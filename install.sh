#!/usr/bin/env bash
# install.sh — Install or uninstall the homelab CLI tool
# Usage: sudo ./install.sh [--uninstall]
set -euo pipefail

# ─── Colors (self-contained, no dependency on common.sh) ─────────────
if [[ -t 1 ]] && command -v tput &>/dev/null && [[ $(tput colors 2>/dev/null || echo 0) -ge 8 ]]; then
    C_RESET="\033[0m"
    C_BOLD="\033[1m"
    C_RED="\033[31m"
    C_GREEN="\033[32m"
    C_YELLOW="\033[33m"
    C_CYAN="\033[36m"
else
    C_RESET="" C_BOLD="" C_RED="" C_GREEN="" C_YELLOW="" C_CYAN=""
fi

info()  { echo -e "${C_CYAN}${C_BOLD}[INFO]${C_RESET}  $*"; }
ok()    { echo -e "${C_GREEN}${C_BOLD}[ OK ]${C_RESET}  $*"; }
warn()  { echo -e "${C_YELLOW}${C_BOLD}[WARN]${C_RESET}  $*"; }
error() { echo -e "${C_RED}${C_BOLD}[ERR ]${C_RESET}  $*" >&2; }

# ─── Resolve project root (directory containing this script) ─────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOMELAB_BIN="${SCRIPT_DIR}/bin/homelab"
SYMLINK_PATH="/usr/local/bin/homelab"

# ─── Check bash version ≥ 4 ─────────────────────────────────────────
if (( BASH_VERSINFO[0] < 4 )); then
    error "Bash 4.0 or later is required (found: ${BASH_VERSION})."
    error "Please upgrade bash and try again."
    exit 1
fi

# ─── Root / sudo check ──────────────────────────────────────────────
need_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (or with sudo)."
        error "Usage: sudo $0 $*"
        exit 1
    fi
}

# ─── Uninstall ───────────────────────────────────────────────────────
do_uninstall() {
    need_root "--uninstall"

    info "Uninstalling homelab CLI …"

    if [[ -L "$SYMLINK_PATH" ]]; then
        rm -f "$SYMLINK_PATH"
        ok "Removed symlink ${SYMLINK_PATH}"
    elif [[ -e "$SYMLINK_PATH" ]]; then
        warn "${SYMLINK_PATH} exists but is not a symlink — skipping removal."
        warn "Remove it manually if needed."
    else
        warn "${SYMLINK_PATH} does not exist — nothing to remove."
    fi

    ok "Uninstall complete."
}

# ─── Install ─────────────────────────────────────────────────────────
do_install() {
    need_root

    info "Installing homelab CLI …"

    # Verify the main entry point exists
    if [[ ! -f "$HOMELAB_BIN" ]]; then
        error "Entry point not found: ${HOMELAB_BIN}"
        error "Make sure you are running install.sh from the project root."
        exit 1
    fi

    # Make bin/homelab executable
    chmod +x "$HOMELAB_BIN"
    ok "Made ${HOMELAB_BIN} executable."

    # Create symlink
    ln -sf "$HOMELAB_BIN" "$SYMLINK_PATH"
    ok "Created symlink: ${SYMLINK_PATH} → ${HOMELAB_BIN}"

    echo ""
    echo -e "${C_GREEN}${C_BOLD}✔ homelab CLI installed successfully!${C_RESET}"
    echo -e "  Run ${C_CYAN}homelab --help${C_RESET} to get started."
    echo ""
}

# ─── Main ────────────────────────────────────────────────────────────
case "${1:-}" in
    --uninstall|-u)
        do_uninstall
        ;;
    --help|-h)
        echo "Usage: sudo $0 [--uninstall]"
        echo ""
        echo "  (no args)      Install homelab CLI to ${SYMLINK_PATH}"
        echo "  --uninstall    Remove the symlink from ${SYMLINK_PATH}"
        echo "  --help         Show this help"
        ;;
    "")
        do_install
        ;;
    *)
        error "Unknown option: $1"
        echo "Usage: sudo $0 [--uninstall]"
        exit 1
        ;;
esac
