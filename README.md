# homelab 🚀

A modular, robust, and beautiful Bash CLI for managing a **Proxmox VE (PVE)** homelab.

It acts as a clean management interface for inspecting host status, storage drives, container resources, bind mounts, and managing ACLs for LXC containers using a safe, user-approved lifecycle.

---

## 📖 Table of Contents
1. [Philosophy](#-philosophy)
2. [Project Layout](#-project-layout)
3. [Installation](#-installation)
4. [Configuration](#-configuration)
5. [Subcommands](#-subcommands)
   - [doctor](#homelab-doctor)
   - [storage](#homelab-storage)
   - [container](#homelab-container)
   - [mount](#homelab-mount)
   - [acl](#homelab-acl)
   - [service](#homelab-service)
6. [Global Flags](#-global-flags)
7. [Developer Guidelines](#-developer-guidelines)

---

## 🧠 Philosophy

Every mutating operation follows a strict, predictable lifecycle:

```text
Inspect ──> Validate ──> Preview ──> Ask (y/n) ──> Apply ──> Verify
```

1. **Inspect**: Read host, configuration, and container state without making changes.
2. **Validate**: Check for prerequisites, UID mismatches, or invalid paths.
3. **Preview**: Show exactly what changes will be applied (e.g., commands to execute).
4. **Ask**: Prompt the user for explicit confirmation before proceeding.
5. **Apply**: Execute changes (skipping if `--dry-run` is active).
6. **Verify**: Perform checks after execution to confirm the desired state was reached.

---

## 📂 Project Layout

The repository is self-contained:

```text
homelab-cli/
├── bin/
│   └── homelab              # Main CLI entry point (subcommand dispatcher)
├── lib/
│   ├── common.sh            # Logging, table, JSON helpers, confirmation, guards
│   ├── doctor.sh            # Health check command
│   ├── storage.sh           # Drive status & future repair functions
│   ├── mount.sh             # LXC bind mount inspector
│   ├── container.sh         # pct wrapper for container info
│   ├── acl.sh               # ACL inspect & grant functions (mutating)
│   └── service.sh           # Port mapping & live IP resolver
├── config/
│   └── homelab.conf         # User configuration (port maps, root paths)
├── install.sh               # Symlink-based installer script
└── README.md                # This documentation
```

---

## ⚙️ Installation

To install `homelab`, run the self-contained installation script:

```bash
# Clone the repository to a location of your choice (e.g., ~/homelab-cli)
cd ~/homelab-cli

# Run the installer (requires root/sudo to place a symlink under /usr/local/bin)
sudo ./install.sh
```

To uninstall and remove the symlink:

```bash
sudo ./install.sh --uninstall
```

---

## 🔧 Configuration

All settings are managed via [config/homelab.conf](file:///home/priyranjan/myprojects/homelab-cli/config/homelab.conf):

```bash
# Root path for shared data
DATA_ROOT="/srv/data"

# Subdirectories expected under DATA_ROOT
DATA_DIRS="media downloads documents photos backups"

# Service names for URL generation (vmid:name, replace spaces with underscores)
SERVICE_NAMES="100:Plex 101:Homer 102:Download_Gateway 103:NextExplorer"

# Service port mappings (vmid:port)
SERVICE_PORTS="100:32400 101:8010 102:8080 103:3000"

# Default UID offset for unprivileged LXC containers (Proxmox default is 100000)
ACL_UID_OFFSET="100000"
```

---

## 🛠️ Subcommands

### `homelab doctor`
Runs a read-only diagnostics checklist of node status, storage health, filesystem types, tool availability, and container statuses.

```bash
homelab doctor
```

Output:
```text
Homelab Doctor
==============

Host
────
  Hostname : spaceship
  PVE      : pve-manager/8.2.2 (running kernel: 6.8.4-2-pve)

Storage
───────
  NVMe     : ✓ Detected
             nvme0n1 disk nvme   476.9G WDC WDS500G2B0C
  SATA     : ✓ Detected
             sda     disk sata   3.6T   ST4000VN008-2DR1
  DATA_ROOT: ✓ /srv/data mounted

Filesystem
──────────
  /srv/data: ✓ ext4

ACL Tools
─────────
  getfacl  : ✓ Installed
  setfacl  : ✓ Installed

Containers
──────────
  VMID            Status          Name            
  ──────────────  ──────────────  ────────────────
  100             running         plex            
  101             stopped         homer           
  103             running         nextexplorer    

Warnings
────────
  None
```

---

### `homelab storage status`
Displays block storage information and Proxmox storage pool utilization.

```bash
homelab storage status
```

---

### `homelab container list`
Displays running and stopped containers including their VMID, Hostname, CPU Cores, RAM, IP Address, and status.

```bash
homelab container list
```

---

### `homelab mount list`
Finds and prints bind mounts mapped to LXC containers from the PVE host.

```bash
homelab mount list
```

---

### `homelab acl`
Inspects and modifies filesystems permissions on PVE host data paths bound to LXC containers.

#### Inspect ACLs:
Inspects whether the unprivileged container mapping UID has access to host paths.
```bash
homelab acl inspect 103
```

Output:
```text
ACL Inspection — Container 103
==============================
──────────────────────────────────────────────────
  Container:           103
  Hostname:            nextexplorer
  Bind Mount:          /srv/data/media → /media
  Filesystem Owner:    root:root
  Service User:        explorer (UID 1000)
  Mapped Host UID:     101000
  Current Access:      None
  Recommendation:      Grant RWX
──────────────────────────────────────────────────
```

#### Grant ACLs:
Grants read, write, and execute permissions recursively, including **Default ACLs** so newly created files inherit access permissions.
```bash
sudo homelab acl grant 103
```

---

### `homelab service urls`
Generates external web URLs using live IP detection (retrieved directly from the container namespace via API or guest command fallback).

```bash
homelab service urls
```

---

## 🌐 Global Flags

Every command supports standard flags:

* `--json`: Outputs structured JSON for integration with dashboards or scripting.
  ```bash
  homelab --json container list | jq .
  ```
* `--dry-run`: Previews modifying commands without making system changes.
  ```bash
  sudo homelab acl grant 103 --dry-run
  ```
* `--no-color`: Disables tput colors for logging or file output.
  ```bash
  homelab --no-color doctor > status.log
  ```

---

## 💻 Developer Guidelines

When contributing modules, follow these rules:

1. **Isolation**: Subcommands must reside in `lib/<name>.sh` and define `cmd_<name>()`. No direct executions in modules.
2. **Helper Usage**: Always use logging (`log_info`, `log_ok`, `log_warn`, `log_error`) and UI layouts (`print_header`, `print_section`, `print_table_header`, `print_table_row`) from `lib/common.sh`.
3. **Piping & Encodings**: Avoid using `tr` for UTF-8 or multi-byte characters; use `_repeat_char`.
4. **Stderr Safety**: Keep warnings, info messages, and interactive logs redirected to stderr or omitted entirely when `--json` is active, keeping stdout pure JSON.
5. **Robust Fallbacks**: Never assume `pct`, `getfacl`, or configuration keys are present. Gracefully warn and degrade output.
