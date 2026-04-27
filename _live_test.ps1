<#
  Live test:
    Step 1 -- Apply from= restriction to authorized_keys (AAIS bridge key)
    Step 2 -- SSH host->host via 192.168.56.1 using bridge key (simulates VM->host)
    Step 3 -- SSH from running AAIS VM back to host (actual VM->host direction)
#>

# Bridge key found at AAIS vm dir (windsurf-vms has not run setup-host yet)
$BridgeKey    = "C:\Users\email\Desktop\mkt_tools\DAeCS\AAIS\vm\.ssh\vm_bridge_key"
$authKeysPath = "$env:USERPROFILE\.ssh\authorized_keys"
$HostIP       = "192.168.56.1"

$pass = 0; $fail = 0
function Ok   ($m) { Write-Host "  PASS  $m" -ForegroundColor Green;  $script:pass++ }
function Fail ($m) { Write-Host "  FAIL  $m" -ForegroundColor Red;    $script:fail++ }
function Info ($m) { Write-Host "  ....  $m" -ForegroundColor Gray }

# Step 1: Apply from= restriction to live authorized_keys
Write-Host "`n[1] Applying from= restriction to authorized_keys" -ForegroundColor Cyan

if (-not (Test-Path $BridgeKey)) {
    Fail "Bridge key not found at $BridgeKey"
} else {
    # Derive pubkey: try .pub file, else extract via ssh-keygen
    $pubKeyFile = "$BridgeKey.pub"
    if (Test-Path $pubKeyFile) {
        $pubKey = (Get-Content $pubKeyFile -Raw).Trim()
    } else {
        $pubKey = (& ssh-keygen -y -f $BridgeKey 2>$null | Out-String).Trim()
        $pubKey += " windsurf-vm-bridge"
    }
    if ($pubKey) {

        $lines = if (Test-Path $authKeysPath) {
            Get-Content $authKeysPath -ErrorAction SilentlyContinue
        } else { @() }

        $alreadyCorrect = @($lines | Where-Object {
            $_ -match "windsurf-vm-bridge" -and $_ -match 'from="192\.168\.56\.\*"'
        }).Count -gt 0

        if ($alreadyCorrect) {
            Ok "from= restriction already present (no change needed)"
        } else {
            $cleanedLines  = @($lines | Where-Object { $_ -notmatch "windsurf-vm-bridge" })
            $restrictedKey = "from=`"192.168.56.*`" $pubKey"
            $newContent    = (($cleanedLines + $restrictedKey) | Where-Object { $_ -ne "" }) -join "`n"
            [System.IO.File]::WriteAllText($authKeysPath, $newContent.Trim() + "`n",
                [System.Text.UTF8Encoding]::new($false))
            Ok "from= restriction applied to authorized_keys"

            # Verify
            $verify = Get-Content $authKeysPath | Where-Object {
                $_ -match "windsurf-vm-bridge" -and $_ -match 'from="192\.168\.56\.\*"'
            }
            if ($verify) { Ok "Verified: key with from= restriction written correctly" }
            else          { Fail "Verification failed -- key not found with restriction" }
        }
    }
}

# Step 2: SSH host->host via bridge key (simulates VM->host exactly)
Write-Host "`n[2] SSH connectivity test (host->$HostIP via bridge key)" -ForegroundColor Cyan
Info "Simulates exactly what VM does when connecting to Windows host"

$ssh = Get-Command ssh -ErrorAction SilentlyContinue
if (-not $ssh) { Fail "ssh.exe not found on PATH"; exit 1 }

if (-not (Test-Path $BridgeKey)) {
    Fail "Bridge key missing -- cannot test SSH"
} else {
    Info "Testing: ssh -i vm_bridge_key $env:USERNAME@$HostIP echo ssh_ok"
    $out = & ssh `
        -i $BridgeKey `
        -o StrictHostKeyChecking=no `
        -o BatchMode=yes `
        -o ConnectTimeout=8 `
        -o PasswordAuthentication=no `
        "$env:USERNAME@$HostIP" "echo ssh_ok" 2>&1

    if ($out -match "ssh_ok") {
        Ok "SSH key auth: connected and echo succeeded"
    } else {
        Fail "SSH connection failed. Output: $($out -join ' ')"
    }

    # Test 2: from= restriction active -- try with wrong source should not apply
    # (Can only verify restriction is IN the file; runtime enforcement is by sshd)
    $restriction = Get-Content $authKeysPath |
        Where-Object { $_ -match "windsurf-vm-bridge" -and $_ -match 'from=' }
    if ($restriction) {
        Ok "from= restriction confirmed in authorized_keys (enforced by sshd)"
    } else {
        Fail "from= restriction missing from authorized_keys"
    }

    # Test 3: run a realistic command (simulates Windsurf Remote-SSH probe)
    Info "Testing: remote command 'whoami'"
    $who = & ssh `
        -i $BridgeKey `
        -o StrictHostKeyChecking=no `
        -o BatchMode=yes `
        -o ConnectTimeout=8 `
        -o PasswordAuthentication=no `
        "$env:USERNAME@$HostIP" "whoami" 2>&1

    if ($who -match $env:USERNAME) {
        Ok "Remote whoami: $($who -join '')"
    } else {
        Fail "whoami failed or returned unexpected: $($who -join ' ')"
    }

    # Test 4: file access -- read a file on host from "remote" (simulates Remote-SSH)
    Info "Testing: read remote file (simulates Windsurf file browser)"
    $rd = & ssh `
        -i $BridgeKey `
        -o StrictHostKeyChecking=no `
        -o BatchMode=yes `
        -o ConnectTimeout=8 `
        -o PasswordAuthentication=no `
        "$env:USERNAME@$HostIP" "dir /b C:\Users\$env:USERNAME" 2>&1

    if ($LASTEXITCODE -eq 0) {
        Ok "Remote dir C:\Users\$env:USERNAME succeeded ($(@($rd).Count) entries)"
    } else {
        Fail "Remote dir failed: $($rd -join ' ')"
    }
}

# Step 3: Actual VM->host SSH (AAIS VM is running)
Write-Host "`n[3] Actual VM->host SSH (from daecs-aais VM)" -ForegroundColor Cyan
$vboxPath = @(
    "$env:ProgramFiles\Oracle\VirtualBox\VBoxManage.exe",
    "${env:ProgramFiles(x86)}\Oracle\VirtualBox\VBoxManage.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if ($vboxPath) {
    $running = & $vboxPath list runningvms 2>$null
    if ($running -match 'daecs-aais') {
        Info "daecs-aais is running -- testing SSH into VM then bridge back to host"
        # Find vagrant dir for AAIS
        $aaisVmDir = "C:\Users\email\Desktop\mkt_tools\DAeCS\AAIS\vm"
        $vagrantExe = Get-Command vagrant -ErrorAction SilentlyContinue
        if ($vagrantExe -and (Test-Path $aaisVmDir)) {
            $env:VAGRANT_CWD = $aaisVmDir
            # Use direct IP (AAIS VM may not have 'Host host' alias from windsurf-vms provision)
            $aaisKey = "C:\Users\email\Desktop\mkt_tools\DAeCS\AAIS\workspace\.ssh\vm_bridge_key"
            $bridgeCmd = "ssh -i ~/.ssh/bridge_key -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new $env:USERNAME@$HostIP echo bridge_ok 2>&1"
            $bridgeTest = & vagrant ssh -c $bridgeCmd 2>&1 | Out-String
            Remove-Item Env:VAGRANT_CWD -ErrorAction SilentlyContinue
            if ($bridgeTest -match "bridge_ok") {
                Ok "VM->host bridge via IP: echo bridge_ok succeeded"
            } else {
                Fail "VM->host bridge failed. Output: $($bridgeTest.Trim())"
            }
        } else {
            Info "vagrant not found or AAIS vm dir missing -- skipping VM->host test"
        }
    } else {
        Info "No windsurf-vms instances running. Start with 'vm start dev' for end-to-end test"
        Info "daecs-aais found but uses different bridge config"
    }
} else {
    Info "VBoxManage not found -- skipping VM test"
}

# Summary
$color = if ($fail -eq 0) { "Green" } else { "Red" }
Write-Host ""
Write-Host "  Passed: $pass  Failed: $fail" -ForegroundColor $color
Write-Host ""
if ($fail -gt 0) { exit 1 }

Remove-Item $MyInvocation.MyCommand.Path -Force
