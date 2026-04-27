#!/usr/bin/env bash
# Windsurf VM Provision Script
# Ubuntu 22.04 - XFCE Desktop + xrdp + Python 3.13 + Windsurf IDE + Chrome + ibus-unikey
#
# Design principles:
#   * Idempotent: every stage can be re-run without error (required for "resume on error")
#   * Cache-aware: large .deb files cached in /var/cache/ws-vms/ to survive re-provisions
#   * Snap-free: snapd purged and pinned; all GUI apps installed via direct .deb
#   * Single source of truth for Python deps: /tmp/vm-requirements.txt
set -euo pipefail

VAGRANT_USER="${VAGRANT_USER:-vagrant}"
export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-y -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
CACHE=/var/cache/ws-vms

log()  { echo -e "\n[provision] $*"; }
ok()   { echo "  OK: $*"; }
warn() { echo "  WARN: $*"; }

mkdir -p "$CACHE"

# Helper: fetch a .deb into cache if missing, then install via apt
cache_install() {
    local name="$1" url="$2"
    local deb="$CACHE/$name.deb"
    if [ ! -f "$deb" ] || [ ! -s "$deb" ]; then
        log "  Downloading $name..."
        if ! wget -q --tries=3 --timeout=60 "$url" -O "$deb.tmp"; then
            warn "Download failed: $url"
            rm -f "$deb.tmp"
            return 1
        fi
        # Validate: must be >100KB for any real .deb package
        local size
        size=$(stat -c%s "$deb.tmp" 2>/dev/null || echo 0)
        if [ "$size" -lt 102400 ]; then
            warn "Downloaded file too small (${size} bytes), likely corrupted: $name"
            rm -f "$deb.tmp"
            return 1
        fi
        mv "$deb.tmp" "$deb"
    fi
    eatmydata apt-get install "${APT_OPTS[@]}" "$deb" 2>/dev/null \
        || apt-get install "${APT_OPTS[@]}" "$deb"
}

# 0. Switch to fast Vietnamese mirror + apt timeout
log "Configuring apt (VN mirror + timeout)..."
sed -i 's|http://archive.ubuntu.com|http://vn.archive.ubuntu.com|g' /etc/apt/sources.list
sed -i 's|http://security.ubuntu.com|http://vn.archive.ubuntu.com|g' /etc/apt/sources.list
cat > /etc/apt/apt.conf.d/99timeout << 'APTCONF'
Acquire::http::Timeout "60";
Acquire::https::Timeout "60";
Acquire::Retries "3";
APTCONF
ok "Mirror: vn.archive.ubuntu.com, Timeout: 60s"

# 1. Purge snap (fix: snap is very slow — replace with direct .deb workflow)
log "Purging snapd and pinning against reinstall..."
if dpkg -l snapd >/dev/null 2>&1; then
    systemctl disable --now snapd.service snapd.socket snapd.seeded.service 2>/dev/null || true
    apt-get purge "${APT_OPTS[@]}" snapd 2>/dev/null || true
    rm -rf /snap /var/snap /var/lib/snapd /root/snap "/home/${VAGRANT_USER}/snap" 2>/dev/null || true
    ok "snapd purged"
else
    ok "snapd already absent"
fi
cat > /etc/apt/preferences.d/nosnap.pref << 'NOSNAP'
# Prevent any package from re-introducing snapd
Package: snapd
Pin: release a=*
Pin-Priority: -10
NOSNAP
ok "nosnap.pref pinned"

# 2. System update + base packages (incl. eatmydata for faster installs)
log "System update + base packages..."
apt-get update -qq
apt-get install "${APT_OPTS[@]}" eatmydata
eatmydata apt-get upgrade "${APT_OPTS[@]}"
eatmydata apt-get install "${APT_OPTS[@]}" \
    curl wget git unzip ca-certificates gnupg \
    software-properties-common apt-transport-https \
    debconf-utils \
    dbus-x11 x11-xserver-utils at-spi2-core \
    cloud-guest-utils   # provides growpart
ok "System updated"

# 3. Grow root partition + filesystem (handle $VmDiskGB resize)
log "Growing root partition + filesystem (if needed)..."
ROOT_DEV=$(findmnt -n -o SOURCE / || true)
if [ -n "$ROOT_DEV" ] && [[ "$ROOT_DEV" =~ ^/dev/ ]]; then
    PART_NAME=$(basename "$ROOT_DEV")
    DISK=$(lsblk -no pkname "$ROOT_DEV" 2>/dev/null || true)
    PART_NUM=$(echo "$PART_NAME" | grep -oE '[0-9]+$' || true)
    if [ -n "$DISK" ] && [ -n "$PART_NUM" ]; then
        growpart "/dev/$DISK" "$PART_NUM" 2>/dev/null || true   # NOCHANGE if already full
        resize2fs "$ROOT_DEV" 2>/dev/null || true
        ok "Root grown to full VDI size ($(df -h / | awk 'NR==2 {print $2}'))"
    else
        warn "Could not determine root disk/partition layout — skipping grow"
    fi
else
    warn "Root device not under /dev — skipping grow"
fi

# 4. Pre-configure display manager (prevents gdm3.postinst blocking)
log "Pre-configuring display manager..."
echo "shared/default-x-display-manager select lightdm"        | debconf-set-selections
echo "lightdm shared/default-x-display-manager select lightdm" | debconf-set-selections
echo "gdm3 shared/default-x-display-manager select lightdm"   | debconf-set-selections
ok "lightdm pre-selected"

# 5. XFCE4 Desktop
log "Installing XFCE4 desktop..."
eatmydata apt-get install "${APT_OPTS[@]}" --no-install-recommends \
    xfce4 \
    xfce4-terminal \
    xfce4-notifyd \
    xfce4-screenshooter \
    thunar \
    mousepad \
    xorg \
    lightdm
ok "XFCE4 installed"

# 6. xrdp
log "Installing xrdp..."
eatmydata apt-get install "${APT_OPTS[@]}" xrdp
adduser xrdp ssl-cert || true

cat > /etc/xrdp/startwm.sh << 'ENDSESSION'
#!/bin/sh
unset DBUS_SESSION_BUS_ADDRESS
unset XDG_RUNTIME_DIR
if [ -r /etc/default/locale ]; then
    . /etc/default/locale
    export LANG LANGUAGE LC_ALL
fi
exec startxfce4
ENDSESSION
chmod +x /etc/xrdp/startwm.sh

echo "startxfce4" > "/home/${VAGRANT_USER}/.xsession"
chmod +x "/home/${VAGRANT_USER}/.xsession"
chown "${VAGRANT_USER}:${VAGRANT_USER}" "/home/${VAGRANT_USER}/.xsession"

sed -i "s/max_bpp=32/max_bpp=24/" /etc/xrdp/xrdp.ini 2>/dev/null || true
systemctl enable xrdp
systemctl restart xrdp
ok "xrdp configured"

# 7. Vagrant user password (for RDP login)
log "Setting vagrant password..."
echo "${VAGRANT_USER}:vagrant" | chpasswd
ok "Password set: vagrant / vagrant"

# 8. Python 3.13 (idempotent: guard PPA add + alternatives)
log "Installing Python 3.13..."
if ! grep -rq "deadsnakes" /etc/apt/sources.list.d/ 2>/dev/null; then
    add-apt-repository -y ppa:deadsnakes/ppa
    apt-get update -qq
fi
eatmydata apt-get install "${APT_OPTS[@]}" python3.13 python3.13-venv python3.13-dev \
    || eatmydata apt-get install "${APT_OPTS[@]}" python3.13 python3.13-venv

# Do NOT touch /usr/bin/python3 — apt_pkg is compiled for system python3.10
update-alternatives --install /usr/bin/python  python  /usr/bin/python3.13 1  2>/dev/null || true
update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.10 10 2>/dev/null || true

if ! command -v pip3.13 >/dev/null 2>&1 && ! python3.13 -m pip --version >/dev/null 2>&1; then
    curl -sS https://bootstrap.pypa.io/get-pip.py -o /tmp/get-pip.py
    python3.13 /tmp/get-pip.py --quiet
fi
python3.13 -m pip install --upgrade pip --quiet
ok "Python 3.13 + pip ready"

# 9. Python packages (via /tmp/vm-requirements.txt — single source of truth)
log "Installing Python packages from vm-requirements.txt..."
# Pre-fix: blinker 1.4 is a distutils package pip can't uninstall — force install newer
python3.13 -m pip install --quiet --ignore-installed "blinker>=1.6" || true

if [ -f /tmp/vm-requirements.txt ]; then
    python3.13 -m pip install --quiet --root-user-action=ignore \
        -r /tmp/vm-requirements.txt
    ok "Python packages installed from requirements file"
else
    warn "/tmp/vm-requirements.txt not found — file provisioner may have failed"
fi

# 10. Google Chrome (direct .deb + apt repo for auto-update, no snap)
log "Installing Google Chrome..."
if ! command -v google-chrome >/dev/null 2>&1; then
    CHROME_OK=false
    # Method 1: direct .deb download (fast, cached)
    if cache_install google-chrome-stable_amd64 \
        "https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb"; then
        CHROME_OK=true
    else
        # Method 2: add Google's apt repo and install from there
        warn "Direct .deb failed, adding Google apt repo..."
        wget -q -O - https://dl.google.com/linux/linux_signing_key.pub \
            | gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg 2>/dev/null || true
        echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main" \
            > /etc/apt/sources.list.d/google-chrome.list
        apt-get update -qq 2>/dev/null || true
        if eatmydata apt-get install "${APT_OPTS[@]}" google-chrome-stable 2>/dev/null; then
            CHROME_OK=true
        fi
    fi
    if [ "$CHROME_OK" = true ]; then
        ok "Chrome installed"
    else
        warn "Chrome installation failed -- install manually after boot"
    fi
else
    ok "Chrome already installed"
fi

# 11. ibus + ibus-unikey (Vietnamese input, standard Ubuntu repo)
log "Installing ibus + ibus-unikey..."
eatmydata apt-get install "${APT_OPTS[@]}" ibus ibus-gtk ibus-gtk3 ibus-unikey dconf-cli
ok "ibus + ibus-unikey installed"

# ibus system-wide configuration (works under root — no user X session needed)
log "Configuring ibus system-wide..."
# Environment variables for all users
for VAR in "GTK_IM_MODULE=ibus" "QT_IM_MODULE=ibus" "XMODIFIERS=@im=ibus"; do
    grep -q "^${VAR%=*}=" /etc/environment \
        && sed -i "s|^${VAR%=*}=.*|${VAR}|" /etc/environment \
        || echo "$VAR" >> /etc/environment
done

# dconf system database → default ibus engines for every user
mkdir -p /etc/dconf/profile /etc/dconf/db/local.d
cat > /etc/dconf/profile/user << 'DCONFPROF'
user-db:user
system-db:local
DCONFPROF
cat > /etc/dconf/db/local.d/00-ibus << 'DCONFIBUS'
[desktop/ibus/general]
preload-engines=['xkb:us::eng', 'Unikey']
engines-order=['xkb:us::eng', 'Unikey']

[desktop/ibus/general/hotkey]
triggers=['<Super>space']
DCONFIBUS
dconf update || true
ok "ibus dconf defaults written (engine: Unikey, toggle: Super+Space)"

# 12. Windsurf IDE (cache-aware)
log "Installing Windsurf IDE..."
WINDSURF_INSTALLED=false
if command -v windsurf >/dev/null 2>&1; then
    WINDSURF_INSTALLED=true
    ok "Windsurf already installed"
fi

if [ "$WINDSURF_INSTALLED" = false ]; then
    # Try apt repo first
    if [ ! -f /usr/share/keyrings/windsurf-archive-keyring.gpg ]; then
        curl -fsSL https://windsurf-stable.codeiumdata.com/wVxQEIWkwPUEAGf3/windsurf.gpg 2>/dev/null \
            | gpg --dearmor -o /usr/share/keyrings/windsurf-archive-keyring.gpg 2>/dev/null || true
    fi
    if [ -f /usr/share/keyrings/windsurf-archive-keyring.gpg ] && [ ! -f /etc/apt/sources.list.d/windsurf.list ]; then
        echo "deb [arch=amd64 signed-by=/usr/share/keyrings/windsurf-archive-keyring.gpg] https://windsurf-stable.codeiumdata.com/wVxQEIWkwPUEAGf3/apt stable main" \
            > /etc/apt/sources.list.d/windsurf.list
        apt-get update -qq 2>/dev/null || true
    fi
    if eatmydata apt-get install -y -qq windsurf 2>/dev/null; then
        WINDSURF_INSTALLED=true
        ok "Windsurf installed via apt repo"
    fi
fi

if [ "$WINDSURF_INSTALLED" = false ]; then
    warn "apt repo failed, trying direct .deb download..."
    WINDSURF_DEB_URL="https://windsurf-stable.codeiumdata.com/linux/deb/amd64/stable/windsurf-latest.deb"
    if cache_install windsurf "$WINDSURF_DEB_URL" 2>/dev/null; then
        WINDSURF_INSTALLED=true
        ok "Windsurf installed via direct download"
    else
        warn "Could not auto-install Windsurf. Install manually after boot."
    fi
fi

# 13. XFCE autostart: Windsurf + ibus-daemon
log "Configuring XFCE autostart..."
AUTOSTART_DIR="/home/${VAGRANT_USER}/.config/autostart"
mkdir -p "$AUTOSTART_DIR"

# Detect mount layout set by Vagrant shared_folder:
#   /project       exists  -> legacy single-project VM, auto-open it.
#   /projects/*    exist    -> multi-project VM, launch Windsurf without a
#                              path so user explicitly picks a folder.
#   SSH bridge configured  -> Remote-SSH to host (scoped or browse mode).
if [ -n "${VM_HOST_IP:-}" ] && [ -n "${VM_BRIDGE_KEY:-}" ]; then
    if [ -n "${VM_PROJECTS:-}" ] && [ "$VM_PROJECTS" != "[]" ]; then
        # Projects specified: generate workspace scoped to those folders only
        WINDSURF_EXEC="windsurf /home/${VAGRANT_USER}/host.code-workspace"
        log "Autostart: Windsurf will open scoped workspace (project folders only)"
    else
        # Browse mode: open Windows home directory directly via Remote-SSH.
        # This gives full project browsing identical to native Windsurf on Windows.
        # URL-encode spaces in username (rare but valid in Windows local accounts).
        # Quote the URI in the Exec= line so .desktop spec parses it as one argument.
        ENCODED_USER=$(printf '%s' "${VM_HOST_USER}" | sed 's/ /%20/g')
        FOLDER_URI="vscode-remote://ssh-remote+host/C:/Users/${ENCODED_USER}"
        WINDSURF_EXEC="windsurf --folder-uri \"${FOLDER_URI}\""
        log "Autostart: Windsurf will open Windows home (C:/Users/${VM_HOST_USER}) via Remote-SSH"
    fi
elif [ -d /project ]; then
    WINDSURF_EXEC="windsurf /project"
    log "Autostart: Windsurf will auto-open /project (legacy mode)"
else
    WINDSURF_EXEC="windsurf"
    log "Autostart: Windsurf will launch without a folder (multi-project mode)"
fi

cat > "${AUTOSTART_DIR}/windsurf.desktop" << ENDDESKTOP
[Desktop Entry]
Type=Application
Name=Windsurf IDE
Exec=${WINDSURF_EXEC}
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
ENDDESKTOP

cat > "${AUTOSTART_DIR}/ibus-daemon.desktop" << 'ENDIBUS'
[Desktop Entry]
Type=Application
Name=IBus Daemon
Exec=ibus-daemon -drxR
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
ENDIBUS

chown -R "${VAGRANT_USER}:${VAGRANT_USER}" "/home/${VAGRANT_USER}/.config"
ok "Windsurf + ibus autostart configured"

# 14. Locale & timezone (idempotent)
log "Setting locale and timezone..."
ln -sf /usr/share/zoneinfo/Asia/Ho_Chi_Minh /etc/localtime
if ! grep -q "^en_US.UTF-8 UTF-8" /etc/locale.gen; then
    locale-gen en_US.UTF-8
fi
update-locale LANG=en_US.UTF-8
ok "Locale + timezone set"

# 15. Git config
runuser -l "${VAGRANT_USER}" -c "git config --global core.autocrlf input" || true
runuser -l "${VAGRANT_USER}" -c "git config --global core.eol lf"         || true

# 16. SSH Bridge to Host (conditional — only when bridge config is provided)
if [ -n "${VM_HOST_IP:-}" ] && [ -n "${VM_BRIDGE_KEY:-}" ]; then
    log "Configuring SSH bridge to Windows host..."

    SSH_DIR="/home/${VAGRANT_USER}/.ssh"
    mkdir -p "$SSH_DIR"

    # Write private key (passed as base64-encoded env var)
    # Use printf (not echo) to avoid trailing newline corrupting base64 decode
    printf '%s' "$VM_BRIDGE_KEY" | base64 -d > "$SSH_DIR/bridge_key"
    chmod 600 "$SSH_DIR/bridge_key"

    # Write known_hosts (pinned host key — prevents TOFU prompts)
    if [ -n "${VM_HOST_KEY:-}" ]; then
        printf '%s' "$VM_HOST_KEY" | base64 -d > "$SSH_DIR/known_hosts"
        chmod 644 "$SSH_DIR/known_hosts"
    fi

    # SSH client config — host alias "host" for zero-friction connect
    cat > "$SSH_DIR/config" << SSHCONF
Host host
    HostName ${VM_HOST_IP}
    User ${VM_HOST_USER}
    IdentityFile ~/.ssh/bridge_key
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
    UserKnownHostsFile ~/.ssh/known_hosts
    ConnectTimeout 10
    ServerAliveInterval 30
    ServerAliveCountMax 5
SSHCONF
    chmod 600 "$SSH_DIR/config"
    chown -R "${VAGRANT_USER}:${VAGRANT_USER}" "$SSH_DIR"

    # Windsurf workspace file for auto-connect (Remote-SSH)
    # Only generated when projects are specified (-p flag).
    # Each project gets its own folder entry scoped to that exact path.
    WS_FILE="/home/${VAGRANT_USER}/host.code-workspace"
    if [ -n "${VM_PROJECTS:-}" ] && [ "$VM_PROJECTS" != "[]" ]; then
        python3 -c "
import json, sys
projects = json.loads(sys.argv[1])
folders = []
for p in projects:
    # Convert Windows backslash path to forward-slash URI
    win_path = p['host_path'].replace(chr(92), '/')
    folders.append({
        'uri': f'vscode-remote://ssh-remote+host/{win_path}',
        'name': p['name']
    })
ws = {
    'folders': folders,
    'settings': {
        'remote.SSH.remotePlatform': {'host': 'windows'},
        'remote.SSH.connectTimeout': 30
    }
}
print(json.dumps(ws, indent=4))
" "$VM_PROJECTS" > "$WS_FILE"
        chown "${VAGRANT_USER}:${VAGRANT_USER}" "$WS_FILE"
        ok "Workspace: scoped to $(echo "$VM_PROJECTS" | python3 -c "import json,sys; print(', '.join(p['name'] for p in json.loads(sys.stdin.read())))")"
    else
        ok "Workspace: browse mode (auto-opens C:/Users/${VM_HOST_USER} on login)"
    fi

    ok "SSH bridge configured (host: ${VM_HOST_IP}, user: ${VM_HOST_USER})"
else
    log "SSH bridge: skipped (no bridge config provided)"
fi

echo ""
echo "============================================"
echo "  VM provision complete!"
echo "============================================"
echo "  RDP:      mstsc -> localhost:<port>"
echo "  Login:    vagrant / vagrant"
if [ -n "${VM_HOST_IP:-}" ] && [ -n "${VM_BRIDGE_KEY:-}" ]; then
    if [ -n "${VM_PROJECTS:-}" ] && [ "$VM_PROJECTS" != "[]" ]; then
        echo "  Mode:     bridge + scoped projects"
    else
        echo "  Mode:     bridge browse (no shared folders)"
    fi
    echo "  Bridge:   ${VM_HOST_IP} (user: ${VM_HOST_USER}) - auto-connects on login"
elif [ -d /projects ]; then
    echo "  Projects: /projects/*"
elif [ -d /project ]; then
    echo "  Project:  /project"
fi
echo "  Cache:    $CACHE"
echo "  Disk:     $(df -h / | awk 'NR==2 {print $2,"total,",$4,"free"}')"
if [ "$WINDSURF_INSTALLED" = true ]; then
    echo "  Windsurf: auto-launches on RDP login"
else
    echo "  Windsurf: MANUAL INSTALL REQUIRED"
fi
echo "  Chrome:   $(command -v google-chrome >/dev/null && echo 'installed' || echo 'MISSING')"
echo "  ibus:     $(dpkg -s ibus-unikey >/dev/null 2>&1 && echo 'unikey installed' || echo 'MISSING')"
echo ""
