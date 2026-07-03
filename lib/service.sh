#!/usr/bin/env bash
# homelab-cli/lib/service.sh — Service URL listing
# Sourced by bin/homelab; never executed directly.

# ─── Help ────────────────────────────────────────────────────────────
_service_usage() {
    cat <<EOF
${C_BOLD}${C_WHITE}homelab service${C_RESET} — Service URL listing

${C_BOLD}USAGE${C_RESET}
    homelab service [subcommand] [options]

${C_BOLD}SUBCOMMANDS${C_RESET}
    ${C_CYAN}urls${C_RESET}        List service URLs (default)

${C_BOLD}OPTIONS${C_RESET}
    --json      Output in JSON format
    -h, --help  Show this help message

${C_BOLD}EXAMPLES${C_RESET}
    homelab service
    homelab service urls
    homelab service urls --json

${C_DIM}Services are configured in config/homelab.conf via
SERVICE_PORTS and SERVICE_NAMES.${C_RESET}
EOF
}

# ─── Get container IP ────────────────────────────────────────────────
# Usage: _get_container_ip <vmid>
# Prints the IP address or '<unknown>' / '<no pct>'
_get_container_ip() {
    local vmid="$1"
    local ip=""

    # If pct is not available, we can't query containers
    if ! command -v pct &>/dev/null; then
        echo "<no pct>"
        return
    fi

    # Try to parse IP from pct config (static config)
    local net_line
    net_line="$(pct config "$vmid" 2>/dev/null | grep -E '^net0:' || true)"
    if [[ -n "$net_line" ]]; then
        # Extract ip=<addr> value, strip CIDR suffix
        ip="$(echo "$net_line" | grep -oP 'ip=\K[^,/]+' || true)"
    fi

    # If IP is 'dhcp' or empty, try to get it from inside the container
    if [[ -z "$ip" || "$ip" == "dhcp" ]]; then
        ip="$(pct exec "$vmid" -- hostname -I 2>/dev/null | awk '{print $1}' || true)"
    fi

    # Final fallback
    if [[ -z "$ip" ]]; then
        echo "<unknown>"
    else
        echo "$ip"
    fi
}

# ─── Subcommand: urls ───────────────────────────────────────────────
_service_urls() {
    # Check for configured services
    if [[ -z "${SERVICE_PORTS:-}" ]]; then
        if [[ "${HOMELAB_JSON}" == "true" ]]; then
            echo "[]"
        else
            log_warn "No services configured. Edit config/homelab.conf to add services."
        fi
        return 0
    fi

    # Collect service data
    local -a vmids=() ports=() names=() ips=() urls=()

    for entry in ${SERVICE_PORTS}; do
        local vmid="${entry%%:*}"
        local port="${entry#*:}"

        # Look up the service name
        local name
        name="$(map_lookup "${SERVICE_NAMES}" "$vmid" 2>/dev/null || true)"
        if [[ -z "$name" ]]; then
            name="Container ${vmid}"
        fi

        # Replace underscores with spaces for display
        local display_name="${name//_/ }"

        # Get container IP
        local ip
        ip="$(_get_container_ip "$vmid")"

        # Build URL
        local url="http://${ip}:${port}"

        vmids+=("$vmid")
        ports+=("$port")
        names+=("$display_name")
        ips+=("$ip")
        urls+=("$url")
    done

    # Output
    if [[ "${HOMELAB_JSON}" == "true" ]]; then
        local first="true"
        local buf="["
        for i in "${!vmids[@]}"; do
            if [[ "$first" == "true" ]]; then
                first="false"
            else
                buf+=","
            fi
            # Escape name for JSON
            local dn="${names[$i]//\\/\\\\}"
            dn="${dn//\"/\\\"}"
            buf+="{\"name\":\"${dn}\""
            buf+=",\"vmid\":\"${vmids[$i]}\""
            buf+=",\"ip\":\"${ips[$i]}\""
            buf+=",\"port\":\"${ports[$i]}\""
            buf+=",\"url\":\"${urls[$i]}\"}"
        done
        buf+="]"
        echo "$buf"
    else
        print_header "Service URLs"
        print_table_header "Service" "URL"
        for i in "${!vmids[@]}"; do
            print_table_row "${names[$i]}" "${urls[$i]}"
        done
    fi
}

# ─── Entry point ────────────────────────────────────────────────────
cmd_service() {
    local subcmd="${1:-urls}"
    shift 2>/dev/null || true

    case "$subcmd" in
        urls)
            _service_urls "$@"
            ;;
        -h|--help)
            _service_usage
            ;;
        *)
            log_error "Unknown subcommand: ${subcmd}"
            echo ""
            _service_usage
            exit 2
            ;;
    esac
}
