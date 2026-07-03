#!/usr/bin/env bash
# homelab-cli/lib/mount.sh — Bind mount inspection for LXC containers
# Sourced by bin/homelab; never executed directly.

# ─── Help ────────────────────────────────────────────────────────────
_mount_usage() {
    cat <<EOF
${C_BOLD}${C_WHITE}homelab mount${C_RESET} — Bind mount inspection for LXC containers

${C_BOLD}USAGE${C_RESET}
    homelab mount [subcommand] [options]

${C_BOLD}SUBCOMMANDS${C_RESET}
    ${C_CYAN}list${C_RESET}    List all bind mounts for every container (default)

${C_BOLD}OPTIONS${C_RESET}
    --json        Output in JSON format
    --help        Show this help message

${C_BOLD}EXAMPLES${C_RESET}
    homelab mount
    homelab mount list
    homelab mount list --json
EOF
}

# ─── Parse a single mount line from pct config ──────────────────────
# Input : a line like "mp0: /srv/data/media,mp=/media,backup=0"
#         or           "mp0: local-lvm:vm-100-disk-1,mp=/data,size=50G"
# Output: prints "host_path<TAB>container_path"
_parse_mount_line() {
    local line="$1"

    # Strip the key (mp0: , rootfs: , etc.) to get the value part
    local value="${line#*: }"

    # Host path / volume reference: everything before the first comma
    local host_path="${value%%,*}"

    # Container path: extract mp=<path> from the comma-separated options
    local container_path=""
    if [[ "$value" =~ mp=([^,]+) ]]; then
        container_path="${BASH_REMATCH[1]}"
    fi

    # rootfs lines have no mp= key; the mount point is always /
    if [[ -z "$container_path" ]]; then
        container_path="/"
    fi

    printf '%s\t%s\n' "$host_path" "$container_path"
}

# ─── List bind mounts ───────────────────────────────────────────────
_mount_list() {
    require_cmd "pct" "Proxmox container toolkit"

    # Collect container IDs from pct list (skip the header line)
    local vmids
    vmids=$(pct list 2>/dev/null | tail -n +2 | awk '{print $1}')

    if [[ -z "$vmids" ]]; then
        if [[ "${HOMELAB_JSON}" == "true" ]]; then
            echo "[]"
        else
            log_warn "No LXC containers found."
        fi
        return 0
    fi

    # ── JSON mode ────────────────────────────────────────────────────
    if [[ "${HOMELAB_JSON}" == "true" ]]; then
        json_start_array

        while IFS= read -r vmid; do
            [[ -z "$vmid" ]] && continue

            # Hostname
            local hostname=""
            hostname=$(pct config "$vmid" 2>/dev/null \
                | grep -E '^hostname:' \
                | head -1 \
                | awk '{print $2}')
            [[ -z "$hostname" ]] && hostname="unknown"

            # Build mounts JSON array manually (avoid clobbering global json buffer)
            local mounts_json="["
            local mounts_first="true"
            local config
            config=$(pct config "$vmid" 2>/dev/null)

            while IFS= read -r mp_line; do
                [[ -z "$mp_line" ]] && continue

                local parsed
                parsed=$(_parse_mount_line "$mp_line")
                local host_path container_path
                host_path=$(echo "$parsed" | cut -f1)
                container_path=$(echo "$parsed" | cut -f2)

                local mount_obj
                mount_obj=$(json_object "host_path" "$host_path" "container_path" "$container_path")

                if [[ "$mounts_first" == "true" ]]; then
                    mounts_first="false"
                else
                    mounts_json+=","
                fi
                mounts_json+="$mount_obj"
            done < <(echo "$config" | grep -E '^(mp[0-9]+|rootfs):' || true)

            mounts_json+="]"

            # Build container object manually to avoid nested json_start/json_end
            # which would clobber the outer array's _JSON_BUF
            local hn_escaped="${hostname//\\/\\\\}"
            hn_escaped="${hn_escaped//\"/\\\"}"
            local ct_json="{\"vmid\":${vmid},\"hostname\":\"${hn_escaped}\",\"mounts\":${mounts_json}}"

            json_add_array_item "$ct_json"
        done <<< "$vmids"

        json_end_array
        return 0
    fi

    # ── Human-readable mode ──────────────────────────────────────────
    print_header "LXC Bind Mounts"

    while IFS= read -r vmid; do
        [[ -z "$vmid" ]] && continue

        # Hostname
        local hostname=""
        hostname=$(pct config "$vmid" 2>/dev/null \
            | grep -E '^hostname:' \
            | head -1 \
            | awk '{print $2}')
        [[ -z "$hostname" ]] && hostname="unknown"

        print_section "CT ${vmid} — ${hostname}"

        local config
        config=$(pct config "$vmid" 2>/dev/null)
        local mp_lines
        mp_lines=$(echo "$config" | grep -E '^(mp[0-9]+|rootfs):' || true)

        if [[ -z "$mp_lines" ]]; then
            echo "  ${C_DIM}No bind mounts${C_RESET}"
            continue
        fi

        while IFS= read -r mp_line; do
            [[ -z "$mp_line" ]] && continue

            local parsed
            parsed=$(_parse_mount_line "$mp_line")
            local host_path container_path
            host_path=$(echo "$parsed" | cut -f1)
            container_path=$(echo "$parsed" | cut -f2)

            echo "  ${C_CYAN}${container_path}${C_RESET} → ${C_WHITE}${host_path}${C_RESET}"
        done <<< "$mp_lines"

    done <<< "$vmids"

    echo ""
}

# ─── Entry point ─────────────────────────────────────────────────────
cmd_mount() {
    local subcmd="${1:-list}"
    shift 2>/dev/null || true

    case "$subcmd" in
        list)
            _mount_list "$@"
            ;;
        --help|-h|help)
            _mount_usage
            ;;
        *)
            log_error "Unknown subcommand: ${subcmd}"
            echo ""
            _mount_usage
            exit 2
            ;;
    esac
}
