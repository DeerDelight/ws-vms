# Windsurf VM Manager (`ws-vms`)

A minimal PowerShell CLI to spin up, manage, and snapshot isolated **Windsurf IDE** development environments on Windows using Vagrant + VirtualBox.

Each VM runs **Ubuntu 22.04** with XFCE desktop, accessible via Remote Desktop (RDP). Your Windows project folder is shared into the VM as `/project` — edit files in the VM, run apps on Windows, no sync lag.

---

## Features

- **One-command VM creation** — `vm new dev-main` provisions everything automatically
- **Multi-instance** — run multiple named VMs, each with its own RDP port and snapshots
- **Snapshot workflow** — save/restore VM state in seconds (great for experiments)
- **Shared folder** — your project files are live-synced via VirtualBox shared folder
- **Fast re-use** — optionally build a pre-provisioned base box (~1-2 min boot vs. ~15 min)
- **Auto RDP** — `vm start` opens Remote Desktop automatically

### What's inside each VM

| Component | Version |
|-----------|---------|
| OS | Ubuntu 22.04 LTS |
| Desktop | XFCE4 (lightweight) |
| Remote access | xrdp |
| IDE | Windsurf (auto-launches on login) |
| Python | 3.13 + pip |
| Python packages | FastAPI, SQLAlchemy, Flask, Textual, Pillow, and more |

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
Base RDP port [3390]:
```

This creates `vm.config.ps1` (gitignored — stays on your machine):

```powershell
$ProjectPath = "C:\Dev\myapp"
$VmRam       = 6144
$VmCpus      = 4
$BaseRdpPort = 3390
```

To change settings later, edit `vm.config.ps1` directly or delete it to re-run the prompt.

To use a template: copy `vm.config.example.ps1` → `vm.config.ps1` and fill in your values.

---

## Commands

```
.\vm.bat new <name>               Create and provision a new VM
.\vm.bat start <name>             Start VM + open Remote Desktop
.\vm.bat stop <name>              Halt VM (state preserved)
.\vm.bat list                     Show all instances with status
.\vm.bat delete <name>            Permanently destroy a VM

.\vm.bat snapshot <name> <label>  Save a named snapshot
.\vm.bat restore <name> <label>   Restore VM to a snapshot
.\vm.bat snapshots <name>         List snapshots for an instance
```

You can also call `vm.ps1` directly from PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\vm.ps1 start dev-main
```

### Example workflow

```powershell
# Create VM for a project
.\vm.bat new dev-main

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

## Troubleshooting

**`vm new` hangs for a very long time during apt-get update**
> The default Ubuntu mirror can be slow in some regions. The provision script auto-switches to a regional mirror — if it's still slow, SSH into the VM and change `/etc/apt/sources.list` manually.

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
