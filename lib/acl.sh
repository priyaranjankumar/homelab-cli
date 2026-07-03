#!/usr/bin/env bash
# homelab-cli/lib/acl.sh — ACL inspection and management for LXC bind mounts
# Sourced by bin/homelab; never executed directly.

# ─── Help ────────────────────────────────────────────────────────────
_acl_usage() {
    cat <<EOF
${C_BOLD}${C_WHITE}homelab acl${C_RESET} — ACL inspection and management

${C_BOLD}USAGE${C_RESET}
    homelab acl <subcommand> <vmid> [options]

${C_BOLD}SUBCOMMANDS${C_RESET}
    ${C_CYAN}inspect${C_RESET} <vmid>   Inspect ACLs for a container's bind mounts
    ${C_CYAN}grant${C_RESET}   <vmid>   Grant recommended ACLs to bind mounts

${C_BOLD}OPTIONS${C_RESET}
    --json        Output in JSON format
    --dry-run     Preview changes without applying them (grant only)
    -h, --help    Show this help message

${C_BOLD}EXAMPLES${C_RESET}
    homelab acl inspect 103
    homelab acl grant 103
    homelab acl grant 103 --dry-run
    homelab --json acl inspect 103

${C_DIM}The inspect subcommand is read-only; only grant modifies the system.${C_RESET}
EOF
}

# ─── Inspect helpers ────────────────────────────────────────────────

# _acl_get_config <vmid>
#   Retrieve the pct config for a container, or fail.
_acl_get_config() {
    local vmid="$1"
    local config
    if ! config="$(pct config "$vmid" 2>&1)"; then
        log_error "Container ${vmid} not found or not accessible."
        exit 1
    fi
    echo "$config"
}

# _acl_get_hostname <config>
_acl_get_hostname() {
    local config="$1"
    local hostname
    hostname="$(echo "$config" | grep -oP '^hostname:\s*\K\S+' || true)"
    echo "${hostname:-unknown}"
}

# _acl_is_unprivileged <config>
_acl_is_unprivileged() {
    local config="$1"
    echo "$config" | grep -qP '^\s*unprivileged:\s*1'
}

# _acl_get_uid_offset <config>
#   Returns the UID mapping offset. Defaults to 100000 for unprivileged.
_acl_get_uid_offset() {
    local config="$1"
    local offset=""
    # Try to read lxc.idmap from config (format: lxc.idmap: u 0 100000 65536)
    offset="$(echo "$config" | grep -oP 'lxc\.idmap:\s*u\s+0\s+\K[0-9]+' | head -1 || true)"
    echo "${offset:-100000}"
}

# _acl_detect_service_user <vmid> <config>
#   Detect the primary service user inside the container by checking:
#   1. A user matching the service name configured in homelab.conf
#   2. A user matching the container hostname
#   3. Standard UID 1000 user
#   Returns "username:uid" or "unknown:1000".
_acl_detect_service_user() {
    local vmid="$1"
    local config="$2"

    local hostname
    hostname="$(_acl_get_hostname "$config")"

    # Try lookup from SERVICE_NAMES in config
    local svc_name=""
    if [[ -n "${SERVICE_NAMES:-}" ]]; then
        svc_name="$(map_lookup "${SERVICE_NAMES}" "$vmid" 2>/dev/null | tr 'A-Z' 'a-z' || true)"
        # Replace underscores back to hyphens if any
        svc_name="${svc_name//_/-}"
    fi

    # Read passwd contents (via pct exec if running, otherwise host rootfs)
    local passwd_content=""
    local read_success=false

    if pct status "$vmid" 2>/dev/null | grep -q "running"; then
        if passwd_content="$(pct exec "$vmid" -- cat /etc/passwd 2>/dev/null)"; then
            read_success=true
        fi
    fi

    if [[ "$read_success" == "false" ]]; then
        local rootfs_paths=(
            "/var/lib/lxc/${vmid}/rootfs/etc/passwd"
            "/var/lib/lxc/${vmid}/etc/passwd"
        )
        for passwd_file in "${rootfs_paths[@]}"; do
            if [[ -r "$passwd_file" ]]; then
                passwd_content="$(cat "$passwd_file" 2>/dev/null || true)"
                if [[ -n "$passwd_content" ]]; then
                    read_success=true
                    break
                fi
            fi
        done
    fi

    if [[ "$read_success" == "true" ]]; then
        local user_line=""
        
        # 1. Try matching service name
        if [[ -n "$svc_name" ]]; then
            user_line="$(echo "$passwd_content" | awk -F: -v u="$svc_name" '$1 == u { print $1":"$3; exit }' 2>/dev/null || true)"
        fi
        
        # 2. Try matching hostname (lowercased)
        if [[ -z "$user_line" && -n "$hostname" ]]; then
            local hn_lower
            hn_lower="$(echo "$hostname" | tr 'A-Z' 'a-z')"
            user_line="$(echo "$passwd_content" | awk -F: -v u="$hn_lower" '$1 == u { print $1":"$3; exit }' 2>/dev/null || true)"
        fi
        
        # 3. Try fallback standard UID 1000
        if [[ -z "$user_line" ]]; then
            user_line="$(echo "$passwd_content" | awk -F: '$3 == 1000 { print $1":"$3; exit }' 2>/dev/null || true)"
        fi
        
        if [[ -n "$user_line" ]]; then
            echo "$user_line"
            return 0
        fi
    fi

    echo "unknown:1000"
}

# _acl_parse_bind_mounts <config>
#   Parse mp0, mp1, ... lines from the config.
#   Output: one line per mount with format "host_path|container_path"
_acl_parse_bind_mounts() {
    local config="$1"
    # mp lines look like: mp0: /host/path,mp=/container/path[,options...]
    echo "$config" | grep -P '^\s*mp\d+:' | while IFS= read -r line; do
        # Strip key prefix (mp0: )
        local value="${line#*: }"
        # Host path is the first comma-separated field
        local host_path="${value%%,*}"
        # Container path follows mp=
        local container_path
        container_path="$(echo "$value" | grep -oP 'mp=\K[^,]+' || true)"
        if [[ -n "$host_path" && -n "$container_path" ]]; then
            echo "${host_path}|${container_path}"
        fi
    done
}

# _acl_check_access <host_path> <mapped_uid>
#   Check current ACL access for a mapped UID on a path.
#   Returns the permission string (e.g., "rwx") or "None".
_acl_check_access() {
    local host_path="$1"
    local mapped_uid="$2"

    if [[ ! -e "$host_path" ]]; then
        echo "path_missing"
        return
    fi

    local acl_output
    acl_output="$(getfacl -p "$host_path" 2>/dev/null || true)"
    if [[ -z "$acl_output" ]]; then
        echo "None"
        return
    fi

    # Look for user:<mapped_uid>:<perms> in ACL output
    local perms
    perms="$(echo "$acl_output" | grep -P "^user:${mapped_uid}:" | head -1 | awk -F: '{print $3}' || true)"
    if [[ -n "$perms" ]]; then
        echo "$perms"
    else
        echo "None"
    fi
}

# _acl_get_owner <host_path>
_acl_get_owner() {
    local host_path="$1"
    if [[ ! -e "$host_path" ]]; then
        echo "N/A (path missing)"
        return
    fi
    stat -c '%U:%G' "$host_path" 2>/dev/null || echo "unknown:unknown"
}

# ─── Inspect logic ──────────────────────────────────────────────────
# _acl_inspect_data <vmid>
#   Runs the full inspection and prints structured data.
#   Sets global array _ACL_RESULTS with result lines for grant to reuse.
#   Each result line: "host_path|container_path|owner|service_user|service_uid|mapped_uid|access|recommendation"
declare -a _ACL_RESULTS=()

_acl_inspect_data() {
    local vmid="$1"

    require_cmd pct "Proxmox container toolkit"
    require_cmd getfacl "ACL inspection tool"

    local config
    config="$(_acl_get_config "$vmid")"

    local hostname
    hostname="$(_acl_get_hostname "$config")"

    # Check bind mounts
    local mounts
    mounts="$(_acl_parse_bind_mounts "$config")"
    if [[ -z "$mounts" ]]; then
        if [[ "${HOMELAB_JSON}" == "true" ]]; then
            json_start
            json_add_string "vmid" "$vmid"
            json_add_string "hostname" "$hostname"
            json_add_raw "bind_mounts" "[]"
            json_add_string "message" "No bind mounts found"
            json_end
        else
            log_warn "No bind mounts found for container ${vmid} (${hostname})."
        fi
        return 0
    fi

    # Determine UID mapping
    local is_unprivileged=false
    local uid_offset=0
    if _acl_is_unprivileged "$config"; then
        is_unprivileged=true
        uid_offset="$(_acl_get_uid_offset "$config")"
    fi

    # Detect service user
    local service_info
    service_info="$(_acl_detect_service_user "$vmid" "$config")"
    local service_user="${service_info%%:*}"
    local service_uid="${service_info##*:}"

    _ACL_RESULTS=()

    # JSON array accumulator
    local json_items=""

    while IFS='|' read -r host_path container_path; do
        local mapped_uid=$(( service_uid + uid_offset ))
        local owner
        owner="$(_acl_get_owner "$host_path")"
        local access
        access="$(_acl_check_access "$host_path" "$mapped_uid")"

        # Determine recommendation
        local recommendation="OK"
        if [[ "$access" == "path_missing" ]]; then
            recommendation="Path does not exist on host"
            access="N/A"
        elif [[ "$access" == "None" ]]; then
            recommendation="Grant RWX"
        elif ! echo "$access" | grep -qP '^r..[xX]?$' 2>/dev/null; then
            # Has some access but may be insufficient — check for at least rw
            if [[ "$access" != *r* ]] || [[ "$access" != *w* ]]; then
                recommendation="Grant RWX (insufficient)"
            fi
        fi

        # Store result for grant reuse
        _ACL_RESULTS+=("${host_path}|${container_path}|${owner}|${service_user}|${service_uid}|${mapped_uid}|${access}|${recommendation}")

        if [[ "${HOMELAB_JSON}" == "true" ]]; then
            # Build JSON item
            local item_buf
            local _OUTER_JSON_BUF="$_JSON_BUF"
            local _OUTER_JSON_FIRST="$_JSON_FIRST"
            json_start
            json_add_string "host_path" "$host_path"
            json_add_string "container_path" "$container_path"
            json_add_string "filesystem_owner" "$owner"
            json_add_string "service_user" "$service_user"
            json_add_number "service_uid" "$service_uid"
            json_add_number "mapped_host_uid" "$mapped_uid"
            json_add_bool "unprivileged" "$is_unprivileged"
            json_add_number "uid_offset" "$uid_offset"
            json_add_string "current_access" "$access"
            json_add_string "recommendation" "$recommendation"
            item_buf="$(_JSON_BUF="$_JSON_BUF" json_end)"
            _JSON_BUF="$_OUTER_JSON_BUF"
            _JSON_FIRST="$_OUTER_JSON_FIRST"

            if [[ -n "$json_items" ]]; then
                json_items+=","
            fi
            json_items+="$item_buf"
        else
            print_separator
            printf "  ${C_BOLD}%-20s${C_RESET} %s\n" "Container:" "$vmid"
            printf "  ${C_BOLD}%-20s${C_RESET} %s\n" "Hostname:" "$hostname"
            printf "  ${C_BOLD}%-20s${C_RESET} %s → %s\n" "Bind Mount:" "$host_path" "$container_path"
            printf "  ${C_BOLD}%-20s${C_RESET} %s\n" "Filesystem Owner:" "$owner"
            printf "  ${C_BOLD}%-20s${C_RESET} %s (UID %s)\n" "Service User:" "$service_user" "$service_uid"
            printf "  ${C_BOLD}%-20s${C_RESET} %s\n" "Mapped Host UID:" "$mapped_uid"
            printf "  ${C_BOLD}%-20s${C_RESET} %s\n" "Current Access:" "$access"
            if [[ "$recommendation" == "OK" ]]; then
                printf "  ${C_BOLD}%-20s${C_RESET} ${C_GREEN}%s${C_RESET}\n" "Recommendation:" "$recommendation"
            else
                printf "  ${C_BOLD}%-20s${C_RESET} ${C_YELLOW}%s${C_RESET}\n" "Recommendation:" "$recommendation"
            fi
        fi
    done <<< "$mounts"

    if [[ "${HOMELAB_JSON}" == "true" ]]; then
        json_start
        json_add_string "vmid" "$vmid"
        json_add_string "hostname" "$hostname"
        json_add_bool "unprivileged" "$is_unprivileged"
        json_add_number "uid_offset" "$uid_offset"
        json_add_raw "bind_mounts" "[${json_items}]"
        json_end
    else
        print_separator
    fi
}

# ─── Subcommand: inspect ────────────────────────────────────────────
_acl_inspect() {
    local vmid="${1:-}"
    if [[ -z "$vmid" ]]; then
        log_error "Missing required argument: <vmid>"
        echo ""
        echo "Usage: homelab acl inspect <vmid>"
        exit 2
    fi

    if [[ "${HOMELAB_JSON}" != "true" ]]; then
        print_header "ACL Inspection — Container ${vmid}"
    fi

    _acl_inspect_data "$vmid"
}

# ─── Subcommand: grant ──────────────────────────────────────────────
_acl_grant() {
    local vmid="${1:-}"
    if [[ -z "$vmid" ]]; then
        log_error "Missing required argument: <vmid>"
        echo ""
        echo "Usage: homelab acl grant <vmid>"
        exit 2
    fi

    require_root
    require_cmd setfacl "ACL modification tool"

    if [[ "${HOMELAB_JSON}" != "true" ]]; then
        print_header "ACL Grant — Container ${vmid}"
    fi

    # Run inspect first to gather data (suppress output in JSON mode; text inspect prints its report)
    if [[ "${HOMELAB_JSON}" == "true" ]]; then
        # Capture and discard JSON inspect output; we only need _ACL_RESULTS
        _acl_inspect_data "$vmid" > /dev/null
    else
        _acl_inspect_data "$vmid"
    fi

    if [[ ${#_ACL_RESULTS[@]} -eq 0 ]]; then
        return 0
    fi

    local changes_needed=false
    local json_grant_items=""

    for result in "${_ACL_RESULTS[@]}"; do
        IFS='|' read -r host_path container_path owner service_user service_uid mapped_uid access recommendation <<< "$result"

        # Skip if no changes needed
        if [[ "$recommendation" == "OK" ]]; then
            continue
        fi

        # Skip if path is missing
        if [[ "$recommendation" == "Path does not exist on host" ]]; then
            log_warn "Skipping ${host_path}: path does not exist on host."
            continue
        fi

        changes_needed=true

        local cmd_acl_set="setfacl -R -m u:${mapped_uid}:rwX ${host_path}"
        local cmd_acl_default="setfacl -R -d -m u:${mapped_uid}:rwX ${host_path}"

        if [[ "${HOMELAB_JSON}" != "true" ]]; then
            echo ""
            print_section "Bind Mount: ${host_path} → ${container_path}"
            log_info "Mapped UID ${mapped_uid} (${service_user}) needs access to ${host_path}"
            echo "  ${C_DIM}Command:${C_RESET} ${cmd_acl_set}"
            echo "  ${C_DIM}Command:${C_RESET} ${cmd_acl_default}"
        fi

        # Dry-run check
        if dry_run_guard "$cmd_acl_set"; then
            dry_run_guard "$cmd_acl_default" || true
            if [[ "${HOMELAB_JSON}" == "true" ]]; then
                local item
                item="$(json_object \
                    "host_path" "$host_path" \
                    "container_path" "$container_path" \
                    "mapped_uid" "$mapped_uid" \
                    "action" "dry_run" \
                    "command_acl" "$cmd_acl_set" \
                    "command_default" "$cmd_acl_default")"
                if [[ -n "$json_grant_items" ]]; then json_grant_items+=","; fi
                json_grant_items+="$item"
            fi
            continue
        fi

        # Confirm with user
        if ! confirm "Apply ACLs for UID ${mapped_uid} on ${host_path}?"; then
            log_warn "Skipped ${host_path}."
            if [[ "${HOMELAB_JSON}" == "true" ]]; then
                local item
                item="$(json_object \
                    "host_path" "$host_path" \
                    "container_path" "$container_path" \
                    "mapped_uid" "$mapped_uid" \
                    "action" "skipped")"
                if [[ -n "$json_grant_items" ]]; then json_grant_items+=","; fi
                json_grant_items+="$item"
            fi
            continue
        fi

        # Apply ACLs
        log_info "Applying ACLs on ${host_path}..."
        if $cmd_acl_set && $cmd_acl_default; then
            # Verify
            local new_access
            new_access="$(_acl_check_access "$host_path" "$mapped_uid")"
            if [[ "$new_access" != "None" && "$new_access" != "path_missing" ]]; then
                log_ok "ACL applied successfully. New access: ${new_access}"
                if [[ "${HOMELAB_JSON}" == "true" ]]; then
                    local item
                    item="$(json_object \
                        "host_path" "$host_path" \
                        "container_path" "$container_path" \
                        "mapped_uid" "$mapped_uid" \
                        "action" "applied" \
                        "new_access" "$new_access")"
                    if [[ -n "$json_grant_items" ]]; then json_grant_items+=","; fi
                    json_grant_items+="$item"
                fi
            else
                log_error "ACL verification failed for ${host_path}."
                if [[ "${HOMELAB_JSON}" == "true" ]]; then
                    local item
                    item="$(json_object \
                        "host_path" "$host_path" \
                        "container_path" "$container_path" \
                        "mapped_uid" "$mapped_uid" \
                        "action" "verification_failed")"
                    if [[ -n "$json_grant_items" ]]; then json_grant_items+=","; fi
                    json_grant_items+="$item"
                fi
            fi
        else
            log_error "Failed to apply ACLs on ${host_path}."
            if [[ "${HOMELAB_JSON}" == "true" ]]; then
                local item
                item="$(json_object \
                    "host_path" "$host_path" \
                    "container_path" "$container_path" \
                    "mapped_uid" "$mapped_uid" \
                    "action" "failed")"
                if [[ -n "$json_grant_items" ]]; then json_grant_items+=","; fi
                json_grant_items+="$item"
            fi
        fi
    done

    if [[ "$changes_needed" == "false" ]]; then
        if [[ "${HOMELAB_JSON}" != "true" ]]; then
            echo ""
            log_ok "All bind mounts already have correct ACLs."
        fi
    fi

    if [[ "${HOMELAB_JSON}" == "true" ]]; then
        json_start
        json_add_string "vmid" "$vmid"
        json_add_string "action" "grant"
        json_add_raw "results" "[${json_grant_items}]"
        json_end
    fi
}

# ─── Entry point ────────────────────────────────────────────────────
cmd_acl() {
    local subcmd="${1:-}"
    shift 2>/dev/null || true

    case "$subcmd" in
        inspect)
            _acl_inspect "$@"
            ;;
        grant)
            _acl_grant "$@"
            ;;
        -h|--help|help|"")
            _acl_usage
            ;;
        *)
            log_error "Unknown subcommand: ${subcmd}"
            echo ""
            echo "Run 'homelab acl --help' for usage."
            exit 2
            ;;
    esac
}
