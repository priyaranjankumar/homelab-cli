#!/usr/bin/env bash
# homelab-cli/lib/container.sh — LXC container listing
# Sourced by bin/homelab; never executed directly.

# ─── Help ────────────────────────────────────────────────────────────
_container_usage() {
    cat <<EOF
${C_BOLD}${C_WHITE}homelab container${C_RESET} — LXC container listing

${C_BOLD}USAGE${C_RESET}
    homelab container [subcommand] [options]

${C_BOLD}SUBCOMMANDS${C_RESET}
    ${C_CYAN}list${C_RESET}    List all LXC containers (default)

${C_BOLD}OPTIONS${C_RESET}
    --json        Output in JSON format
    -h, --help    Show this help message

${C_BOLD}EXAMPLES${C_RESET}
    homelab container
    homelab container list
    homelab container list --json

${C_DIM}Requires: pct (Proxmox container toolkit)${C_RESET}
EOF
}

# ─── Helpers ─────────────────────────────────────────────────────────

# Format memory in MB to a human-friendly string
_format_ram() {
    local mb="$1"
    if [[ -z "$mb" || "$mb" == "0" ]]; then
        echo "-"
        return
    fi
    if (( mb >= 1024 )) && (( mb % 1024 == 0 )); then
        echo "$(( mb / 1024 )) GB"
    else
        echo "${mb} MB"
    fi
}

# Extract IP address from a pct net0 config line value
# Input example: name=eth0,bridge=vmbr0,hwaddr=AA:BB:CC:DD:EE:FF,ip=192.168.1.49/24,gw=192.168.1.1
# Returns the IP without CIDR suffix, or "DHCP" / "-"
_extract_ip() {
    local net_line="$1"
    if [[ -z "$net_line" ]]; then
        echo "-"
        return
    fi

    # Extract the ip= value
    local ip_val
    ip_val="$(echo "$net_line" | grep -oP 'ip=\K[^,]+' || true)"

    if [[ -z "$ip_val" ]]; then
        echo "-"
    elif [[ "$ip_val" == "dhcp" ]]; then
        echo "DHCP"
    else
        # Strip CIDR suffix (e.g. /24)
        echo "${ip_val%%/*}"
    fi
}

# ─── List containers ────────────────────────────────────────────────
_container_list() {
    require_cmd "pct" "Proxmox container toolkit"

    # Get container list (skip the header line)
    local pct_output
    pct_output="$(pct list 2>/dev/null)" || {
        log_error "Failed to run 'pct list'."
        exit 1
    }

    # Parse lines, skipping the header
    local lines
    mapfile -t lines <<< "$pct_output"

    # Collect container data
    local -a vmids=() hostnames=() ram_values=() cpu_values=() ips=() statuses=() memory_mbs=()

    local first_line="true"
    for line in "${lines[@]}"; do
        # Skip header line
        if [[ "$first_line" == "true" ]]; then
            first_line="false"
            continue
        fi

        # Skip empty lines
        [[ -z "${line// /}" ]] && continue

        # Parse: VMID Status Lock Name
        # Fields are whitespace-separated; Lock may be empty
        local vmid status lock name
        read -r vmid status lock name <<< "$line"

        # If only 3 fields, lock is empty — shift fields
        if [[ -z "$name" ]]; then
            name="$lock"
            lock=""
        fi

        # Fetch config for this container
        local config
        config="$(pct config "$vmid" 2>/dev/null)" || config=""

        # Extract memory (MB)
        local memory_mb
        memory_mb="$(echo "$config" | grep -E '^memory:' | awk '{print $2}' || true)"
        [[ -z "$memory_mb" ]] && memory_mb="0"

        # Extract cores
        local cores
        cores="$(echo "$config" | grep -E '^cores:' | awk '{print $2}' || true)"
        [[ -z "$cores" ]] && cores="-"

        # Extract net0 line and IP
        local net0_line
        net0_line="$(echo "$config" | grep -E '^net0:' | sed 's/^net0: *//' || true)"
        local ip
        ip="$(_extract_ip "$net0_line")"

        # Format RAM
        local ram_display
        ram_display="$(_format_ram "$memory_mb")"

        vmids+=("$vmid")
        hostnames+=("$name")
        ram_values+=("$ram_display")
        memory_mbs+=("$memory_mb")
        cpu_values+=("$cores")
        ips+=("$ip")
        statuses+=("$status")
    done

    local count="${#vmids[@]}"

    # ─── JSON output ─────────────────────────────────────────────
    if [[ "${HOMELAB_JSON}" == "true" ]]; then
        local json_out="["
        for (( i = 0; i < count; i++ )); do
            (( i > 0 )) && json_out+=","

            # Escape string values
            local h="${hostnames[$i]}" ip_v="${ips[$i]}" st="${statuses[$i]}" cv="${cpu_values[$i]}"
            h="${h//\\/\\\\}"; h="${h//\"/\\\"}"
            ip_v="${ip_v//\\/\\\\}"; ip_v="${ip_v//\"/\\\"}"
            st="${st//\\/\\\\}"; st="${st//\"/\\\"}"
            cv="${cv//\\/\\\\}"; cv="${cv//\"/\\\"}"

            json_out+="{\"id\":${vmids[$i]}"
            json_out+=",\"hostname\":\"${h}\""
            json_out+=",\"memory_mb\":${memory_mbs[$i]}"
            json_out+=",\"cores\":\"${cv}\""
            json_out+=",\"ip\":\"${ip_v}\""
            json_out+=",\"status\":\"${st}\"}"
        done
        json_out+="]"
        echo "$json_out"
        return
    fi

    # ─── Table output ────────────────────────────────────────────
    print_header "Containers"

    if (( count == 0 )); then
        echo ""
        log_warn "No containers found."
        return
    fi

    echo ""
    print_table_header "ID" "Hostname" "RAM" "CPU" "IP" "Status"

    for (( i = 0; i < count; i++ )); do
        print_table_row "${vmids[$i]}" "${hostnames[$i]}" "${ram_values[$i]}" "${cpu_values[$i]}" "${ips[$i]}" "${statuses[$i]}"
    done

    echo ""
    log_info "${count} container(s) found."
}

# ─── Entry point ─────────────────────────────────────────────────────
cmd_container() {
    local subcmd="${1:-list}"
    shift 2>/dev/null || true

    case "$subcmd" in
        list)
            _container_list "$@"
            ;;
        -h|--help|help)
            _container_usage
            ;;
        *)
            log_error "Unknown subcommand: ${subcmd}"
            echo ""
            _container_usage
            exit 2
            ;;
    esac
}
