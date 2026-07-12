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

_normalize_path() {
    local path="$1"
    local IFS='/'
    local -a parts
    read -ra parts <<< "$path"
    local -a output=()
    for part in "${parts[@]}"; do
        if [[ -z "$part" || "$part" == "." ]]; then
            continue
        fi
        if [[ "$part" == ".." ]]; then
            if (( ${#output[@]} > 0 )); then
                unset "output[$(( ${#output[@]} - 1 ))]"
                output=("${output[@]}")
            fi
        else
            output+=("$part")
        fi
    done
    echo "/${output[*]}"
}

_acl_expand_mounts() {
    local mounts="$1"
    local -A seen
    
    # First pass: mark all explicit parent container paths as seen
    while IFS='|' read -r host_path container_path; do
        [[ -z "$host_path" ]] && continue
        seen["$container_path"]=1
    done <<< "$mounts"
    
    # Second pass: output parents, and find sub-mounts / symlinks
    while IFS='|' read -r host_path container_path; do
        [[ -z "$host_path" ]] && continue
        echo "${host_path}|${container_path}|parent|"
        
        if [[ -d "$host_path" ]]; then
            # 1. Sub-mounts
            local submounts
            submounts="$(awk -v p="${host_path}/" 'index($5, p) == 1 {print $5}' /proc/self/mountinfo 2>/dev/null || true)"
            while IFS= read -r sm; do
                [[ -z "$sm" ]] && continue
                [[ "$sm" == "$host_path" ]] && continue
                local rel_path="${sm#$host_path/}"
                local container_sm="${container_path}/${rel_path}"
                container_sm="$(echo "$container_sm" | tr -s '/')"
                
                # Only output if not explicitly mounted in config
                if [[ -z "${seen["$container_sm"]:-}" ]]; then
                    echo "${sm}|${container_sm}|submount|"
                    seen["$container_sm"]=1
                fi
            done <<< "$submounts"
            
            # 2. Symlinks
            local symlinks
            symlinks="$(find "$host_path" -type l 2>/dev/null || true)"
            while IFS= read -r sl; do
                [[ -z "$sl" ]] && continue
                local target_text
                target_text="$(readlink "$sl")"
                local resolved_host
                resolved_host="$(readlink -f "$sl")"
                
                [[ -z "$resolved_host" ]] && continue
                [[ ! -e "$resolved_host" ]] && continue
                
                local norm_resolved
                norm_resolved="$(_normalize_path "$resolved_host")"
                local norm_host_path
                norm_host_path="$(_normalize_path "$host_path")"
                
                if [[ "$norm_resolved" != "$norm_host_path"/* && "$norm_resolved" != "$norm_host_path" ]]; then
                    local container_target=""
                    if [[ "$target_text" == /* ]]; then
                        container_target="$target_text"
                    else
                        local sl_dir_host="$(dirname "$sl")"
                        local rel_sl_dir="${sl_dir_host#$host_path}"
                        local container_sl_dir="${container_path}/${rel_sl_dir}"
                        container_target="${container_sl_dir}/${target_text}"
                        container_target="$(_normalize_path "$container_target")"
                    fi
                    
                    if [[ -z "${seen["$container_target"]:-}" ]]; then
                        echo "${norm_resolved}|${container_target}|symlink|${sl}"
                        seen["$container_target"]=1
                    fi
                fi
            done <<< "$symlinks"
        fi
    done <<< "$mounts"
}

# _acl_mount_in_config <vmid> <host_path> <container_path>
#   Check if a mount entry already exists in the Proxmox LXC config.
_acl_mount_in_config() {
    local vmid="$1"
    local host_path="$2"
    local container_path="$3"
    local config_file="/etc/pve/lxc/${vmid}.conf"
    local dest="${container_path#/}"

    [[ ! -f "$config_file" ]] && return 1

    # Check for lxc.mount.entry with this source and destination
    if grep -q "^lxc\.mount\.entry:.*${host_path}[[:space:]]\+${dest}[[:space:]]" "$config_file" 2>/dev/null; then
        return 0
    fi

    return 1
}

# _acl_add_mount_entry <vmid> <host_path> <container_path>
#   Add a lxc.mount.entry line to the Proxmox LXC config file.
_acl_add_mount_entry() {
    local vmid="$1"
    local host_path="$2"
    local container_path="$3"
    local config_file="/etc/pve/lxc/${vmid}.conf"
    local dest="${container_path#/}"

    local entry="lxc.mount.entry: ${host_path} ${dest} none bind,optional,create=dir 0 0"

    # Already present?
    if _acl_mount_in_config "$vmid" "$host_path" "$container_path"; then
        return 0
    fi

    if echo "$entry" >> "$config_file"; then
        return 0
    else
        return 1
    fi
}

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

# _acl_detect_service_users <vmid> <config>
#   Detect the primary service users inside the container by checking:
#   1. Users matching the service names configured in homelab.conf (supports comma-separated list)
#   2. A user matching the container hostname
#   3. Standard UID 1000 user
#   Returns a space-separated list of "username:uid" pairs.
_acl_detect_service_users() {
    local vmid="$1"
    local config="$2"

    local hostname
    hostname="$(_acl_get_hostname "$config")"

    # Get service names list (comma-separated, convert to list)
    local svc_names_str=""
    if [[ -n "${SERVICE_NAMES:-}" ]]; then
        svc_names_str="$(map_lookup "${SERVICE_NAMES}" "$vmid" 2>/dev/null | tr 'A-Z' 'a-z' || true)"
        svc_names_str="${svc_names_str//_/-}"
    fi

    # Split by comma
    local -a search_users=()
    if [[ -n "$svc_names_str" ]]; then
        IFS=',' read -r -a parsed_names <<< "$svc_names_str"
        for name in "${parsed_names[@]}"; do
            search_users+=("$name")
        done
    fi

    # Add hostname (lowercased) if not already in search_users
    if [[ -n "$hostname" ]]; then
        local hn_lower
        hn_lower="$(echo "$hostname" | tr 'A-Z' 'a-z')"
        local found_hn=false
        for u in "${search_users[@]}"; do
            if [[ "$u" == "$hn_lower" ]]; then
                found_hn=true
                break
            fi
        done
        if [[ "$found_hn" == "false" ]]; then
            search_users+=("$hn_lower")
        fi
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

    local -a matched_users=()
    if [[ "$read_success" == "true" ]]; then
        for u in "${search_users[@]}"; do
            local line
            line="$(echo "$passwd_content" | awk -F: -v username="$u" '$1 == username { print $1":"$3; exit }' 2>/dev/null || true)"
            if [[ -n "$line" ]]; then
                matched_users+=("$line")
            fi
        done

        # If no users matched, fall back to UID 1000
        if [[ ${#matched_users[@]} -eq 0 ]]; then
            local line
            line="$(echo "$passwd_content" | awk -F: '$3 == 1000 { print $1":"$3; exit }' 2>/dev/null || true)"
            if [[ -n "$line" ]]; then
                matched_users+=("$line")
            fi
        fi
    fi

    # Final fallback if absolutely nothing works
    if [[ ${#matched_users[@]} -eq 0 ]]; then
        matched_users+=("unknown:1000")
    fi

    echo "${matched_users[*]}"
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
    done || true
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
    require_cmd findmnt "Findmnt tool"
    require_cmd mountpoint "Mountpoint tool"

    local config
    config="$(_acl_get_config "$vmid")"

    local hostname
    hostname="$(_acl_get_hostname "$config")"

    # Check bind mounts
    local mounts_raw
    mounts_raw="$(_acl_parse_bind_mounts "$config")"
    if [[ -z "$mounts_raw" ]]; then
        if [[ "${HOMELAB_JSON}" == "true" ]]; then
            json_start
            json_add_string "vmid" "$vmid"
            json_add_string "hostname" "$hostname"
            json_add_raw "bind_mounts" "[]"
            json_add_string "message" "No bind mounts found"
            json_end
        else
            log_warn "No bind mounts found for container ${vmid} (${hostname})."
            log_info "To add a bind mount in Proxmox, run on the host:"
            log_info "  pct set ${vmid} -mp0 /srv/data/yourfolder,mp=/yourfolder"
        fi
        return 0
    fi

    local mounts
    mounts="$(_acl_expand_mounts "$mounts_raw")"

    # Determine UID mapping
    local is_unprivileged=false
    local uid_offset=0
    if _acl_is_unprivileged "$config"; then
        is_unprivileged=true
        uid_offset="$(_acl_get_uid_offset "$config")"
    fi

    # Detect service users
    local service_users_list
    service_users_list="$(_acl_detect_service_users "$vmid" "$config")"

    local is_running=false
    if pct status "$vmid" 2>/dev/null | grep -q "running"; then
        is_running=true
    fi


    if [[ "${HOMELAB_JSON}" != "true" ]]; then
        print_section "Container Info"
        printf "  ${C_BOLD}%-20s${C_RESET} %s\n" "VMID:" "$vmid"
        printf "  ${C_BOLD}%-20s${C_RESET} %s\n" "Hostname:" "$hostname"
    fi

    _ACL_RESULTS=()

    # JSON array accumulator
    local json_items=""

    while IFS='|' read -r host_path container_path type extra_info; do
        [[ -z "$host_path" ]] && continue
        local owner
        owner="$(_acl_get_owner "$host_path")"

        for service_info in ${service_users_list}; do
            local service_user="${service_info%%:*}"
            local service_uid="${service_info##*:}"
            local mapped_uid=$(( service_uid + uid_offset ))
            local access
            access="$(_acl_check_access "$host_path" "$mapped_uid")"

            # Check if mount is active and/or configured (only for submount and symlink)
            local mount_active=true
            local mount_configured=true
            if [[ "$type" == "submount" || "$type" == "symlink" ]]; then
                # Check if configured in Proxmox LXC config
                if ! _acl_mount_in_config "$vmid" "$host_path" "$container_path"; then
                    mount_configured=false
                fi

                # Check if active inside the running container
                if [[ "$is_running" == "true" ]]; then
                    local container_pid
                    container_pid="$(lxc-info -n "$vmid" -p -H 2>/dev/null || true)"
                    if [[ -n "$container_pid" && "$container_pid" != "0" && -f "/proc/${container_pid}/mountinfo" ]]; then
                        if ! awk -v mp="${container_path}" '$5 == mp {exit 0} END {exit 1}' "/proc/${container_pid}/mountinfo" 2>/dev/null; then
                            mount_active=false
                        fi
                    else
                        mount_active=false
                    fi
                else
                    # Container is stopped — can't verify, trust config
                    mount_active="$mount_configured"
                fi
            fi

            # Determine recommendation
            local recommendation="OK"
            local needs_access=false
            if [[ "$access" == "path_missing" ]]; then
                recommendation="Path does not exist on host"
                access="N/A"
            elif [[ "$access" == "None" ]] || { ! echo "$access" | grep -qP '^r..[xX]?$' 2>/dev/null || [[ "$access" != *r* ]] || [[ "$access" != *w* ]]; }; then
                needs_access=true
            fi

            if [[ "$recommendation" != "Path does not exist on host" ]]; then
                if [[ "$mount_active" == "true" ]]; then
                    if [[ "$needs_access" == "true" ]]; then
                        recommendation="Grant RWX"
                    else
                        recommendation="OK"
                    fi
                elif [[ "$mount_configured" == "true" ]]; then
                    if [[ "$needs_access" == "true" ]]; then
                        recommendation="Restart container & Grant RWX"
                    else
                        recommendation="Restart container"
                    fi
                else
                    if [[ "$needs_access" == "true" ]]; then
                        recommendation="Add mount entry & Grant RWX"
                    else
                        recommendation="Add mount entry"
                    fi
                fi
            fi

            # Store result for grant reuse
            _ACL_RESULTS+=("${host_path}|${container_path}|${owner}|${service_user}|${service_uid}|${mapped_uid}|${access}|${recommendation}|${type}|${extra_info}")

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
                json_add_string "type" "$type"
                json_add_string "extra_info" "$extra_info"
                item_buf="$(_JSON_BUF="$_JSON_BUF" json_end)"
                _JSON_BUF="$_OUTER_JSON_BUF"
                _JSON_FIRST="$_OUTER_JSON_FIRST"

                if [[ -n "$json_items" ]]; then
                    json_items+=","
                fi
                json_items+="$item_buf"
            else
                print_separator
                
                if [[ "$type" == "submount" ]]; then
                    printf "  ${C_BOLD}%-20s${C_RESET} %s → %s (${C_YELLOW}Sub-mount${C_RESET})\n" "Bind Mount:" "$host_path" "$container_path"
                elif [[ "$type" == "symlink" ]]; then
                    printf "  ${C_BOLD}%-20s${C_RESET} %s → %s (${C_YELLOW}Symlink target of %s${C_RESET})\n" "Bind Mount:" "$host_path" "$container_path" "$extra_info"
                else
                    printf "  ${C_BOLD}%-20s${C_RESET} %s → %s\n" "Bind Mount:" "$host_path" "$container_path"
                fi
                
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
        done
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

    local config_changed=false

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
        local host_path container_path owner service_user service_uid mapped_uid access recommendation type extra_info
        IFS='|' read -r host_path container_path owner service_user service_uid mapped_uid access recommendation type extra_info <<< "$result"

        # Skip if no changes needed
        if [[ "$recommendation" == "OK" ]]; then
            continue
        fi

        # Skip if only a restart is needed (config already has the entry)
        if [[ "$recommendation" == "Restart container" ]]; then
            continue
        fi

        # Skip if path is missing
        if [[ "$recommendation" == "Path does not exist on host" ]]; then
            log_warn "Skipping ${host_path}: path does not exist on host."
            continue
        fi

        changes_needed=true

        local needs_mount_entry=false
        local needs_acl=false
        if [[ "$recommendation" == *"Add mount entry"* ]]; then
            needs_mount_entry=true
        fi
        if [[ "$recommendation" == *"Grant RWX"* ]]; then
            needs_acl=true
        fi

        local cmd_acl_set="setfacl -R -m u:${mapped_uid}:rwX ${host_path}"
        local cmd_acl_default="setfacl -R -d -m u:${mapped_uid}:rwX ${host_path}"
        local dest="${container_path#/}"
        local cmd_config="echo 'lxc.mount.entry: ${host_path} ${dest} none bind,optional,create=dir 0 0' >> /etc/pve/lxc/${vmid}.conf"

        if [[ "${HOMELAB_JSON}" != "true" ]]; then
            echo ""
            if [[ "$type" == "submount" ]]; then
                print_section "Sub-mount: ${host_path} → ${container_path}"
            elif [[ "$type" == "symlink" ]]; then
                print_section "Symlink target: ${host_path} (target of ${extra_info}) → ${container_path}"
            else
                print_section "Bind Mount: ${host_path} → ${container_path}"
            fi

            if [[ "$needs_mount_entry" == "true" ]]; then
                log_info "Will add mount entry to Proxmox config"
                echo "  ${C_DIM}Config:${C_RESET} lxc.mount.entry: ${host_path} ${dest} none bind,optional,create=dir 0 0"
            fi
            if [[ "$needs_acl" == "true" ]]; then
                log_info "Mapped UID ${mapped_uid} (${service_user}) needs access to ${host_path}"
                echo "  ${C_DIM}Command:${C_RESET} ${cmd_acl_set}"
                echo "  ${C_DIM}Command:${C_RESET} ${cmd_acl_default}"
            fi
        fi

        # Dry-run check
        if [[ "${HOMELAB_DRY_RUN}" == "true" ]]; then
            if [[ "$needs_mount_entry" == "true" ]]; then
                dry_run_guard "$cmd_config"
            fi
            if [[ "$needs_acl" == "true" ]]; then
                dry_run_guard "${cmd_acl_set}"
                dry_run_guard "${cmd_acl_default}"
            fi

            if [[ "${HOMELAB_JSON}" == "true" ]]; then
                local item
                item="$(json_object \
                    "host_path" "$host_path" \
                    "container_path" "$container_path" \
                    "mapped_uid" "$mapped_uid" \
                    "type" "$type" \
                    "action" "dry_run" \
                    "needs_mount_entry" "$needs_mount_entry" \
                    "needs_acl" "$needs_acl")"
                if [[ -n "$json_grant_items" ]]; then json_grant_items+=","; fi
                json_grant_items+="$item"
            fi
            continue
        fi

        # Confirm with user
        local confirm_msg="Apply changes for ${host_path}?"
        if [[ "$needs_mount_entry" == "true" && "$needs_acl" == "true" ]]; then
            confirm_msg="Add mount config entry and apply ACLs for ${host_path}?"
        elif [[ "$needs_mount_entry" == "true" ]]; then
            confirm_msg="Add mount config entry for ${host_path}?"
        fi

        if ! confirm "$confirm_msg"; then
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

        # Apply changes
        local mount_success=true
        if [[ "$needs_mount_entry" == "true" ]]; then
            log_info "Adding mount entry to Proxmox config..."
            if _acl_add_mount_entry "$vmid" "$host_path" "$container_path"; then
                log_ok "Mount entry added to /etc/pve/lxc/${vmid}.conf"
                config_changed=true
            else
                log_error "Failed to write mount entry to config."
                mount_success=false
            fi
        fi

        local acl_success=true
        if [[ "$needs_acl" == "true" && "$mount_success" == "true" ]]; then
            log_info "Applying ACLs on ${host_path}..."
            if eval "$cmd_acl_set" && eval "$cmd_acl_default"; then
                # Verify
                local new_access
                new_access="$(_acl_check_access "$host_path" "$mapped_uid")"
                if [[ "$new_access" != "None" && "$new_access" != "path_missing" ]]; then
                    log_ok "ACL applied successfully. New access: ${new_access}"
                else
                    log_error "ACL verification failed for ${host_path}."
                    acl_success=false
                fi
            else
                log_error "Failed to apply ACLs on ${host_path}."
                acl_success=false
            fi
        fi

        if [[ "$mount_success" == "true" && "$acl_success" == "true" ]]; then
            if [[ "${HOMELAB_JSON}" == "true" ]]; then
                local item
                item="$(json_object \
                    "host_path" "$host_path" \
                    "container_path" "$container_path" \
                    "mapped_uid" "$mapped_uid" \
                    "type" "$type" \
                    "action" "applied")"
                if [[ -n "$json_grant_items" ]]; then json_grant_items+=","; fi
                json_grant_items+="$item"
            fi
        else
            if [[ "${HOMELAB_JSON}" == "true" ]]; then
                local item
                item="$(json_object \
                    "host_path" "$host_path" \
                    "container_path" "$container_path" \
                    "mapped_uid" "$mapped_uid" \
                    "type" "$type" \
                    "action" "failed")"
                if [[ -n "$json_grant_items" ]]; then json_grant_items+=","; fi
                json_grant_items+="$item"
            fi
        fi
    done

    # If config was changed, prompt for container restart
    if [[ "$config_changed" == "true" ]] && [[ "${HOMELAB_DRY_RUN}" != "true" ]]; then
        if [[ "${HOMELAB_JSON}" != "true" ]]; then
            echo ""
            log_info "Container config has been updated. A restart is required for the new mounts to take effect."
            if confirm "Restart container ${vmid} now?"; then
                log_info "Restarting container ${vmid}..."
                if pct reboot "$vmid" 2>/dev/null; then
                    log_ok "Container ${vmid} restarted successfully."
                else
                    log_error "Failed to restart container ${vmid}. Please restart manually: pct reboot ${vmid}"
                fi
            else
                log_warn "Restart skipped. Run 'pct reboot ${vmid}' to apply mount changes."
            fi
        fi
    fi

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
