# Windsurf VM Manager (`ws-vms`)

A minimal PowerShell CLI to spin up, manage, and snapshot isolated **Windsurf IDE** development environments on Windows using Vagrant + VirtualBox.

Each VM runs **Ubuntu 22.04** with XFCE desktop, accessible via Remote Desktop (RDP). Your Windows project folders are live-synced into the VM as shared folders — either a single `/project` mount (legacy) or multiple `/projects/<name>` mounts (see [USAGE.md](./USAGE.md) for the multi-project workflow).

---

## Features

- **One-command VM creation** — `vm new dev-main` provisions everything automatically
- **Multi-instance** — run multiple named VMs, each with its own RDP port and snapshots
- **Multi-project** — each VM can mount any subset of your project folders under `/projects/<name>` (see [USAGE.md](./USAGE.md))
- **Snapshot workflow** — save/restore VM state in seconds (great for experiments)
- **Shared folders** — project files are live-synced via VirtualBox shared folder
- **Fast re-use** — optionally build a pre-provisioned base box (~1-2 min boot vs. ~15 min)
- **Auto RDP** — `vm start` opens Remote Desktop automatically

### What's inside each VM

| Component | Version / Source |
|-----------|------------------|
| OS | Ubuntu 22.04 LTS (**snap-free** — snapd purged and pinned) |
| Desktop | XFCE4 (lightweight) |
| Remote access | xrdp |
| IDE | Windsurf (auto-launches on login) |
| Browser | Google Chrome (direct `.deb` from Google) |
| Vietnamese input | ibus + ibus-bamboo (direct `.deb` from GitHub releases) |
| Python | 3.13 + pip |
| Python packages | See `vm-requirements.txt` (FastAPI, SQLAlchemy, Flask, Textual, Pillow, …) |

---

## Prerequisites

| Tool | Download |
|------|----------|
| **VirtualBox 7.x** | https://www.virtualbox.org/wiki/Downloads |
| **Vagrant 2.4+** | https://developer.hashicorp.com/vagrant/downloads |
| **Windows 10/11** | (PowerShell 5.1+ included) |

> **VirtualBox must be installed on C:** (driver requirement). VM disk images can be stored on any drive via VirtualBox Preferences > Default Machine Folder.

---

## Quick Start

```powershell
# 1. Clone the repo
git clone https://github.com/DeerDelight/ws-vms.git
cd ws-vms

# 2. Create your first VM (prompts for project path on first run)
.\vm.bat new dev-main

# 3. Start it (opens Remote Desktop automatically)
.\vm.bat start dev-main
```

> First run downloads Ubuntu (~700 MB) and provisions the VM (~15 minutes). Subsequent VMs are faster if you [build the base box](#building-the-base-box-optional).

**RDP Login**: `vagrant` / `vagrant`

---

## Configuration

On first `vm new`, you'll be prompted to create `vm.config.ps1`:

```
First-time setup
─────────────────────────────────────────────────────────
Project folder path (default: C:\Users\You\Desktop\my-project): C:\Dev\myapp
RAM in MB [6144]:
CPU cores [4]:
Disk size in GB [40]:
Base RDP port [3390]:
```

This creates `vm.config.ps1` (gitignored — stays on your machine):

```powershell
# Legacy single-project fallback (used when -p is omitted and prompt is empty)
$ProjectPath = "C:\Dev\myapp"

# Named project aliases for multi-project VMs (add your own, or leave empty)
$Projects = @{
    "mkt-tools"    = "C:\Dev\mkt-tools"
    "windsurf-vms" = "C:\Dev\windsurfv_vms"
}

$VmRam       = 6144
$VmCpus      = 4
$VmDiskGB    = 40
$BaseRdpPort = 3390
```

> `$VmDiskGB` resizes the VirtualBox primary disk **and** grows the guest
> filesystem automatically (via `growpart` + `resize2fs` during provisioning).
> Increase it before `vm new` if you expect to install large toolchains.
>
> **Note:** disk resize only applies when creating VMs from `ubuntu/jammy64`
> (VDI format). Packaged `windsurf-base.box` uses VMDK which VirtualBox cannot
> resize — to enlarge disks on VMs from a base box, rebuild the base box after
> bumping `$VmDiskGB`.

To change settings later, edit `vm.config.ps1` directly or delete it to re-run the prompt.

To use a template: copy `vm.config.example.ps1` → `vm.config.ps1` and fill in your values.

---

## Commands

```
.\vm.bat new <name> [-p spec]     Create a new VM (spec = comma-separated aliases or paths)
.\vm.bat start <name>             Start VM + open Remote Desktop
.\vm.bat stop <name>              Halt VM (state preserved)
.\vm.bat list                     Show all instances with status + projects
.\vm.bat delete <name>            Permanently destroy a VM

.\vm.bat snapshot <name> <label>  Save a named snapshot
.\vm.bat restore <name> <label>   Restore VM to a snapshot
.\vm.bat snapshots <name>         List snapshots for an instance

.\vm.bat setup-host               One-time SSH bridge setup (auto-elevates)
.\vm.bat ssh <name>               SSH into VM from host terminal
.\vm.bat status <name>            Show connectivity + bridge health
```

For every flag, prompt, and edge case with concrete examples, see **[USAGE.md](./USAGE.md)**.

You can also call `vm.ps1` directly from PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\vm.ps1 start dev-main
```

### Example workflow

```powershell
# Create a single-project VM (press Enter at the project prompt)
.\vm.bat new dev-main

# Create a multi-project VM from aliases in vm.config.ps1
.\vm.bat new dev-main -p mkt-tools,windsurf-vms

# Take a clean snapshot before installing something risky
.\vm.bat snapshot dev-main before-experiment

# ... do stuff, it breaks ...

# Restore to clean state
.\vm.bat restore dev-main before-experiment

# Create a second isolated VM for another project
.\vm.bat new dev-client-x

# See all VMs
.\vm.bat list
```

---

## Inside the VM

| Path | Description |
|------|-------------|
| `/project` | Your Windows project folder (live-synced, read-write) |
| `python3.13` | Python 3.13 with pip |
| `python` | Alias to python3.13 |
| `windsurf` | Windsurf IDE (auto-launches after RDP login) |

The VM opens Windsurf pointed at `/project` automatically after you log in via RDP.

---

## Multi-VM setup

Each VM gets its own RDP port (auto-incremented from `$BaseRdpPort`):

```powershell
.\vm.bat new project-a   # RDP: localhost:3390
.\vm.bat new project-b   # RDP: localhost:3391
.\vm.bat new project-c   # RDP: localhost:3392
```

> Each VM needs 6 GB RAM to run comfortably. On a 16 GB host, run 1-2 VMs at a time.

---

## Building the Base Box (optional)

The first `vm new` takes ~15 minutes to provision from `ubuntu/jammy64`. To make future instances start in ~1-2 minutes, build a pre-provisioned base box:

```powershell
# 1. Stop the provisioned VM
.\vm.bat stop dev-main

# 2. Package it as a base box (~5 min, creates windsurf-base.box ~2 GB)
cd instances\dev-main
vagrant package --output ..\..\windsurf-base.box

# 3. Register the box with Vagrant
vagrant box add windsurf-base ..\..\windsurf-base.box

# 4. Start the VM again
.\vm.bat start dev-main
```

After this, `vm new` will automatically use `windsurf-base` for all new instances.

> `windsurf-base.box` is gitignored (too large for git). Store it locally or on a network share.

---

## Remote-SSH Bridge (VM → Host)

The bridge lets Windsurf inside the VM act as a **thin UI client** — all code execution, terminal, and file access happens on your Windows host. The VM is just a display.

### How it works

- VirtualBox **host-only network** (192.168.56.x) — private link, not reachable from internet/LAN
- **OpenSSH Server** on host, listening only on the private adapter
- **ed25519 key** (no passphrase) pre-installed in every VM
- Windsurf's **Remote-SSH** auto-connects on launch — zero prompts

### Setup (one-time)

```powershell
# 1. Configure SSH server + firewall + keys (auto-elevates, ~2 min)
.\vm.bat setup-host

# 2. Create a VM (no -p needed — Windsurf accesses host via SSH)
.\vm.bat new dev

# 3. Start it
.\vm.bat start dev
```

After RDP login, Windsurf opens and is already connected to your Windows host filesystem — all files visible, no shared folders needed.

> **Note:** `-p` shared folders are optional. Only add them if you need Linux terminal access to project files inside the VM (e.g. `vm new dev -p mkt-tools`).

### New commands

```
vm setup-host          One-time host SSH bridge setup (auto-elevates)
vm ssh <name>          SSH into VM from host terminal
vm status <name>       Show connectivity details + bridge health
```

### Security

| Layer | Protection |
|-------|------------|
| Network | Host-only adapter (no route to internet/LAN) |
| DHCP | Disabled (static IPs only) |
| SSH | Listens only on 192.168.56.1 |
| Auth | ed25519 key only (no password) |
| Firewall | TCP/22 allowed only from 192.168.56.0/24 |
| Host key | Pre-pinned in VM (no TOFU prompts) |

### Rebuilding existing VMs

VMs created before `setup-host` don't have the host-only NIC. Recreate them:

```powershell
.\vm.bat delete dev-main
.\vm.bat new dev-main -p mkt-tools
```

---

## Troubleshooting

**`vm new` hangs for a very long time during apt-get update**
> The default Ubuntu mirror can be slow in some regions. The provision script auto-switches to a regional mirror — if it's still slow, SSH into the VM and change `/etc/apt/sources.list` manually.

**Provision fails partway through — do I have to `vm delete` and start over?**
> No. `vm new <name>` now detects a previous `error` state and automatically re-runs `vagrant up --provision`. All provision steps are idempotent. Full Vagrant output is also saved to `instances/<name>/last-run.log` for inspection.

**Guest Additions version mismatch warning**
> Safe to ignore. The `/project` shared folder still works correctly.

**RDP can't connect after `vm start`**
> Wait 10-15 seconds and try again — xrdp needs a moment to start after boot.

**`vagrant: command not found`**
> Ensure Vagrant is in your PATH. Restart your terminal or PC after installing.

**VM state shows `provisioning` after an interrupted run**
> Run `.\vm.bat delete <name>` and recreate with `.\vm.bat new <name>`.

---

## Project Structure

```
ws-vms/
├── vm.bat                   # Shell wrapper (double-click or call from cmd)
├── vm.ps1                   # Main CLI (PowerShell)
├── vm.config.example.ps1    # Config template — copy to vm.config.ps1
├── Vagrantfile              # VM definition (box, network, shared folder)
├── provision.sh             # Bash provisioner (XFCE, xrdp, Python, Windsurf)
├── vm-requirements.txt      # Python packages installed in VM
├── .gitignore
└── .gitattributes
```

---

## License

MIT
