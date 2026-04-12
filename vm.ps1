<#
.SYNOPSIS
    Windsurf VM Manager — spin up, manage, and snapshot Windsurf IDE VMs.

.USAGE
    vm new <name>               Create new VM instance (auto-provision ~12 min)
    vm start <name>             Start VM + open RDP
    vm stop <name>              Halt VM (state preserved)
    vm list                     List all instances
    vm delete <name>            Destroy VM permanently

    vm snapshot <name> <label>  Save snapshot
    vm restore <name> <label>   Restore to snapshot
    vm snapshots <name>         List snapshots for an instance

.EXAMPLE
    vm new dev-main
    vm start dev-main
    vm snapshot dev-main clean-state
    vm restore dev-main clean-state
    vm stop dev-main
#>

param(
    [Parameter(Position=0)] [string] $Command = "",
    [Parameter(Position=1)] [string] $Name    = "",
    [Parameter(Position=2)] [string] $Label   = ""
)

# ─── Config ──────────────────────────────────────────────────────────────────
$RootDir      = $PSScriptRoot
$InstancesDir = Join-Path $RootDir "instances"
$RegistryFile = Join-Path $RootDir ".vm-registry.json"
$ProjectPath  = "C:\Users\email\Desktop\mkt_tools"
$BaseRdpPort  = 3390
$RdpWaitSec   = 8    # seconds to wait after vagrant up before opening mstsc

# ─── Helpers ─────────────────────────────────────────────────────────────────
function Write-Info  ($msg) { Write-Host "  $msg" -ForegroundColor Cyan }
function Write-Ok    ($msg) { Write-Host "  ✓ $msg" -ForegroundColor Green }
function Write-Warn  ($msg) { Write-Host "  ⚠ $msg" -ForegroundColor Yellow }
function Write-Err   ($msg) { Write-Host "  ✗ $msg" -ForegroundColor Red }

function Get-Registry {
    if (Test-Path $RegistryFile) {
        $raw = Get-Content $RegistryFile -Raw | ConvertFrom-Json
        return $raw
    }
    return [PSCustomObject]@{ instances = [PSCustomObject]@{} }
}

function Save-Registry ($reg) {
    $reg | ConvertTo-Json -Depth 10 | Set-Content $RegistryFile -Encoding UTF8
}

function Get-NextPort ($reg) {
    $used = @()
    foreach ($prop in $reg.instances.PSObject.Properties) {
        $used += $prop.Value.rdp_port
    }
    $port = $BaseRdpPort
    while ($port -in $used) { $port++ }
    return $port
}

function Get-Instance ($reg, $name) {
    if ($reg.instances.PSObject.Properties[$name]) {
        return $reg.instances.$name
    }
    return $null
}

function Invoke-Vagrant ($instanceName, $rdpPort, [string[]]$vagrantArgs) {
    $instanceDir = Join-Path $InstancesDir $instanceName
    New-Item -ItemType Directory -Force -Path $instanceDir | Out-Null

    # Set env vars for Vagrantfile parameterization
    $env:VM_INSTANCE_NAME    = $instanceName
    $env:VM_RDP_PORT         = "$rdpPort"
    $env:VM_PROJECT_PATH     = $ProjectPath
    $env:VAGRANT_DOTFILE_PATH = $instanceDir
    $env:VAGRANT_CWD         = $RootDir

    try {
        & vagrant @vagrantArgs | Out-Host
        $code = $LASTEXITCODE
        return $code
    }
    finally {
        Remove-Item Env:VM_INSTANCE_NAME     -ErrorAction SilentlyContinue
        Remove-Item Env:VM_RDP_PORT          -ErrorAction SilentlyContinue
        Remove-Item Env:VM_PROJECT_PATH      -ErrorAction SilentlyContinue
        Remove-Item Env:VAGRANT_DOTFILE_PATH -ErrorAction SilentlyContinue
        Remove-Item Env:VAGRANT_CWD          -ErrorAction SilentlyContinue
    }
}

function Show-Help {
    Write-Host ""
    Write-Host "  Windsurf VM Manager" -ForegroundColor Cyan
    Write-Host "  ─────────────────────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host "  vm new <name>               Create new VM (auto-provisions)"
    Write-Host "  vm start <name>             Start VM + open RDP"
    Write-Host "  vm stop <name>              Halt VM (state preserved)"
    Write-Host "  vm list                     List all instances"
    Write-Host "  vm delete <name>            Destroy VM permanently"
    Write-Host ""
    Write-Host "  vm snapshot <name> <label>  Save VM snapshot"
    Write-Host "  vm restore <name> <label>   Restore to snapshot"
    Write-Host "  vm snapshots <name>         List snapshots"
    Write-Host ""
    Write-Host "  Examples:" -ForegroundColor DarkGray
    Write-Host "    vm new dev-main"
    Write-Host "    vm start dev-main"
    Write-Host "    vm snapshot dev-main clean-state"
    Write-Host "    vm restore dev-main clean-state"
    Write-Host ""
}

# ─── Require name helper ──────────────────────────────────────────────────────
function Assert-Name {
    if ([string]::IsNullOrWhiteSpace($Name)) {
        Write-Err "Instance name required. Usage: vm $Command <name>"
        exit 1
    }
}

function Assert-Label {
    if ([string]::IsNullOrWhiteSpace($Label)) {
        Write-Err "Snapshot label required. Usage: vm $Command $Name <label>"
        exit 1
    }
}

# ─── Commands ─────────────────────────────────────────────────────────────────
switch ($Command.ToLower()) {

    "new" {
        Assert-Name
        $reg      = Get-Registry
        $existing = Get-Instance $reg $Name

        if ($existing) {
            Write-Warn "Instance '$Name' already exists (port $($existing.rdp_port))."
            Write-Info "Use 'vm start $Name' to launch it."
            exit 1
        }

        $port = Get-NextPort $reg

        Write-Host ""
        Write-Host "  Creating VM '$Name'" -ForegroundColor Cyan
        Write-Host "  RDP port : localhost:$port"
        Write-Host "  Project  : $ProjectPath"
        Write-Host "  RAM      : 6 GB  |  CPU: 4 cores"
        Write-Host ""
        Write-Warn "First run downloads Ubuntu box (~700 MB) + provisions (~12 min)."
        Write-Warn "SMB share: Windows will show a UAC prompt — approve it."
        Write-Host ""

        # Register before provisioning so port is reserved
        $reg.instances | Add-Member -NotePropertyName $Name -NotePropertyValue ([PSCustomObject]@{
            rdp_port = $port
            created  = (Get-Date).ToString("yyyy-MM-dd HH:mm")
            status   = "provisioning"
        })
        Save-Registry $reg

        $exitCode = Invoke-Vagrant $Name $port @("up")

        if ($exitCode -eq 0) {
            $reg = Get-Registry
            $reg.instances.$Name.status = "ready"
            Save-Registry $reg

            Write-Host ""
            Write-Ok "VM '$Name' is ready!"
            Write-Host "  Run: vm start $Name" -ForegroundColor Gray
        } else {
            Write-Err "Provisioning failed (exit $exitCode). Check output above."
            $reg = Get-Registry
            $reg.instances.$Name.status = "error"
            Save-Registry $reg
            exit 1
        }
    }

    "start" {
        Assert-Name
        $reg      = Get-Registry
        $instance = Get-Instance $reg $Name

        if (-not $instance) {
            Write-Err "Instance '$Name' not found."
            Write-Info "Use 'vm new $Name' to create it, or 'vm list' to see all instances."
            exit 1
        }

        $port = $instance.rdp_port
        Write-Host ""
        Write-Info "Starting VM '$Name' (RDP: localhost:$port)..."

        $exitCode = Invoke-Vagrant $Name $port @("up")

        if ($exitCode -ne 0) {
            Write-Err "Failed to start VM (exit $exitCode)."
            exit 1
        }

        Write-Info "Waiting $RdpWaitSec s for RDP service..."
        Start-Sleep $RdpWaitSec

        Write-Info "Opening Remote Desktop..."
        Start-Process "mstsc" "/v:localhost:$port"

        $reg = Get-Registry
        $reg.instances.$Name.status = "running"
        Save-Registry $reg

        Write-Host ""
        Write-Ok "Connected to '$Name'"
        Write-Host "  Login    : vagrant / vagrant" -ForegroundColor Gray
        Write-Host "  Project  : /project  (shared folder)" -ForegroundColor Gray
        Write-Host "  Windsurf : auto-launches after login" -ForegroundColor Gray
        Write-Host ""
    }

    "stop" {
        Assert-Name
        $reg      = Get-Registry
        $instance = Get-Instance $reg $Name

        if (-not $instance) {
            Write-Err "Instance '$Name' not found."
            exit 1
        }

        Write-Info "Stopping VM '$Name'..."
        Invoke-Vagrant $Name $instance.rdp_port @("halt") | Out-Null

        $reg = Get-Registry
        $reg.instances.$Name.status = "stopped"
        Save-Registry $reg

        Write-Ok "VM '$Name' stopped. State preserved — 'vm start $Name' to resume."
    }

    "list" {
        $reg = Get-Registry
        Write-Host ""
        Write-Host "  ┌─ Windsurf VM Instances ──────────────────────────────────┐" -ForegroundColor Cyan

        $props = $reg.instances.PSObject.Properties
        if ($props.Count -eq 0) {
            Write-Host "  │  (no instances)  Use: vm new <name>" -ForegroundColor DarkGray
        } else {
            foreach ($prop in $props) {
                $inst   = $prop.Value
                $status = $inst.status
                $color  = switch ($status) {
                    "running"      { "Green" }
                    "ready"        { "Yellow" }
                    "stopped"      { "DarkGray" }
                    "provisioning" { "Cyan" }
                    default        { "Gray" }
                }
                $line = "  │  {0,-16} RDP: localhost:{1,-6} {2,-12} Created: {3}" -f `
                    $prop.Name, $inst.rdp_port, "[$status]", $inst.created
                Write-Host $line -ForegroundColor $color
            }
        }

        Write-Host "  └──────────────────────────────────────────────────────────┘" -ForegroundColor Cyan
        Write-Host ""
    }

    "delete" {
        Assert-Name
        $reg      = Get-Registry
        $instance = Get-Instance $reg $Name

        if (-not $instance) {
            Write-Err "Instance '$Name' not found."
            exit 1
        }

        Write-Host ""
        Write-Warn "This will PERMANENTLY destroy VM '$Name' and all its snapshots."
        Write-Host "  (Your project files in $ProjectPath are NOT affected)" -ForegroundColor DarkGray
        $confirm = Read-Host "  Type 'yes' to confirm"

        if ($confirm -ne "yes") {
            Write-Info "Cancelled."
            exit 0
        }

        Write-Info "Destroying VM '$Name'..."
        Invoke-Vagrant $Name $instance.rdp_port @("destroy", "-f") | Out-Null

        # Remove from registry
        $newInstances = [PSCustomObject]@{}
        foreach ($prop in $reg.instances.PSObject.Properties) {
            if ($prop.Name -ne $Name) {
                $newInstances | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value
            }
        }
        $reg.instances = $newInstances
        Save-Registry $reg

        # Remove instance directory
        $instanceDir = Join-Path $InstancesDir $Name
        Remove-Item -Recurse -Force $instanceDir -ErrorAction SilentlyContinue

        Write-Ok "VM '$Name' deleted."
    }

    "snapshot" {
        Assert-Name
        Assert-Label
        $reg      = Get-Registry
        $instance = Get-Instance $reg $Name

        if (-not $instance) {
            Write-Err "Instance '$Name' not found."
            exit 1
        }

        Write-Info "Saving snapshot '$Label' for '$Name'..."
        Invoke-Vagrant $Name $instance.rdp_port @("snapshot", "save", "--force", $Label)
        Write-Ok "Snapshot '$Label' saved."
    }

    "restore" {
        Assert-Name
        Assert-Label
        $reg      = Get-Registry
        $instance = Get-Instance $reg $Name

        if (-not $instance) {
            Write-Err "Instance '$Name' not found."
            exit 1
        }

        Write-Warn "This will revert '$Name' to snapshot '$Label'. Unsaved VM state will be lost."
        $confirm = Read-Host "  Confirm? (y/N)"
        if ($confirm -ne "y") { Write-Info "Cancelled."; exit 0 }

        Write-Info "Restoring '$Name' to '$Label'..."
        Invoke-Vagrant $Name $instance.rdp_port @("snapshot", "restore", $Label)
        Write-Ok "'$Name' restored to '$Label'."
    }

    "snapshots" {
        Assert-Name
        $reg      = Get-Registry
        $instance = Get-Instance $reg $Name

        if (-not $instance) {
            Write-Err "Instance '$Name' not found."
            exit 1
        }

        Write-Info "Snapshots for '$Name':"
        Invoke-Vagrant $Name $instance.rdp_port @("snapshot", "list")
    }

    { $_ -in @("", "help", "-h", "--help") } {
        Show-Help
    }

    default {
        Write-Err "Unknown command: '$Command'"
        Show-Help
        exit 1
    }
}
