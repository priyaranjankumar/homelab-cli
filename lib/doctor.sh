#!/usr/bin/env bash
# homelab-cli/lib/doctor.sh — System health check (read-only)
# Sourced by bin/homelab; provides cmd_doctor.

# ─── Help ────────────────────────────────────────────────────────────
_doctor_usage() {
    cat <<EOF
${C_BOLD}${C_WHITE}homelab doctor${C_RESET} — System health check

${C_BOLD}USAGE${C_RESET}
    homelab [options] doctor

${C_BOLD}DESCRIPTION${C_RESET}
    Performs a read-only diagnostic scan of the Proxmox VE host,
    checking storage, filesystem, ACL tools, and running containers.

${C_BOLD}OPTIONS${C_RESET}
    -h, --help    Show this help message

${C_BOLD}GLOBAL OPTIONS${C_RESET}
    --json        Output results as a JSON object
    --no-color    Disable colored output

${C_BOLD}SECTIONS${C_RESET}
    Host          Hostname and PVE version
    Storage       NVMe / SATA drive detection and DATA_ROOT mount
    Filesystem    Filesystem type on DATA_ROOT (ext4/xfs preferred)
    ACL Tools     Presence of getfacl / setfacl
    Containers    Running LXC containers via pct
    Warnings      Aggregated warnings from all checks

${C_BOLD}EXAMPLES${C_RESET}
    homelab doctor
    homelab --json doctor
EOF
}

# ─── Entry point ─────────────────────────────────────────────────────
cmd_doctor() {
    # Parse args
    while (( $# > 0 )); do
        case "$1" in
            -h|--help) _doctor_usage; return 0 ;;
            *)
                log_error "Unknown argument: $1"
                _doctor_usage
                return 2
                ;;
        esac
    done

    # Warnings accumulator
    local -a WARNINGS=()

    # ── 1. Host ──────────────────────────────────────────────────────
    local host_name host_pve
    host_name="$(hostname 2>/dev/null || echo 'unknown')"

    if command -v pveversion &>/dev/null; then
        host_pve="$(pveversion 2>/dev/null || echo 'unknown')"
    else
        host_pve="not detected"
        WARNINGS+=("PVE not detected — some checks may be limited")
    fi

    # ── 2. Storage ───────────────────────────────────────────────────
    local nvme_detected="false" sata_detected="false"
    local nvme_info="" sata_info=""
    local data_root_mounted="false"

    if command -v lsblk &>/dev/null; then
        local lsblk_output
        lsblk_output="$(lsblk -d -o NAME,TYPE,TRAN,SIZE,MODEL --noheadings 2>/dev/null || true)"

        if [[ -n "$lsblk_output" ]]; then
            # Check NVMe drives
            local nvme_lines
            nvme_lines="$(echo "$lsblk_output" | grep -i 'nvme' || true)"
            if [[ -n "$nvme_lines" ]]; then
                nvme_detected="true"
                nvme_info="$nvme_lines"
            fi

            # Check SATA drives
            local sata_lines
            sata_lines="$(echo "$lsblk_output" | grep -i 'sata' || true)"
            if [[ -n "$sata_lines" ]]; then
                sata_detected="true"
                sata_info="$sata_lines"
            fi
        fi
    else
        WARNINGS+=("lsblk not found — cannot detect drives")
    fi

    if [[ "$nvme_detected" == "false" && "$sata_detected" == "false" ]]; then
        WARNINGS+=("No NVMe or SATA drives detected")
    fi

    # Check if DATA_ROOT is mounted
    if mountpoint -q "${DATA_ROOT}" 2>/dev/null; then
        data_root_mounted="true"
    elif [[ -d "${DATA_ROOT}" ]]; then
        # Directory exists but may not be a separate mount (could be on root fs)
        if df "${DATA_ROOT}" &>/dev/null; then
            data_root_mounted="true"
        fi
    else
        data_root_mounted="false"
        WARNINGS+=("DATA_ROOT (${DATA_ROOT}) does not exist")
    fi

    # ── 3. Filesystem ────────────────────────────────────────────────
    local fs_type="unknown" fs_ok="false"

    if [[ -d "${DATA_ROOT}" ]]; then
        if command -v findmnt &>/dev/null; then
            fs_type="$(findmnt -n -o FSTYPE --target "${DATA_ROOT}" 2>/dev/null || echo 'unknown')"
        elif command -v df &>/dev/null; then
            fs_type="$(df -T "${DATA_ROOT}" 2>/dev/null | awk 'NR==2{print $2}' || echo 'unknown')"
        fi

        # Trim whitespace
        fs_type="$(echo "$fs_type" | xargs)"

        if [[ "$fs_type" == "ext4" || "$fs_type" == "xfs" ]]; then
            fs_ok="true"
        else
            fs_ok="false"
            if [[ "$fs_type" != "unknown" ]]; then
                WARNINGS+=("Filesystem on ${DATA_ROOT} is '${fs_type}' — ext4 or xfs recommended")
            else
                WARNINGS+=("Could not determine filesystem type on ${DATA_ROOT}")
            fi
        fi
    else
        WARNINGS+=("Cannot check filesystem — ${DATA_ROOT} not found")
    fi

    # ── 4. ACL tools ─────────────────────────────────────────────────
    local getfacl_ok="false" setfacl_ok="false"

    if command -v getfacl &>/dev/null; then
        getfacl_ok="true"
    else
        WARNINGS+=("getfacl not installed — ACL inspection unavailable")
    fi

    if command -v setfacl &>/dev/null; then
        setfacl_ok="true"
    else
        WARNINGS+=("setfacl not installed — ACL management unavailable")
    fi

    # ── 5. Containers ────────────────────────────────────────────────
    local pct_available="false"
    local -a ct_ids=()
    local -a ct_names=()
    local -a ct_statuses=()

    if command -v pct &>/dev/null; then
        pct_available="true"
        local pct_output
        pct_output="$(pct list 2>/dev/null || true)"

        if [[ -n "$pct_output" ]]; then
            # Skip header line, parse VMID, Status, Name
            while IFS= read -r line; do
                # Skip empty lines and the header
                [[ -z "$line" ]] && continue
                [[ "$line" =~ ^VMID ]] && continue

                local vmid status name
                vmid="$(echo "$line" | awk '{print $1}')"
                status="$(echo "$line" | awk '{print $2}')"
                name="$(echo "$line" | awk '{print $3}')"

                if [[ -n "$vmid" && "$vmid" =~ ^[0-9]+$ ]]; then
                    ct_ids+=("$vmid")
                    ct_statuses+=("${status:-unknown}")
                    ct_names+=("${name:-unnamed}")
                fi
            done <<< "$pct_output"
        fi
    else
        WARNINGS+=("pct not available — cannot list containers")
    fi

    # ─── JSON output ─────────────────────────────────────────────────
    if [[ "${HOMELAB_JSON}" == "true" ]]; then
        _doctor_json_output \
            "$host_name" "$host_pve" \
            "$nvme_detected" "$sata_detected" "$data_root_mounted" \
            "$fs_type" "$fs_ok" \
            "$getfacl_ok" "$setfacl_ok" \
            "$pct_available"
        return 0
    fi

    # ─── Human-readable output ───────────────────────────────────────
    print_header "Homelab Doctor"

    # ── Host section ─────────────────────────────────────────────────
    print_section "Host"
    echo "  Hostname : ${C_BOLD}${host_name}${C_RESET}"
    if [[ "$host_pve" == "not detected" ]]; then
        echo "  PVE      : ${C_YELLOW}not detected${C_RESET}"
    else
        echo "  PVE      : ${C_GREEN}${host_pve}${C_RESET}"
    fi

    # ── Storage section ──────────────────────────────────────────────
    print_section "Storage"
    if [[ "$nvme_detected" == "true" ]]; then
        echo "  NVMe     : ${C_GREEN}✓ Detected${C_RESET}"
        while IFS= read -r drive_line; do
            [[ -z "$drive_line" ]] && continue
            echo "             ${C_DIM}${drive_line}${C_RESET}"
        done <<< "$nvme_info"
    else
        echo "  NVMe     : ${C_YELLOW}✗ Not detected${C_RESET}"
    fi

    if [[ "$sata_detected" == "true" ]]; then
        echo "  SATA     : ${C_GREEN}✓ Detected${C_RESET}"
        while IFS= read -r drive_line; do
            [[ -z "$drive_line" ]] && continue
            echo "             ${C_DIM}${drive_line}${C_RESET}"
        done <<< "$sata_info"
    else
        echo "  SATA     : ${C_YELLOW}✗ Not detected${C_RESET}"
    fi

    if [[ "$data_root_mounted" == "true" ]]; then
        echo "  DATA_ROOT: ${C_GREEN}✓ ${DATA_ROOT} mounted${C_RESET}"
    else
        echo "  DATA_ROOT: ${C_RED}✗ ${DATA_ROOT} not mounted${C_RESET}"
    fi

    # ── Filesystem section ───────────────────────────────────────────
    print_section "Filesystem"
    if [[ "$fs_ok" == "true" ]]; then
        echo "  ${DATA_ROOT}: ${C_GREEN}✓ ${fs_type}${C_RESET}"
    elif [[ "$fs_type" == "unknown" ]]; then
        echo "  ${DATA_ROOT}: ${C_YELLOW}? unknown${C_RESET}"
    else
        echo "  ${DATA_ROOT}: ${C_YELLOW}⚠ ${fs_type} (ext4 or xfs recommended)${C_RESET}"
    fi

    # ── ACL Tools section ────────────────────────────────────────────
    print_section "ACL Tools"
    if [[ "$getfacl_ok" == "true" ]]; then
        echo "  getfacl  : ${C_GREEN}✓ Installed${C_RESET}"
    else
        echo "  getfacl  : ${C_RED}✗ Not installed${C_RESET}"
    fi

    if [[ "$setfacl_ok" == "true" ]]; then
        echo "  setfacl  : ${C_GREEN}✓ Installed${C_RESET}"
    else
        echo "  setfacl  : ${C_RED}✗ Not installed${C_RESET}"
    fi

    # ── Containers section ───────────────────────────────────────────
    print_section "Containers"
    if [[ "$pct_available" == "false" ]]; then
        echo "  ${C_YELLOW}pct not available${C_RESET}"
    elif [[ ${#ct_ids[@]} -eq 0 ]]; then
        echo "  ${C_DIM}No containers found${C_RESET}"
    else
        print_table_header "VMID" "Status" "Name"
        for i in "${!ct_ids[@]}"; do
            print_table_row "${ct_ids[$i]}" "${ct_statuses[$i]}" "${ct_names[$i]}"
        done
    fi

    # ── Warnings section ─────────────────────────────────────────────
    print_section "Warnings"
    if [[ ${#WARNINGS[@]} -eq 0 ]]; then
        echo "  ${C_GREEN}None${C_RESET}"
    else
        for w in "${WARNINGS[@]}"; do
            echo "  ${C_YELLOW}⚠${C_RESET}  ${w}"
        done
    fi

    echo ""
}

# ─── JSON builder for doctor output ──────────────────────────────────
_doctor_json_output() {
    local host_name="$1" host_pve="$2"
    local nvme_detected="$3" sata_detected="$4" data_root_mounted="$5"
    local fs_type="$6" fs_ok="$7"
    local getfacl_ok="$8" setfacl_ok="$9"
    local pct_available="${10}"

    # We build the JSON manually using the common.sh helpers.
    # Because the helpers work on a single global buffer, we build
    # nested objects as raw strings.

    # -- host object --
    local host_json
    host_json="$(json_object "hostname" "$host_name" "pve_version" "$host_pve")"

    # -- storage object --
    local storage_json
    json_start
    json_add_bool "nvme_detected" "$nvme_detected"
    json_add_bool "sata_detected" "$sata_detected"
    json_add_bool "data_root_mounted" "$data_root_mounted"
    json_add_string "data_root" "${DATA_ROOT}"
    storage_json="$(_json_flush)"

    # -- filesystem object --
    local fs_json
    json_start
    json_add_string "path" "${DATA_ROOT}"
    json_add_string "type" "$fs_type"
    json_add_bool "ok" "$fs_ok"
    fs_json="$(_json_flush)"

    # -- acl_tools object --
    local acl_json
    json_start
    json_add_bool "getfacl" "$getfacl_ok"
    json_add_bool "setfacl" "$setfacl_ok"
    acl_json="$(_json_flush)"

    # -- containers array --
    local containers_json="["
    local ct_first="true"
    if [[ "$pct_available" == "true" ]]; then
        for i in "${!ct_ids[@]}"; do
            if [[ "$ct_first" == "true" ]]; then ct_first="false"; else containers_json+=","; fi
            containers_json+="{\"vmid\":${ct_ids[$i]},\"status\":\"${ct_statuses[$i]}\",\"name\":\"${ct_names[$i]}\"}"
        done
    fi
    containers_json+="]"

    # -- warnings array --
    local warnings_json="["
    local w_first="true"
    for w in "${WARNINGS[@]+"${WARNINGS[@]}"}"; do
        [[ -z "$w" ]] && continue
        # Escape the warning string
        local escaped_w="${w//\\/\\\\}"
        escaped_w="${escaped_w//\"/\\\"}"
        if [[ "$w_first" == "true" ]]; then w_first="false"; else warnings_json+=","; fi
        warnings_json+="\"${escaped_w}\""
    done
    warnings_json+="]"

    # -- assemble top-level object --
    json_start
    json_add_raw "host" "$host_json"
    json_add_raw "storage" "$storage_json"
    json_add_raw "filesystem" "$fs_json"
    json_add_raw "acl_tools" "$acl_json"
    json_add_raw "containers" "$containers_json"
    json_add_raw "warnings" "$warnings_json"
    json_end
}

# Internal: flush the current JSON buffer as a closed object string
# without printing to stdout (for nesting).
_json_flush() {
    _JSON_BUF+="}"
    echo "${_JSON_BUF}"
    _JSON_BUF=""
    _JSON_FIRST="true"
}
