# ─── Windsurf VM — User Configuration ────────────────────────────────────────
#
# Copy this file to vm.config.ps1 and adjust for your setup.
# vm.config.ps1 is gitignored — your settings stay local and private.
#
# Usage: copy vm.config.example.ps1 vm.config.ps1
# ─────────────────────────────────────────────────────────────────────────────

# Path to the project folder to share into the VM as /project
$ProjectPath = "C:\Users\YourName\Desktop\my-project"

# VM resources (adjust based on your host machine)
$VmRam  = 6144   # RAM in MB  — 6 GB recommended (minimum 4096 for Windsurf)
$VmCpus = 4      # CPU cores  — 4 recommended (minimum 2)

# RDP port for the first VM (subsequent VMs auto-increment: 3391, 3392 ...)
$BaseRdpPort = 3390
