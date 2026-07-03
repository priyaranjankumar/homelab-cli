#!/usr/bin/env bash
# homelab-cli/lib/storage.sh — Storage inspection module
# Sourced by bin/homelab; never executed directly.

# ─── Help ────────────────────────────────────────────────────────────
_storage_usage() {
    cat <<EOF
${C_BOLD}${C_WHITE}homelab storage${C_RESET} — Storage inspection and management

${C_BOLD}USAGE${C_RESET}
    homelab storage <subcommand> [options]

${C_BOLD}SUBCOMMANDS${C_RESET}
    ${C_CYAN}status${C_RESET}    Show storage status (default)
    ${C_CYAN}repair${C_RESET}    Repair storage issues (coming soon)

${C_BOLD}OPTIONS${C_RESET}
    --json      Output in JSON format
    -h, --help  Show this help message

${C_BOLD}EXAMPLES${C_RESET}
    homelab storage
    homelab storage status
    homelab storage status --json
    homelab storage repair

${C_DIM}Shows NVMe/SATA devices, data root filesystem info, and PVE storage pools.${C_RESET}
EOF
}

# ─── Helpers ─────────────────────────────────────────────────────────

# Collect NVMe devices into parallel arrays
_storage_collect_nvme() {
    _NVME_NAMES=()
    _NVME_SIZES=()
    _NVME_MODELS=()

    if ! command -v lsblk &>/dev/null; then
        return 1
    fi

    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local name type tran size model
        read -r name type tran size model <<< "$line"
        _NVME_NAMES+=("$name")
        _NVME_SIZES+=("$size")
        _NVME_MODELS+=("${model:-unknown}")
    done < <(lsblk -d -o NAME,TYPE,TRAN,SIZE,MODEL --noheadings 2>/dev/null | grep -i nvme || true)

    return 0
}

# Collect SATA devices into parallel arrays
_storage_collect_sata() {
    _SATA_NAMES=()
    _SATA_SIZES=()
    _SATA_MODELS=()

    if ! command -v lsblk &>/dev/null; then
        return 1
    fi

    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local name type tran size model
        read -r name type tran size model <<< "$line"
        _SATA_NAMES+=("$name")
        _SATA_SIZES+=("$size")
        _SATA_MODELS+=("${model:-unknown}")
    done < <(lsblk -d -o NAME,TYPE,TRAN,SIZE,MODEL --noheadings 2>/dev/null | grep -i sata || true)

    return 0
}

# Collect data root info
_storage_collect_data_root() {
    local data_root="${DATA_ROOT:-/srv/data}"

    _DR_PATH="$data_root"
    _DR_EXISTS="false"
    _DR_MOUNTED="false"
    _DR_FSTYPE="unknown"
    _DR_USED="unknown"
    _DR_FREE="unknown"
    _DR_TOTAL="unknown"
    _DR_USE_PCT="unknown"

    if [[ -d "$data_root" ]]; then
        _DR_EXISTS="true"

        # Check if it's a mount point or on a mounted filesystem
        if findmnt -n "$data_root" &>/dev/null; then
            _DR_MOUNTED="true"
            _DR_FSTYPE="$(findmnt -n -o FSTYPE "$data_root" 2>/dev/null || echo "unknown")"
        fi

        # Get disk usage stats
        if command -v df &>/dev/null; then
            local df_line
            df_line="$(df -h "$data_root" 2>/dev/null | tail -1)"
            if [[ -n "$df_line" ]]; then
                local fs total used free pct mount
                read -r fs total used free pct mount <<< "$df_line"
                _DR_TOTAL="$total"
                _DR_USED="$used"
                _DR_FREE="$free"
                _DR_USE_PCT="$pct"
            fi
        fi
    fi
}

# Collect PVE storage pools
_storage_collect_pve_pools() {
    _PVE_POOL_NAMES=()
    _PVE_POOL_TYPES=()
    _PVE_POOL_STATUSES=()
    _PVE_POOL_TOTALS=()
    _PVE_POOL_USEDS=()
    _PVE_POOL_AVAILS=()
    _PVE_POOL_PCTS=()

    if ! command -v pvesm &>/dev/null; then
        return 1
    fi

    local line
    local first="true"
    while IFS= read -r line; do
        # Skip the header line
        if [[ "$first" == "true" ]]; then
            first="false"
            continue
        fi
        [[ -z "$line" ]] && continue

        local name type status total used avail pct
        read -r name type status total used avail pct <<< "$line"

        _PVE_POOL_NAMES+=("$name")
        _PVE_POOL_TYPES+=("${type:-unknown}")
        _PVE_POOL_STATUSES+=("${status:-unknown}")
        _PVE_POOL_TOTALS+=("${total:-0}")
        _PVE_POOL_USEDS+=("${used:-0}")
        _PVE_POOL_AVAILS+=("${avail:-0}")
        _PVE_POOL_PCTS+=("${pct:-0%}")
    done < <(pvesm status 2>/dev/null || true)

    return 0
}

# Format bytes (PVE reports in bytes or KiB depending on version)
_storage_format_size() {
    local val="$1"
    # If already has a suffix, return as-is
    if [[ "$val" =~ [A-Za-z]$ ]]; then
        echo "$val"
        return
    fi
    # Assume bytes, convert to human-readable
    if (( val >= 1073741824 )); then
        printf "%.1fG" "$(echo "scale=1; $val / 1073741824" | bc 2>/dev/null || echo "$val")"
    elif (( val >= 1048576 )); then
        printf "%.1fM" "$(echo "scale=1; $val / 1048576" | bc 2>/dev/null || echo "$val")"
    elif (( val >= 1024 )); then
        printf "%.1fK" "$(echo "scale=1; $val / 1024" | bc 2>/dev/null || echo "$val")"
    else
        echo "${val}B"
    fi
}

# ─── Subcommand: status ─────────────────────────────────────────────
_storage_status() {
    # Collect all data first
    local has_lsblk="true"
    _storage_collect_nvme  || has_lsblk="false"
    _storage_collect_sata  || has_lsblk="false"
    _storage_collect_data_root

    local has_pvesm="true"
    _storage_collect_pve_pools || has_pvesm="false"

    # ── JSON output ──────────────────────────────────────────────────
    if [[ "${HOMELAB_JSON}" == "true" ]]; then
        json_start

        # NVMe devices
        local nvme_arr="["
        local nfirst="true"
        for i in "${!_NVME_NAMES[@]}"; do
            if [[ "$nfirst" == "true" ]]; then nfirst="false"; else nvme_arr+=","; fi
            nvme_arr+="$(json_object \
                "device" "${_NVME_NAMES[$i]}" \
                "size" "${_NVME_SIZES[$i]}" \
                "model" "${_NVME_MODELS[$i]}")"
        done
        nvme_arr+="]"
        json_add_raw "nvme" "$nvme_arr"

        # SATA devices
        local sata_arr="["
        local sfirst="true"
        for i in "${!_SATA_NAMES[@]}"; do
            if [[ "$sfirst" == "true" ]]; then sfirst="false"; else sata_arr+=","; fi
            sata_arr+="$(json_object \
                "device" "${_SATA_NAMES[$i]}" \
                "size" "${_SATA_SIZES[$i]}" \
                "model" "${_SATA_MODELS[$i]}")"
        done
        sata_arr+="]"
        json_add_raw "sata" "$sata_arr"

        # Data root
        local dr_json
        dr_json="{"
        dr_json+="\"path\":\"${_DR_PATH}\""
        dr_json+=",\"exists\":${_DR_EXISTS}"
        dr_json+=",\"mounted\":${_DR_MOUNTED}"
        dr_json+=",\"filesystem\":\"${_DR_FSTYPE}\""
        dr_json+=",\"total\":\"${_DR_TOTAL}\""
        dr_json+=",\"used\":\"${_DR_USED}\""
        dr_json+=",\"free\":\"${_DR_FREE}\""
        dr_json+=",\"use_percent\":\"${_DR_USE_PCT}\""
        dr_json+="}"
        json_add_raw "data_root" "$dr_json"

        # PVE pools
        local pve_arr="["
        local pfirst="true"
        for i in "${!_PVE_POOL_NAMES[@]}"; do
            if [[ "$pfirst" == "true" ]]; then pfirst="false"; else pve_arr+=","; fi
            pve_arr+="$(json_object \
                "name" "${_PVE_POOL_NAMES[$i]}" \
                "type" "${_PVE_POOL_TYPES[$i]}" \
                "status" "${_PVE_POOL_STATUSES[$i]}" \
                "total" "${_PVE_POOL_TOTALS[$i]}" \
                "used" "${_PVE_POOL_USEDS[$i]}" \
                "available" "${_PVE_POOL_AVAILS[$i]}" \
                "use_percent" "${_PVE_POOL_PCTS[$i]}")"
        done
        pve_arr+="]"
        json_add_raw "pve_pools" "$pve_arr"

        json_end
        return
    fi

    # ── Human-readable output ────────────────────────────────────────
    print_header "Storage Status"

    # NVMe devices
    print_section "NVMe Devices"
    if [[ "$has_lsblk" == "false" ]]; then
        log_warn "lsblk not found — cannot detect block devices."
    elif [[ ${#_NVME_NAMES[@]} -eq 0 ]]; then
        echo "  ${C_DIM}No NVMe devices found.${C_RESET}"
    else
        print_table_header "Device" "Size" "Model"
        for i in "${!_NVME_NAMES[@]}"; do
            print_table_row "/dev/${_NVME_NAMES[$i]}" "${_NVME_SIZES[$i]}" "${_NVME_MODELS[$i]}"
        done
    fi

    # SATA devices
    print_section "SATA Devices"
    if [[ "$has_lsblk" == "false" ]]; then
        log_warn "lsblk not found — cannot detect block devices."
    elif [[ ${#_SATA_NAMES[@]} -eq 0 ]]; then
        echo "  ${C_DIM}No SATA devices found.${C_RESET}"
    else
        print_table_header "Device" "Size" "Model"
        for i in "${!_SATA_NAMES[@]}"; do
            print_table_row "/dev/${_SATA_NAMES[$i]}" "${_SATA_SIZES[$i]}" "${_SATA_MODELS[$i]}"
        done
    fi

    # Data root filesystem
    print_section "Data Root (${_DR_PATH})"
    if [[ "${_DR_EXISTS}" == "false" ]]; then
        log_warn "Data root '${_DR_PATH}' does not exist."
    else
        log_ok "Directory exists"
        if [[ "${_DR_MOUNTED}" == "true" ]]; then
            log_ok "Mounted  (filesystem: ${_DR_FSTYPE})"
        else
            log_warn "Not a separate mount point (on root filesystem)."
        fi
        if [[ "${_DR_TOTAL}" != "unknown" ]]; then
            print_table_header "Total" "Used" "Free" "Use%"
            print_table_row "${_DR_TOTAL}" "${_DR_USED}" "${_DR_FREE}" "${_DR_USE_PCT}"
        fi
    fi

    # PVE storage pools
    print_section "PVE Storage Pools"
    if [[ "$has_pvesm" == "false" ]]; then
        log_warn "pvesm not found — Proxmox storage manager not available."
    elif [[ ${#_PVE_POOL_NAMES[@]} -eq 0 ]]; then
        echo "  ${C_DIM}No PVE storage pools found.${C_RESET}"
    else
        print_table_header "Name" "Type" "Status" "Total" "Used" "Available" "Use%"
        for i in "${!_PVE_POOL_NAMES[@]}"; do
            print_table_row \
                "${_PVE_POOL_NAMES[$i]}" \
                "${_PVE_POOL_TYPES[$i]}" \
                "${_PVE_POOL_STATUSES[$i]}" \
                "${_PVE_POOL_TOTALS[$i]}" \
                "${_PVE_POOL_USEDS[$i]}" \
                "${_PVE_POOL_AVAILS[$i]}" \
                "${_PVE_POOL_PCTS[$i]}"
        done
    fi

    echo ""
}

# ─── Subcommand: repair ─────────────────────────────────────────────
_storage_repair() {
    if [[ "${HOMELAB_JSON}" == "true" ]]; then
        json_start
        json_add_string "status" "not_implemented"
        json_add_string "message" "Storage repair is planned for a future version."
        json_end
        return
    fi

    print_header "Storage Repair"
    log_info "Coming soon — storage repair is planned for a future version."
    echo ""
    echo "  ${C_DIM}This will include:${C_RESET}"
    echo "    • Filesystem consistency checks"
    echo "    • Data directory recreation"
    echo "    • Permission repairs"
    echo ""
}

# ─── Entry point ─────────────────────────────────────────────────────
cmd_storage() {
    local subcmd="${1:-status}"
    shift 2>/dev/null || true

    case "$subcmd" in
        status)          _storage_status "$@" ;;
        repair)          _storage_repair "$@" ;;
        -h|--help|help)  _storage_usage ;;
        *)
            log_error "Unknown storage subcommand: ${subcmd}"
            echo ""
            _storage_usage
            exit 2
            ;;
    esac
}
