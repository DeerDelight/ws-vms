<#
.SYNOPSIS
    Windsurf VM Manager - spin up, manage, and snapshot Windsurf IDE VMs on Windows.

.DESCRIPTION
    Wraps Vagrant + VirtualBox to provide a simple CLI for isolated Windsurf IDE
    development environments. Each instance gets its own VM, RDP port, and snapshot
    history. Your project folder is shared read-write into the VM as /project.

.USAGE
    vm new <name>               Create and provision a new VM instance
    vm start <name>             Start VM + open Remote Desktop
    vm stop <name>              Halt VM (state preserved)
    vm list                     List all instances with status
    vm delete <name>            Permanently destroy a VM

    vm snapshot <name> <label>  Save a named snapshot
    vm restore <name> <label>   Restore VM to a snapshot
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

# --- Load user config ---------------------------------------------------------
$RootDir      = $PSScriptRoot
$InstancesDir = Join-Path $RootDir "instances"
$RegistryFile = Join-Path $RootDir ".vm-registry.json"
$ConfigFile   = Join-Path $RootDir "vm.config.ps1"

# Defaults (overridden by vm.config.ps1 or first-run prompt)
$ProjectPath = ""
$VmRam       = 6144
$VmCpus      = 4
$BaseRdpPort = 3390
$RdpWaitSec  = 8

if (Test-Path $ConfigFile) {
    . $ConfigFile
}

# --- Helpers -----------------------------------------------------------------
function Write-Info  ($msg) { Write-Host "  $msg" -ForegroundColor Cyan }
function Write-Ok    ($msg) { Write-Host "  OK $msg" -ForegroundColor Green }
function Write-Warn  ($msg) { Write-Host "  ! $msg" -ForegroundColor Yellow }
function Write-Err   ($msg) { Write-Host "  X $msg" -ForegroundColor Red }

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

function Get-VmBox {
    # Use pre-built windsurf-base box if available (fast, no provisioning needed)
    # Otherwise fall back to ubuntu/jammy64 + provision.sh (~15 min first time)
    $boxes = & vagrant box list 2>$null | Out-String
    if ($boxes -match "windsurf-base") {
        return "windsurf-base"
    }
    return "ubuntu/jammy64"
}

function Invoke-Vagrant ($instanceName, $rdpPort, [string[]]$vagrantArgs) {
    $instanceDir = Join-Path $InstancesDir $instanceName
    New-Item -ItemType Directory -Force -Path $instanceDir | Out-Null

    $env:VM_INSTANCE_NAME    = $instanceName
    $env:VM_RDP_PORT         = "$rdpPort"
    $env:VM_PROJECT_PATH     = $ProjectPath
    $env:VM_RAM              = "$VmRam"
    $env:VM_CPUS             = "$VmCpus"
    $env:VM_BOX              = Get-VmBox
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
        Remove-Item Env:VM_RAM               -ErrorAction SilentlyContinue
        Remove-Item Env:VM_CPUS              -ErrorAction SilentlyContinue
        Remove-Item Env:VM_BOX               -ErrorAction SilentlyContinue
        Remove-Item Env:VAGRANT_DOTFILE_PATH -ErrorAction SilentlyContinue
        Remove-Item Env:VAGRANT_CWD          -ErrorAction SilentlyContinue
    }
}

function Ensure-Config {
    # If no config and no project path set, run first-time setup prompt
    if ([string]::IsNullOrWhiteSpace($ProjectPath)) {
        Write-Host ""
        Write-Host "  First-time setup" -ForegroundColor Cyan
        Write-Host "  ---------------------------------------------------------" -ForegroundColor DarkGray
        Write-Host "  No vm.config.ps1 found. Running first-time setup." -ForegroundColor Gray
        Write-Host ""

        $defaultPath = "$env:USERPROFILE\Desktop\my-project"
        $inputPath = Read-Host "  Project folder path (default: $defaultPath)"
        if ([string]::IsNullOrWhiteSpace($inputPath)) { $inputPath = $defaultPath }

        $inputRam = Read-Host "  RAM in MB [6144]"
        if ([string]::IsNullOrWhiteSpace($inputRam)) { $inputRam = "6144" }

        $inputCpus = Read-Host "  CPU cores [4]"
        if ([string]::IsNullOrWhiteSpace($inputCpus)) { $inputCpus = "4" }

        $inputPort = Read-Host "  Base RDP port [3390]"
        if ([string]::IsNullOrWhiteSpace($inputPort)) { $inputPort = "3390" }

        $configContent  = "# Windsurf VM - User Configuration (auto-generated)`n"
        $configContent += "`$ProjectPath = `"$inputPath`"`n"
        $configContent += "`$VmRam       = $inputRam`n"
        $configContent += "`$VmCpus      = $inputCpus`n"
        $configContent += "`$BaseRdpPort = $inputPort`n"
        Set-Content $ConfigFile $configContent -Encoding UTF8

        # Apply in current session
        $script:ProjectPath = $inputPath
        $script:VmRam       = [int]$inputRam
        $script:VmCpus      = [int]$inputCpus
        $script:BaseRdpPort = [int]$inputPort

        Write-Host ""
        Write-Ok "Config saved to vm.config.ps1"
        Write-Host ""
    }

    # Validate project path exists
    if (-not (Test-Path $ProjectPath)) {
        Write-Warn "Project path does not exist: $ProjectPath"
        Write-Info "Creating it..."
        New-Item -ItemType Directory -Force -Path $ProjectPath | Out-Null
    }
}

function Show-Help {
    Write-Host ""
    Write-Host "  Windsurf VM Manager" -ForegroundColor Cyan
    Write-Host "  ---------------------------------------------------------" -ForegroundColor DarkGray
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

# --- Commands -----------------------------------------------------------------
switch ($Command.ToLower()) {

    "new" {
        Assert-Name
        Ensure-Config

        $reg      = Get-Registry
        $existing = Get-Instance $reg $Name

        if ($existing) {
            Write-Warn "Instance '$Name' already exists (port $($existing.rdp_port))."
            Write-Info "Use 'vm start $Name' to launch it."
            exit 1
        }

        $port  = Get-NextPort $reg
        $box   = Get-VmBox
        $isNew = $box -eq "ubuntu/jammy64"

        Write-Host ""
        Write-Host "  Creating VM '$Name'" -ForegroundColor Cyan
        Write-Host "  RDP port : localhost:$port"
        Write-Host "  Project  : $ProjectPath"
        Write-Host "  RAM      : $([math]::Round($VmRam/1024, 0)) GB  |  CPU: $VmCpus cores"
        Write-Host "  Box      : $box"
        Write-Host ""
        if ($isNew) {
            Write-Warn "First run: downloads Ubuntu box (~700 MB) + provisions (~15 min)."
        } else {
            Write-Info "Using pre-built windsurf-base box - VM ready in ~1-2 min."
        }
        Write-Host ""

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
        Ensure-Config

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

        Write-Ok "VM '$Name' stopped. State preserved - 'vm start $Name' to resume."
    }

    "list" {
        $reg = Get-Registry
        Write-Host ""
        Write-Host "  Windsurf VM Instances" -ForegroundColor Cyan
        Write-Host "  ---------------------------------------------------------" -ForegroundColor DarkGray

        $props = $reg.instances.PSObject.Properties
        if ($props.Count -eq 0) {
            Write-Host "  (no instances)  Use: vm new <name>" -ForegroundColor DarkGray
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
                $line = "  {0,-16} RDP: localhost:{1,-6} [{2}]  Created: {3}" -f `
                    $prop.Name, $inst.rdp_port, $status, $inst.created
                Write-Host $line -ForegroundColor $color
            }
        }

        Write-Host "  ---------------------------------------------------------" -ForegroundColor DarkGray
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
        Write-Host "  (Your project files are NOT affected)" -ForegroundColor DarkGray
        $confirm = Read-Host "  Type 'yes' to confirm"

        if ($confirm -ne "yes") {
            Write-Info "Cancelled."
            exit 0
        }

        Write-Info "Destroying VM '$Name'..."
        Invoke-Vagrant $Name $instance.rdp_port @("destroy", "-f") | Out-Null

        $newInstances = [PSCustomObject]@{}
        foreach ($prop in $reg.instances.PSObject.Properties) {
            if ($prop.Name -ne $Name) {
                $newInstances | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value
            }
        }
        $reg.instances = $newInstances
        Save-Registry $reg

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