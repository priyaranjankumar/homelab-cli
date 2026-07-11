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

### 📦 Pushing to GitHub (Optional)

If you want to push this repository to your own GitHub account using the GitHub CLI (`gh`):

```bash
# Initialize git and add files
git init
git add .
git commit -m "Initial commit of homelab-cli"

# Create a public repository and push
gh repo create homelab-cli --public --source=. --remote=origin --push
```

---

## 🔧 Configuration

All settings are managed via [config/homelab.conf](file:///home/priyranjan/myprojects/homelab-cli/config/homelab.conf):

```bash
# Root path for shared data
DATA_ROOT="/srv/data"

# Subdirectories expected under DATA_ROOT
DATA_DIRS="media downloads documents photos backups"

# Service names for URL generation (vmid:name, replace spaces with underscores, or comma-separated for multiple users)
SERVICE_NAMES="100:Plex 101:Homer 102:gateway,aria2 103:NextExplorer"

# Service port mappings (vmid:port)
SERVICE_PORTS="100:32400 101:8010 102:8080 103:3000"

# Default UID offset for unprivileged LXC containers (Proxmox default is 100000)
ACL_UID_OFFSET="100000"
```

### 🔍 How to Find These Settings on Your Proxmox Node

If you are not sure what values to fill in your `homelab.conf`, run these diagnostic commands on your Proxmox server:

1. **Find Container VMIDs & Names**:
   Run `pct list`. This lists all local containers:
   ```bash
   pct list
   ```
   *Map the VMIDs to your names in `SERVICE_NAMES` (e.g., `100:Plex 101:Homer`).*

2. **Find Container Service Ports**:
   If you don't know which port a service is running on inside container `100`, query its open ports:
   ```bash
   pct exec 100 -- ss -tlnp
   ```

3. **Find Mount Points**:
   To see what host folders are mapped to containers:
   ```bash
   homelab mount list
   ```
   *Set `DATA_ROOT` to the common parent path (like `/srv/data`) and list the directories in `DATA_DIRS`.*

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
Inspects and modifies filesystem permissions on PVE host data paths bound to LXC containers.

It also automatically detects **split-namespace issues** caused by non-recursive LXC bind mounts:
1. **Sub-mounts:** Discovers active host mount points under parent bind mounts (e.g. `/srv/data/media/Movies` under `/srv/data`) that are not visible inside the container.
2. **Symlinks:** Discovers symlinks pointing outside the parent path and whose targets are not available inside the container.

When these are detected, the tool writes `lxc.mount.entry` lines directly to the Proxmox container config (`/etc/pve/lxc/<vmid>.conf`) and prompts for a container restart so LXC can set up the mounts natively.

> [!NOTE]
> **Why not inject mounts at runtime?** Linux kernel security prevents bind-mounting host filesystems into an unprivileged container's user namespace from within that namespace. The only reliable approach is configuring them in the LXC config so Proxmox sets them up before namespace isolation begins.

#### Inspect ACLs:
Inspects whether the unprivileged container mapping UID has access to host paths, and checks if sub-mounts or symlinks need to be added to the container config.
```bash
homelab acl inspect 103
```

Output:
```text
ACL Inspection — Container 103
==============================

Container Info
──────────────
  VMID:                103
  Hostname:            nextexplorer
  Persistence Hook:    Not configured
──────────────────────────────────────────────────
  Bind Mount:          /srv/data → /data
  Filesystem Owner:    root:root
  Service User:        explorer (UID 1000)
  Mapped Host UID:     101000
  Current Access:      rwx
  Recommendation:      OK
──────────────────────────────────────────────────
  Bind Mount:          /srv/data/media/Movies → /data/media/Movies (Sub-mount)
  Filesystem Owner:    root:root
  Service User:        explorer (UID 1000)
  Mapped Host UID:     101000
  Current Access:      rwx
  Recommendation:      Add mount entry
──────────────────────────────────────────────────
```

> [!IMPORTANT]
> **Prerequisite**: The container must have at least one bind mount configured in Proxmox (e.g., `mp0: /host/path,mp=/container/path`) before you can inspect or grant ACLs. If a container only has its root filesystem (`/`), the ACL tool will have no paths to manage.

#### Grant ACLs & Add Mount Entries:
Grants read, write, and execute permissions recursively (including **Default ACLs** so newly created files inherit access permissions). For sub-mounts and symlink targets not visible inside the container, it adds `lxc.mount.entry` lines to `/etc/pve/lxc/<vmid>.conf` with `bind,optional,create=dir` options and prompts for a container restart.

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
