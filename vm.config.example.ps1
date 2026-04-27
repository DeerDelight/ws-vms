# ─── Windsurf VM — User Configuration ────────────────────────────────────────
#
# Copy this file to vm.config.ps1 and adjust for your setup.
# vm.config.ps1 is gitignored — your settings stay local and private.
#
# Usage: copy vm.config.example.ps1 vm.config.ps1
# ─────────────────────────────────────────────────────────────────────────────

# Legacy single-project fallback. Used by `vm new <name>` when you press Enter
# at the "Projects to mount" prompt (or don't pass -p). Mounts at /project.
$ProjectPath = "C:\Users\YourName\Desktop\my-project"

# Named project aliases for multi-project VMs.
#
# Each VM can mount any subset via: vm new <name> -p alias1,alias2,C:\abs\path
# Aliases become mount names inside the guest: /projects/<alias>
# Alias names must match [a-zA-Z0-9][a-zA-Z0-9_-]{0,31}
#
# Delete or leave empty (@{}) if you only use single-project VMs.
$Projects = @{
    # "mkt-tools"    = "C:\Dev\mkt-tools"
    # "windsurf-vms" = "C:\Dev\windsurfv_vms"
    # "scratch"      = "C:\Users\YourName\Desktop\scratch"
}

# VM resources (adjust based on your host machine)
$VmRam    = 6144  # RAM in MB    — 6 GB recommended (minimum 4096 for Windsurf)
$VmCpus   = 4     # CPU cores    — 4 recommended (minimum 2)
$VmDiskGB = 40    # Disk size GB — 40 recommended (guest filesystem auto-grows on provision)

# RDP port for the first VM (subsequent VMs auto-increment: 3391, 3392 ...)
$BaseRdpPort = 3390

# SSH Bridge: Windows username for Remote-SSH connections from VM.
# Leave blank to auto-detect from bridge config (set during 'vm setup-host').
$HostUser = ""
