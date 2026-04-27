# Windsurf VM — Usage Examples

Concrete, copy-paste-ready examples for every supported workflow. For overview
and installation see `README.md`.

---

## Table of contents

1. [First-time setup](#1-first-time-setup)
2. [Single-project VMs (simple / legacy)](#2-single-project-vms-simplelegacy)
3. [Multi-project VMs](#3-multi-project-vms)
4. [Start / stop / list / delete](#4-start--stop--list--delete)
5. [Snapshots](#5-snapshots)
6. [Recovery & edge cases](#6-recovery--edge-cases)

---

## 1. First-time setup

Copy the template and edit with your paths:

```powershell
PS> copy vm.config.example.ps1 vm.config.ps1
PS> notepad vm.config.ps1
```

Recommended `vm.config.ps1`:

```powershell
# Legacy single-project fallback (used when a VM is created without -p)
$ProjectPath = "C:\Dev\legacy-main"

# Named project aliases — declare once, reuse across VMs
$Projects = @{
    "mkt-tools"    = "C:\Dev\mkt-tools"
    "windsurf-vms" = "C:\Dev\windsurfv_vms"
    "scratch"      = "C:\Users\me\Desktop\scratch"
}

$VmRam       = 6144
$VmCpus      = 4
$VmDiskGB    = 40
$BaseRdpPort = 3390
```

If you skip this step, `vm new` will prompt for `$ProjectPath` on first run
(no aliases — you can add `$Projects` later).

---

## 2. Single-project VMs (simple/legacy)

### 2.1. Create a VM that mounts `$ProjectPath` at `/project`

```powershell
PS> vm new work
```

When asked "Projects to mount", **press Enter** (empty input) to fall back to
legacy single-mount mode. Host `$ProjectPath` appears inside the VM as
`/project`. Windsurf auto-opens `/project` on RDP login.

### 2.2. Same thing, non-interactive

Edit `vm.config.ps1` so that `$ProjectPath` points at your project, then:

```powershell
PS> echo "" | vm new work
```

Or explicitly skip the prompt by setting `$Projects` empty and pressing Enter.

---

## 3. Multi-project VMs

Each VM can mount any subset of your aliases plus ad-hoc absolute paths.
Mounts appear as `/projects/<name>` inside the guest. Windsurf does **not**
auto-open any of them — you pick the folder inside the IDE.

### 3.1. Two aliases

```powershell
PS> vm new dev -p mkt-tools,windsurf-vms
```

Output:
```
  Creating VM 'dev'
  RDP port : localhost:3390
  Projects : mkt-tools    -> C:\Dev\mkt-tools       -> /projects/mkt-tools
             windsurf-vms -> C:\Dev\windsurfv_vms   -> /projects/windsurf-vms
  RAM      : 6 GB  |  CPU: 4 cores  |  Disk: 40 GB
```

Inside the VM after `vm start dev`:
```bash
vagrant@windsurf-dev:~$ ls /projects/
mkt-tools  windsurf-vms
vagrant@windsurf-dev:~$ ls /projects/mkt-tools/
# same files as C:\Dev\mkt-tools on host
```

### 3.2. Mix alias + ad-hoc absolute path

```powershell
PS> vm new bugfix -p mkt-tools,C:\Temp\issue-123
```

- `mkt-tools` resolves from `$Projects` -> mount `C:\Dev\mkt-tools` at `/projects/mkt-tools`
- `C:\Temp\issue-123` is an absolute path -> leaf name = `issue-123` (sanitized) -> mount at `/projects/issue-123`

### 3.3. No `-p` flag (interactive prompt)

```powershell
PS> vm new test
```
```
  Projects to mount for 'test':
    Available aliases: mkt-tools, windsurf-vms, scratch
    (comma-separated aliases or absolute paths; empty = legacy $ProjectPath)
  Select: mkt-tools,scratch
```

### 3.4. Single project under new layout

```powershell
PS> vm new solo -p mkt-tools
```
Mounts only `/projects/mkt-tools`. No `/project`. Useful when you want the new
path scheme for consistency across VMs.

### 3.5. Alias doesn't exist

```powershell
PS> vm new oops -p typo-alias
  X Unknown project alias or invalid path: 'typo-alias'
  Available aliases: mkt-tools, windsurf-vms, scratch
  (Hint: use an alias from the list, or an absolute Windows path)
```
Exit 1. VM not created.

### 3.6. Host path missing

```powershell
PS> vm new temp -p C:\Not\Existing\Yet
  ! Host path does not exist: C:\Not\Existing\Yet
  ! Continue anyway? (y/N): y
```
If you confirm, `vm new` proceeds. Vagrant will error clearly when mounting
if the path still doesn't exist at `vagrant up` time.

### 3.7. Duplicate mount names

```powershell
PS> vm new dupe -p C:\Dev\tools,C:\Other\tools
  X Duplicate project name: 'tools' (from C:\Dev\tools and C:\Other\tools)
  (Hint: add one as an alias in $Projects with a unique name)
```
Fix: add aliases to disambiguate:
```powershell
$Projects = @{
    "tools-a" = "C:\Dev\tools"
    "tools-b" = "C:\Other\tools"
}
```
Then: `vm new dupe -p tools-a,tools-b`.

### 3.8. Path with spaces

```powershell
$Projects = @{
    "my-docs" = "C:\Users\me\My Documents\project"
}
```
```powershell
PS> vm new doc -p my-docs
```
PowerShell JSON encoding and VirtualBox shared folders both handle spaces.
Mounts as `/projects/my-docs`.

### 3.9. Leaf name sanitization

```powershell
PS> vm new x -p "C:\Dev\Project With Spaces & Symbols!"
  Projects : project-with-spaces-symbols -> C:\Dev\Project With Spaces & Symbols!
                                         -> /projects/project-with-spaces-symbols
```
Leaf `Project With Spaces & Symbols!` becomes mount name
`project-with-spaces-symbols` (lowercase, non-alphanumeric runs collapsed to `-`).

---

## 4. Start / stop / list / delete

### 4.1. Start a VM (opens RDP automatically)

```powershell
PS> vm start dev
```

### 4.2. Stop a VM (state preserved)

```powershell
PS> vm stop dev
```

### 4.3. List VMs with project summary

```powershell
PS> vm list
  Windsurf VM Instances
  ---------------------------------------------------------
  dev        RDP: localhost:3390  [running]  Created: 2026-04-17 10:30
             Projects: mkt-tools, windsurf-vms
  bugfix     RDP: localhost:3391  [stopped]  Created: 2026-04-17 11:00
             Projects: mkt-tools, issue-123
  legacy     RDP: localhost:3392  [ready]    Created: 2026-03-01 08:00
             Projects: /project (legacy)
  ---------------------------------------------------------
```

### 4.4. Delete a VM

```powershell
PS> vm delete dev
  ! This will PERMANENTLY destroy VM 'dev' and all its snapshots.
    (Your project files are NOT affected)
  Type 'yes' to confirm: yes
```

---

## 5. Snapshots

Snapshots save VM **internal** state (filesystem + memory inside the guest).
Shared project folders live on the host and are **not** captured in snapshots —
restoring a snapshot does not roll back your project files.

### 5.1. Save a clean-state snapshot

```powershell
PS> vm new dev -p mkt-tools,windsurf-vms
PS> vm start dev
# ...let provisioning finish, log into RDP once...
PS> vm snapshot dev clean
```

### 5.2. Restore after experimenting

```powershell
PS> vm restore dev clean
  ! This will revert 'dev' to snapshot 'clean'. Unsaved VM state will be lost.
  Confirm? (y/N): y
```

### 5.3. List snapshots

```powershell
PS> vm snapshots dev
```

---

## 6. Recovery & edge cases

### 6.1. Resume a failed provision

If `vm new` fails partway through provisioning, the VM is left in `error`
state. Re-run the same command to resume — `provision.sh` is idempotent and
the registry remembers your project list:

```powershell
PS> vm new dev -p mkt-tools,windsurf-vms    # fails mid-way
PS> vm new dev                               # resume (no -p needed)
  ! Instance 'dev' previously failed to provision. Resuming...
```

Full Vagrant output of the last run is always saved to
`instances/<name>/last-run.log`.

### 6.2. Change projects on an existing VM (manual)

v1 does not include a dedicated subcommand. Workflow:

```powershell
PS> vm stop dev
# Edit .vm-registry.json: modify instances.dev.projects[]
PS> vm start dev
```

A future `vm projects <name> add/remove` subcommand may land in a later
version.

### 6.3. Rename an alias after a VM was created

```powershell
# Original config:  "mkt-tools" = "C:\Dev\mkt-tools"
PS> vm new dev -p mkt-tools
# Later: rename alias "mkt-tools" -> "marketing" in vm.config.ps1
PS> vm start dev
```

The registry stores the resolved path at creation time, so VM `dev` still
mounts `C:\Dev\mkt-tools` at `/projects/mkt-tools`. New VMs created after the
rename will see the new alias name.

### 6.4. A VM created before the multi-project feature

VMs whose registry entries lack a `projects` field keep the legacy behavior:
they mount `$ProjectPath` at `/project`. No migration needed — just keep using
`vm start`/`vm stop`.

### 6.5. Snapshot with multi-project VMs

Same semantics as before: snapshots cover VM internal state only. Host project
folders are untouched. Safe to snapshot/restore any multi-project VM.

### 6.6. Absolute path with unicode or symbols that sanitize to empty

```powershell
PS> vm new x -p "C:\あいうえお"
  X Cannot derive a valid mount name from path: 'C:\あいうえお'
  (Hint: add an alias in $Projects with an ASCII name)
```

Fix:
```powershell
$Projects = @{ "jp-docs" = "C:\あいうえお" }
```
Then `vm new x -p jp-docs` — the alias name is used as the mount name, so
unicode in the host path is fine.
