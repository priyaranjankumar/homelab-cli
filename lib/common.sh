#!/usr/bin/env bash
# homelab-cli/lib/common.sh — Shared utilities for all modules
# Sourced by bin/homelab; never executed directly.

set -euo pipefail

# ─── Version ─────────────────────────────────────────────────────────
HOMELAB_VERSION="1.0.0"

# ─── Resolve paths ───────────────────────────────────────────────────
# HOMELAB_ROOT is set by the entry point before sourcing this file.
HOMELAB_LIB="${HOMELAB_ROOT}/lib"
HOMELAB_CONFIG="${HOMELAB_ROOT}/config/homelab.conf"

# ─── Global flags (set by entry point) ───────────────────────────────
HOMELAB_JSON="${HOMELAB_JSON:-false}"
HOMELAB_DRY_RUN="${HOMELAB_DRY_RUN:-false}"
HOMELAB_NO_COLOR="${HOMELAB_NO_COLOR:-false}"

# ─── Colors ──────────────────────────────────────────────────────────
_setup_colors() {
    if [[ "${HOMELAB_NO_COLOR}" == "true" ]] || [[ ! -t 1 ]]; then
        C_RESET="" C_BOLD="" C_DIM=""
        C_RED="" C_GREEN="" C_YELLOW="" C_CYAN="" C_WHITE=""
    else
        C_RESET="$(tput sgr0    2>/dev/null || true)"
        C_BOLD="$(tput bold     2>/dev/null || true)"
        C_DIM="$(tput dim       2>/dev/null || true)"
        C_RED="$(tput setaf 1   2>/dev/null || true)"
        C_GREEN="$(tput setaf 2 2>/dev/null || true)"
        C_YELLOW="$(tput setaf 3 2>/dev/null || true)"
        C_CYAN="$(tput setaf 6  2>/dev/null || true)"
        C_WHITE="$(tput setaf 7 2>/dev/null || true)"
    fi
}

# ─── Logging ─────────────────────────────────────────────────────────
log_info()  { echo "${C_CYAN}${C_BOLD}INFO${C_RESET}  $*"; }
log_ok()    { echo "${C_GREEN}${C_BOLD}  ✓${C_RESET}  $*"; }
log_warn()  { echo "${C_YELLOW}${C_BOLD}WARN${C_RESET}  $*"; }
log_error() { echo "${C_RED}${C_BOLD}ERROR${C_RESET} $*" >&2; }

_repeat_char() {
    local char="$1"
    local count="$2"
    local val=""
    for ((i=0; i<count; i++)); do
        val+="$char"
    done
    echo -n "$val"
}

# ─── Section formatting ─────────────────────────────────────────────
print_header() {
    # Usage: print_header "Title"
    local title="$1"
    echo ""
    echo "${C_BOLD}${C_WHITE}${title}${C_RESET}"
    printf '%*s\n' "${#title}" '' | tr ' ' '='
}

print_section() {
    # Usage: print_section "Section Name"
    local name="$1"
    echo ""
    echo "${C_BOLD}${C_WHITE}${name}${C_RESET}"
    _repeat_char "─" "${#name}"
    echo ""
}

print_separator() {
    printf '%.0s─' {1..50}
    echo ""
}

# ─── Table printing ─────────────────────────────────────────────────
# Usage:
#   print_table_header "Col1" "Col2" "Col3"
#   print_table_row    "val1" "val2" "val3"
#
# Widths are determined by the header call.
declare -a _TABLE_WIDTHS=()

print_table_header() {
    _TABLE_WIDTHS=()
    local header=""
    local separator=""
    for col in "$@"; do
        local w=$(( ${#col} + 6 ))
        # Minimum column width of 16
        (( w < 16 )) && w=16
        _TABLE_WIDTHS+=("$w")
        header+="$(printf "%-${w}s" "${C_BOLD}${col}${C_RESET}")  "
        separator+="$(_repeat_char "─" "$w")  "
    done
    echo "$header"
    echo "$separator"
}

print_table_row() {
    local i=0
    local row=""
    for val in "$@"; do
        local w="${_TABLE_WIDTHS[$i]:-16}"
        row+="$(printf "%-${w}s" "$val")  "
        (( i++ )) || true
    done
    echo "$row"
}

# ─── JSON output helpers ────────────────────────────────────────────
# Lightweight JSON builder for --json mode.
# For complex structures, we build an associative approach using jq if available,
# otherwise fall back to manual construction.

_JSON_BUF=""
_JSON_FIRST="true"

json_start() {
    _JSON_BUF="{"
    _JSON_FIRST="true"
}

json_start_array() {
    _JSON_BUF="["
    _JSON_FIRST="true"
}

json_add_string() {
    # Usage: json_add_string "key" "value"
    local key="$1" val="$2"
    # Escape special characters in value
    val="${val//\\/\\\\}"
    val="${val//\"/\\\"}"
    val="${val//$'\n'/\\n}"
    val="${val//$'\t'/\\t}"
    if [[ "${_JSON_FIRST}" == "true" ]]; then
        _JSON_FIRST="false"
    else
        _JSON_BUF+=","
    fi
    _JSON_BUF+="\"${key}\":\"${val}\""
}

json_add_number() {
    # Usage: json_add_number "key" value
    local key="$1" val="$2"
    if [[ "${_JSON_FIRST}" == "true" ]]; then
        _JSON_FIRST="false"
    else
        _JSON_BUF+=","
    fi
    _JSON_BUF+="\"${key}\":${val}"
}

json_add_bool() {
    # Usage: json_add_bool "key" true/false
    local key="$1" val="$2"
    if [[ "${_JSON_FIRST}" == "true" ]]; then
        _JSON_FIRST="false"
    else
        _JSON_BUF+=","
    fi
    _JSON_BUF+="\"${key}\":${val}"
}

json_add_raw() {
    # Usage: json_add_raw "key" '["a","b"]'
    local key="$1" val="$2"
    if [[ "${_JSON_FIRST}" == "true" ]]; then
        _JSON_FIRST="false"
    else
        _JSON_BUF+=","
    fi
    _JSON_BUF+="\"${key}\":${val}"
}

json_add_array_item() {
    # Usage: json_add_array_item '{"id":100}'
    local val="$1"
    if [[ "${_JSON_FIRST}" == "true" ]]; then
        _JSON_FIRST="false"
    else
        _JSON_BUF+=","
    fi
    _JSON_BUF+="${val}"
}

json_end() {
    _JSON_BUF+="}"
    echo "${_JSON_BUF}"
    _JSON_BUF=""
    _JSON_FIRST="true"
}

json_end_array() {
    _JSON_BUF+="]"
    echo "${_JSON_BUF}"
    _JSON_BUF=""
    _JSON_FIRST="true"
}

# Build a complete JSON object from key=value pairs for simple cases
json_object() {
    # Usage: json_object "key1" "val1" "key2" "val2"
    local buf="{"
    local first="true"
    while (( $# >= 2 )); do
        local key="$1" val="$2"
        shift 2
        val="${val//\\/\\\\}"
        val="${val//\"/\\\"}"
        if [[ "${first}" == "true" ]]; then first="false"; else buf+=","; fi
        buf+="\"${key}\":\"${val}\""
    done
    buf+="}"
    echo "${buf}"
}

# ─── Confirmation prompt ────────────────────────────────────────────
confirm() {
    # Usage: confirm "Do something dangerous?" || return
    local prompt="${1:-Continue?}"
    if [[ "${HOMELAB_DRY_RUN}" == "true" ]]; then
        log_info "DRY RUN — skipping confirmation: ${prompt}"
        return 1  # Don't proceed in dry-run
    fi
    echo ""
    printf "%s [y/N] " "${prompt}"
    read -r answer
    case "${answer}" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

# ─── Guards ──────────────────────────────────────────────────────────
require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        log_error "This command must be run as root."
        exit 1
    fi
}

require_cmd() {
    # Usage: require_cmd "pct" "Proxmox container toolkit"
    local cmd="$1"
    local desc="${2:-$cmd}"
    if ! command -v "$cmd" &>/dev/null; then
        log_error "Required command not found: ${cmd} (${desc})"
        exit 3
    fi
}

check_pve() {
    if ! command -v pveversion &>/dev/null; then
        log_warn "Not running on a Proxmox VE host (pveversion not found)."
        log_warn "Some commands may produce incomplete output."
        return 1
    fi
    return 0
}

# ─── Dry-run guard ──────────────────────────────────────────────────
dry_run_guard() {
    # Usage: dry_run_guard "setfacl -m u:101000:rwX /srv/data"
    # Returns 0 (true) if dry-run is active — caller should skip the action.
    local action="$1"
    if [[ "${HOMELAB_DRY_RUN}" == "true" ]]; then
        echo "  ${C_DIM}DRY RUN → would execute:${C_RESET} ${action}"
        return 0
    fi
    return 1
}

# ─── Config loader ──────────────────────────────────────────────────
load_config() {
    if [[ -f "${HOMELAB_CONFIG}" ]]; then
        # shellcheck source=/dev/null
        source "${HOMELAB_CONFIG}"
    else
        log_warn "Config file not found: ${HOMELAB_CONFIG}"
        log_warn "Using defaults."
    fi

    # Apply defaults
    DATA_ROOT="${DATA_ROOT:-/srv/data}"
    DATA_DIRS="${DATA_DIRS:-media downloads documents photos backups}"
    SERVICE_PORTS="${SERVICE_PORTS:-}"
    SERVICE_NAMES="${SERVICE_NAMES:-}"
}

# ─── Helper: get value from colon-separated map ─────────────────────
# Usage: map_lookup "100:Plex 101:Homer" "100"  →  "Plex"
map_lookup() {
    local map="$1" key="$2"
    for entry in ${map}; do
        local k="${entry%%:*}"
        local v="${entry#*:}"
        if [[ "$k" == "$key" ]]; then
            echo "$v"
            return 0
        fi
    done
    return 1
}

# ─── Initialize colors on source ────────────────────────────────────
_setup_colors
