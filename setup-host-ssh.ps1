<#
.SYNOPSIS
    One-time setup: configure Windows host as SSH target for Windsurf VM bridge.

.DESCRIPTION
    Creates VirtualBox host-only adapter, installs/configures OpenSSH Server,
    generates VM bridge keypair, installs public key, configures firewall.
    Idempotent -- safe to re-run. Requires elevation (auto-requests if needed).

.NOTES
    Run via: .\vm.bat setup-host
    Or directly: powershell -ExecutionPolicy Bypass -File setup-host-ssh.ps1
#>
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RootDir    = $PSScriptRoot
$SshDir     = Join-Path $RootDir ".ssh"
$BridgeKey  = Join-Path $SshDir "vm_bridge_key"
$BridgePub  = Join-Path $SshDir "vm_bridge_key.pub"
$HostKeyFile = Join-Path $SshDir "host_key"
$ConfigFile = Join-Path $RootDir ".bridge-config.json"

$HostOnlyIP   = "192.168.56.1"
$HostOnlyMask = "255.255.255.0"
$SubnetCIDR   = "192.168.56.0/24"

# --- Helpers -----------------------------------------------------------------
function Write-Step  ($n, $msg) { Write-Host "`n  [$n/9] $msg" -ForegroundColor Cyan }
function Write-Ok    ($msg)     { Write-Host "        OK: $msg" -ForegroundColor Green }
function Write-Warn  ($msg)     { Write-Host "        ! $msg" -ForegroundColor Yellow }
function Write-Err   ($msg)     { Write-Host "        X $msg" -ForegroundColor Red }

function Resolve-VBoxManage {
    $onPath = Get-Command VBoxManage -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    foreach ($dir in @(
        "$env:ProgramFiles\Oracle\VirtualBox",
        "${env:ProgramFiles(x86)}\Oracle\VirtualBox",
        "$env:ProgramW6432\Oracle\VirtualBox"
    )) {
        $exe = Join-Path $dir "VBoxManage.exe"
        if (Test-Path $exe) { return $exe }
    }
    return $null
}

# --- Elevation check ---------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "`n  Requesting administrator privileges..." -ForegroundColor Yellow
    $elevateArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    $proc = Start-Process powershell -ArgumentList $elevateArgs -Verb RunAs -Wait -PassThru
    exit $proc.ExitCode
}

Write-Host ""
Write-Host "  Windsurf VM -- Host SSH Bridge Setup" -ForegroundColor Cyan
Write-Host "  ===========================================================" -ForegroundColor DarkGray

# --- Step 0: Verify VBoxManage is available ----------------------------------
$VBM = Resolve-VBoxManage
if (-not $VBM) {
    Write-Err "VBoxManage not found. Install VirtualBox or add it to PATH."
    Write-Host "        Download: https://www.virtualbox.org/wiki/Downloads" -ForegroundColor Gray
    exit 1
}

# --- Step 1: VirtualBox Host-Only Adapter ------------------------------------
Write-Step 1 "VirtualBox host-only adapter"

# Find existing host-only interfaces
$hostonlyList = & $VBM list hostonlyifs 2>$null | Out-String
$adapterName = ""

if ($hostonlyList -match "Name:\s+(.+)") {
    $adapterName = $Matches[1].Trim()
    Write-Ok "Found existing adapter: $adapterName"
} else {
    Write-Warn "No host-only adapter found. Creating one..."
    $createOutput = & $VBM hostonlyif create 2>&1 | Out-String
    if ($createOutput -match "Interface '([^']+)'") {
        $adapterName = $Matches[1]
    } else {
        # Retry detection
        $hostonlyList = & $VBM list hostonlyifs 2>$null | Out-String
        if ($hostonlyList -match "Name:\s+(.+)") {
            $adapterName = $Matches[1].Trim()
        } else {
            Write-Err "Failed to create host-only adapter. Is VirtualBox installed?"
            exit 1
        }
    }
    Write-Ok "Created adapter: $adapterName"
}

# Configure IP
& $VBM hostonlyif ipconfig "$adapterName" --ip $HostOnlyIP --netmask $HostOnlyMask 2>$null
Write-Ok "IP configured: $HostOnlyIP/$HostOnlyMask"

# Disable DHCP server on this adapter
$dhcpList = & $VBM list dhcpservers 2>$null | Out-String
if ($dhcpList -match $adapterName) {
    & $VBM dhcpserver remove --ifname "$adapterName" 2>$null
    Write-Ok "DHCP server disabled"
} else {
    Write-Ok "DHCP server already disabled"
}

# --- Step 2: OpenSSH Server --------------------------------------------------
Write-Step 2 "OpenSSH Server"

$sshCapability = Get-WindowsCapability -Online -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like "OpenSSH.Server*" } | Select-Object -First 1
if (-not $sshCapability) {
    # Capability not listed — check if binary already present (manual/OEM install)
    if (-not (Get-Command sshd -ErrorAction SilentlyContinue)) {
        Write-Err "OpenSSH.Server not found. Install via: Settings > Apps > Optional Features > OpenSSH Server"
        exit 1
    }
    Write-Ok "OpenSSH Server binary found (pre-installed)"
} elseif ($sshCapability.State -ne "Installed") {
    Write-Warn "Installing OpenSSH Server..."
    Add-WindowsCapability -Online -Name $sshCapability.Name | Out-Null
    Write-Ok "OpenSSH Server installed"
} else {
    Write-Ok "OpenSSH Server already installed"
}

# Ensure service exists and is set to auto-start
Set-Service -Name sshd -StartupType Automatic -ErrorAction SilentlyContinue
Start-Service sshd -ErrorAction SilentlyContinue
$sshdInitSvc   = Get-Service sshd -ErrorAction SilentlyContinue
$sshdInitState = if ($sshdInitSvc) { $sshdInitSvc.Status } else { "not found" }
if ($sshdInitState -eq "Running") {
    Write-Ok "sshd service: running + auto-start"
} else {
    Write-Warn "sshd service state: $sshdInitState (Step 3 will restart after config changes)"
}

# --- Step 3: Configure sshd_config -------------------------------------------
Write-Step 3 "sshd_config"

$sshdConfig = "$env:ProgramData\ssh\sshd_config"
$configContent = Get-Content $sshdConfig -Raw -ErrorAction SilentlyContinue

# Backup original (only once -- skip if any backup already exists)
$backup = "$sshdConfig.backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
$existingBackups = Get-ChildItem "$env:ProgramData\ssh\sshd_config.backup-*" -ErrorAction SilentlyContinue
if (-not $existingBackups) {
    Copy-Item $sshdConfig $backup
    Write-Ok "Backed up original to $backup"
} else {
    Write-Ok "Backup already exists (skipped)"
}

# Build desired config lines
# NOTE: No ListenAddress — sshd binds 0.0.0.0 so it starts reliably after
# reboot even if the VirtualBox host-only adapter isn't up yet.
# Security is enforced by the firewall rule (Step 6) which restricts port 22
# to RemoteAddress 192.168.56.0/24 -> LocalAddress 192.168.56.1 only.
$desiredSettings = @{
    "PubkeyAuthentication"   = "yes"
    "PasswordAuthentication" = "no"
}

# Remove any pre-existing ListenAddress lines — sshd must bind 0.0.0.0 to start
# reliably after boot regardless of VirtualBox adapter initialization order.
$configContent = $configContent -replace "(?m)^#?\s*ListenAddress\s+.*$\r?\n?", ""

foreach ($key in $desiredSettings.Keys) {
    $value = $desiredSettings[$key]
    $pattern = "(?m)^#?\s*$key\s+.*$"
    $replacement = "$key $value"
    if ($configContent -match $pattern) {
        $configContent = $configContent -replace $pattern, $replacement
    } else {
        $configContent += "`n$replacement"
    }
}

# Remove the default Windows OpenSSH admin Match block that forces a different
# AuthorizedKeysFile path. We handle admin keys ourselves in Step 5.
# Only remove the specific 2-line block (Match Group administrators + AuthorizedKeysFile).
$adminMatchPattern = "(?m)^\s*Match Group administrators\s*\r?\n\s*AuthorizedKeysFile[^\r\n]*\r?\n?"
$configContent = $configContent -replace $adminMatchPattern, ""

[System.IO.File]::WriteAllText($sshdConfig, $configContent.Trim(),
    [System.Text.UTF8Encoding]::new($false))
Write-Ok "sshd_config updated (key-only auth, sshd binds 0.0.0.0)"

# Restart to apply
try {
    Restart-Service sshd -ErrorAction Stop
    Write-Ok "sshd restarted"
} catch {
    Write-Warn "sshd restart failed: $_"
    Write-Warn "Trying Stop + Start..."
    Stop-Service sshd -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Start-Service sshd -ErrorAction SilentlyContinue
    $sshdSvc2   = Get-Service sshd -ErrorAction SilentlyContinue
    $sshdState2 = if ($sshdSvc2) { $sshdSvc2.Status } else { "not found" }
    if ($sshdState2 -eq "Running") { Write-Ok "sshd running" }
    else { Write-Warn "sshd state: $sshdState2 -- verify: Get-Service sshd" }
}

# --- Step 4: Generate VM bridge keypair --------------------------------------
Write-Step 4 "VM bridge keypair"

New-Item -ItemType Directory -Force -Path $SshDir | Out-Null

if (Test-Path $BridgeKey) {
    Write-Ok "Keypair already exists: $BridgeKey"
} else {
    # Generate ed25519 key without passphrase.
    # Windows ssh-keygen requires empty passphrase as two double-quotes passed via cmd.
    $keygenArgs = @("-t", "ed25519", "-f", $BridgeKey, "-N", "", "-C", "windsurf-vm-bridge", "-q")
    & ssh-keygen @keygenArgs 2>$null
    if (-not (Test-Path $BridgeKey)) {
        # Fallback: pipe empty input for interactive passphrase prompt
        "" | & ssh-keygen -t ed25519 -f $BridgeKey -C "windsurf-vm-bridge" -q 2>$null
    }
    if (Test-Path $BridgeKey) {
        Write-Ok "Generated ed25519 keypair at $BridgeKey"
    } else {
        Write-Err "Failed to generate SSH key. Ensure ssh-keygen is available."
        exit 1
    }
}

# --- Step 5: Install public key on host --------------------------------------
Write-Step 5 "Install public key"

$pubKey = (Get-Content $BridgePub -Raw).Trim()
$currentUser = $env:USERNAME

# Since we removed the Match Group administrators block in Step 3, OpenSSH
# uses the global AuthorizedKeysFile (.ssh/authorized_keys in user home)
# for ALL users including administrators. Write there for everyone.
$authKeysDir  = "$env:USERPROFILE\.ssh"
$authKeysPath = "$authKeysDir\authorized_keys"
New-Item -ItemType Directory -Force -Path $authKeysDir | Out-Null

# Install key with from= restriction (limits key use to host-only subnet only).
# Idempotent: removes any pre-existing windsurf-vm-bridge entry first so that
# old installs without the from= restriction are upgraded on re-run.
$lines = if (Test-Path $authKeysPath) {
    Get-Content $authKeysPath -ErrorAction SilentlyContinue
} else { @() }

$alreadyCorrect = @($lines | Where-Object {
    $_ -match "windsurf-vm-bridge" -and $_ -match 'from="192\.168\.56\.\*"'
}).Count -gt 0

if ($alreadyCorrect) {
    Write-Ok "Bridge key already installed (with from= restriction)"
} else {
    $cleanedLines  = @($lines | Where-Object { $_ -notmatch "windsurf-vm-bridge" })
    $restrictedKey = "from=`"192.168.56.*`" $pubKey"
    $newContent    = (($cleanedLines + $restrictedKey) | Where-Object { $_ -ne "" }) -join "`n"
    [System.IO.File]::WriteAllText($authKeysPath, $newContent.Trim() + "`n",
        [System.Text.UTF8Encoding]::new($false))
    Write-Ok "Bridge key installed with from= restriction in $authKeysPath"
}

# Fix ACLs on the .ssh directory and authorized_keys (Windows OpenSSH requires
# that authorized_keys is not accessible by "others", only owner + SYSTEM).
try {
    $acl = Get-Acl $authKeysPath
    $acl.SetAccessRuleProtection($true, $false)  # disable inheritance
    $ownerRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $currentUser, "FullControl", "Allow")
    $systemRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        "SYSTEM", "FullControl", "Allow")
    $acl.SetAccessRule($ownerRule)
    $acl.SetAccessRule($systemRule)
    Set-Acl $authKeysPath $acl
    Write-Ok "ACLs set ($currentUser + SYSTEM only)"
} catch {
    Write-Warn "Could not set ACLs on $authKeysPath -- SSH may reject the key. Error: $_"
}

# --- Step 6: Windows Firewall ------------------------------------------------
Write-Step 6 "Windows Firewall rule"

$ruleName = "Windsurf VM SSH Bridge"

# Disable any broad default OpenSSH rules that would allow TCP/22 from ANY source.
# Windows Firewall allows a packet if ANY Allow rule matches, so the default
# "OpenSSH SSH Server (sshd)" rule would keep port 22 open to all networks even
# after we add our VM-scoped rule. We Disable (not Remove) so it's reversible.
$broadRules = Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object {
    ($_.DisplayName -like "*OpenSSH*SSH*" -or $_.DisplayName -like "*OpenSSH-Server*") `
    -and $_.Action -eq "Allow" `
    -and $_.Enabled -eq $true `
    -and $_.DisplayName -ne $ruleName
}
foreach ($r in $broadRules) {
    Disable-NetFirewallRule -Name $r.Name
    Write-Warn "Disabled '$($r.DisplayName)' (was allowing TCP/22 from ANY source)"
    Write-Warn "  Re-enable if needed: Enable-NetFirewallRule -DisplayName '$($r.DisplayName)'"
}

$existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
if ($existing) {
    Remove-NetFirewallRule -DisplayName $ruleName
}

New-NetFirewallRule `
    -DisplayName $ruleName `
    -Direction Inbound `
    -Protocol TCP `
    -LocalPort 22 `
    -LocalAddress $HostOnlyIP `
    -RemoteAddress $SubnetCIDR `
    -Action Allow `
    -Profile Any `
    -Description "Allow SSH from Windsurf VMs (host-only network) only" | Out-Null

Write-Ok "Rule '$ruleName': TCP/22, from $SubnetCIDR to $HostOnlyIP only"

# --- Step 7: Capture host SSH host key ----------------------------------------
Write-Step 7 "Host SSH fingerprint"

# Wait a moment for sshd to be fully ready after restart
Start-Sleep -Seconds 2

$hostKey = & ssh-keyscan -H $HostOnlyIP 2>$null | Out-String
if ([string]::IsNullOrWhiteSpace($hostKey)) {
    Write-Warn "Could not scan host key (sshd may not be listening yet on $HostOnlyIP)"
    Write-Warn "Re-run 'vm setup-host' after confirming sshd is running."
    $hostKey = ""
} else {
    [System.IO.File]::WriteAllText($HostKeyFile, $hostKey.Trim(),
        [System.Text.UTF8Encoding]::new($false))
    Write-Ok "Host key captured and saved to .ssh/host_key"
}

# --- Step 8: Save bridge config ----------------------------------------------
Write-Step 8 "Bridge config"

$bridgeConfig = @{
    host_user  = $currentUser
    host_ip    = $HostOnlyIP
    key_path   = $BridgeKey
    host_key   = $HostKeyFile
    adapter    = $adapterName
    setup_date = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
} | ConvertTo-Json -Depth 5

[System.IO.File]::WriteAllText($ConfigFile, $bridgeConfig,
    [System.Text.UTF8Encoding]::new($false))
Write-Ok "Saved .bridge-config.json"

# --- Step 9: Self-test SSH connectivity --------------------------------------
Write-Step 9 "SSH self-test"

# Test from host-only IP (192.168.56.1) — matches the from= restriction on the key.
# Verifies: sshd running, key loaded, authorized_keys correct, ACLs OK, AND subnet routing.
$sshCmd = Get-Command ssh -ErrorAction SilentlyContinue
$sshBin = if ($sshCmd) { $sshCmd.Source } else { $null }
if ($sshBin) {
    $testOut = & $sshBin `
        -o BatchMode=yes `
        -o ConnectTimeout=8 `
        -o StrictHostKeyChecking=no `
        -o UserKnownHostsFile=NUL `
        -i $BridgeKey `
        "${currentUser}@${HostOnlyIP}" "echo ssh_ok" 2>&1 | Out-String
    if ($testOut -match "ssh_ok") {
        Write-Ok "SSH key auth confirmed working (host-only IP test passed)"
    } else {
        Write-Warn "SSH host-only test did not return expected output."
        Write-Warn "Verify host-only adapter is up and firewall rule allows ${SubnetCIDR}."
        Write-Warn "Manual check after VM boot: ssh -i .ssh/bridge_key ${currentUser}@${HostOnlyIP}"
        # Diagnostics
        $sshdSvc    = Get-Service sshd -ErrorAction SilentlyContinue
        $sshdStatus = if ($sshdSvc) { $sshdSvc.Status } else { "not found" }
        Write-Host "        sshd service  : $sshdStatus" -ForegroundColor Gray
        $listenLines = netstat -an 2>$null | Select-String ":22 " |
            Select-Object -First 3 | ForEach-Object { $_.Line.Trim() }
        Write-Host "        :22 listeners : $($listenLines -join ' | ')" -ForegroundColor Gray
        Write-Host "        authorized_keys: $authKeysPath" -ForegroundColor Gray
    }
} else {
    Write-Warn "ssh.exe not found on PATH -- skipping self-test. Verify manually after VM boot."
}

# --- Done --------------------------------------------------------------------
Write-Host ""
Write-Host "  ===========================================================" -ForegroundColor DarkGray
Write-Host "  Setup complete!" -ForegroundColor Green
Write-Host ""
Write-Host "  Host-only adapter : $adapterName ($HostOnlyIP)" -ForegroundColor Gray
Write-Host "  SSH server        : sshd on 0.0.0.0:22 (firewall limits to $SubnetCIDR)" -ForegroundColor Gray
Write-Host "  Auth              : key-only (no password)" -ForegroundColor Gray
Write-Host "  Firewall          : TCP/22 from $SubnetCIDR -> $HostOnlyIP only" -ForegroundColor Gray
Write-Host "  Bridge key        : $BridgeKey" -ForegroundColor Gray
Write-Host "  Authorized keys   : $authKeysPath" -ForegroundColor Gray
Write-Host ""
Write-Host "  Next: vm new <name>   (bridge auto-configured, no -p needed)" -ForegroundColor Cyan
Write-Host ""
