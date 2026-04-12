#!/usr/bin/env bash
# Windsurf VM Provision Script
# Ubuntu 22.04 - XFCE Desktop + xrdp + Python 3.13 + Windsurf IDE
set -euo pipefail

VAGRANT_USER="${VAGRANT_USER:-vagrant}"
export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-y -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

log()  { echo -e "\n[provision] $*"; }
ok()   { echo "  OK: $*"; }
warn() { echo "  WARN: $*"; }

# 0. Switch to fast Vietnamese mirror + set apt timeout
log "Configuring apt (VN mirror + timeout)..."
sed -i 's|http://archive.ubuntu.com|http://vn.archive.ubuntu.com|g' /etc/apt/sources.list
sed -i 's|http://security.ubuntu.com|http://vn.archive.ubuntu.com|g' /etc/apt/sources.list
cat > /etc/apt/apt.conf.d/99timeout << 'APTCONF'
Acquire::http::Timeout "60";
Acquire::https::Timeout "60";
Acquire::Retries "3";
APTCONF
ok "Mirror: vn.archive.ubuntu.com, Timeout: 60s"

# 1. System update
log "System update..."
apt-get update -qq
apt-get upgrade "${APT_OPTS[@]}"
apt-get install "${APT_OPTS[@]}" \
    curl wget git unzip ca-certificates gnupg \
    software-properties-common apt-transport-https \
    debconf-utils \
    dbus-x11 x11-xserver-utils at-spi2-core
ok "System updated"

# 2. Pre-configure display manager (prevents gdm3.postinst blocking)
log "Pre-configuring display manager..."
echo "shared/default-x-display-manager select lightdm"        | debconf-set-selections
echo "lightdm shared/default-x-display-manager select lightdm" | debconf-set-selections
echo "gdm3 shared/default-x-display-manager select lightdm"   | debconf-set-selections
ok "lightdm pre-selected"

# 3. XFCE4 Desktop
log "Installing XFCE4 desktop..."
apt-get install "${APT_OPTS[@]}" --no-install-recommends \
    xfce4 \
    xfce4-terminal \
    xfce4-notifyd \
    xfce4-screenshooter \
    thunar \
    mousepad \
    xorg \
    lightdm
ok "XFCE4 installed"

# 4. xrdp
log "Installing xrdp..."
apt-get install "${APT_OPTS[@]}" xrdp
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

echo "startxfce4" > /home/${VAGRANT_USER}/.xsession
chmod +x /home/${VAGRANT_USER}/.xsession
chown ${VAGRANT_USER}:${VAGRANT_USER} /home/${VAGRANT_USER}/.xsession

sed -i "s/max_bpp=32/max_bpp=24/" /etc/xrdp/xrdp.ini 2>/dev/null || true
systemctl enable xrdp
systemctl restart xrdp
ok "xrdp configured"

# 5. Vagrant user password (for RDP login)
log "Setting vagrant password..."
echo "${VAGRANT_USER}:vagrant" | chpasswd
ok "Password set: vagrant / vagrant"

# 6. Python 3.13
log "Installing Python 3.13..."
add-apt-repository -y ppa:deadsnakes/ppa
apt-get update -qq
apt-get install "${APT_OPTS[@]}" python3.13 python3.13-venv python3.13-dev || \
    apt-get install "${APT_OPTS[@]}" python3.13 python3.13-venv
# Do NOT touch /usr/bin/python3 — apt_pkg is compiled for system python3.10
# Only set /usr/bin/python (does not exist by default in Ubuntu)
update-alternatives --install /usr/bin/python python /usr/bin/python3.13 1 || true
# Ensure system python3.10 remains default for apt
update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.10 10 || true
curl -sS https://bootstrap.pypa.io/get-pip.py -o /tmp/get-pip.py
python3.13 /tmp/get-pip.py --quiet
python3.13 -m pip install --upgrade pip --quiet
ok "Python 3.13 + pip ready"

# 7. Python packages (DAeCS stack)
log "Installing Python packages..."
# Fix: blinker 1.4 is a system distutils package pip can't uninstall;
# install newer version directly so Flask 3.x dependency is satisfied
python3.13 -m pip install --quiet --ignore-installed "blinker>=1.6" || true

python3.13 -m pip install --quiet --root-user-action=ignore \
    "textual>=0.80.0" "psutil>=5.9.0" \
    "fastapi>=0.109.0" "uvicorn[standard]>=0.27.0" \
    "sqlalchemy>=2.0.25" "pydantic>=2.5.3" "pydantic-settings>=2.1.0" \
    "jinja2>=3.1.3" "python-multipart>=0.0.6" "sse-starlette>=1.8.2" \
    "python-dotenv>=1.0.0" "requests>=2.31.0" "httpx>=0.26.0" \
    "aiofiles>=23.2.1" "python-dateutil>=2.8.2" \
    "PyMuPDF>=1.23.0" "Pillow>=10.0.0" \
    "flask>=3.0" "flask-sqlalchemy>=3.1" "openpyxl>=3.1" \
    "groq>=0.4" "piexif>=1.1.3" "numpy>=1.24" \
    pytest httpx
ok "Python packages installed"

# 8. Windsurf IDE
log "Installing Windsurf IDE..."
WINDSURF_INSTALLED=false

if curl -fsSL https://windsurf-stable.codeiumdata.com/wVxQEIWkwPUEAGf3/windsurf.gpg \
        | gpg --dearmor -o /usr/share/keyrings/windsurf-archive-keyring.gpg 2>/dev/null; then
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/windsurf-archive-keyring.gpg] https://windsurf-stable.codeiumdata.com/wVxQEIWkwPUEAGf3/apt stable main" \
        > /etc/apt/sources.list.d/windsurf.list
    apt-get update -qq 2>/dev/null
    if apt-get install -y -qq windsurf 2>/dev/null; then
        WINDSURF_INSTALLED=true
        ok "Windsurf installed via apt repo"
    fi
fi

if [ "$WINDSURF_INSTALLED" = false ]; then
    warn "apt repo failed, trying direct download..."
    WINDSURF_DEB_URL="https://windsurf-stable.codeiumdata.com/linux/deb/amd64/stable/windsurf-latest.deb"
    if wget -q --spider "$WINDSURF_DEB_URL" 2>/dev/null; then
        wget -q "$WINDSURF_DEB_URL" -O /tmp/windsurf.deb
        apt-get install -y -qq /tmp/windsurf.deb 2>/dev/null || dpkg -i /tmp/windsurf.deb && apt-get install -f -y -qq
        rm -f /tmp/windsurf.deb
        WINDSURF_INSTALLED=true
        ok "Windsurf installed via direct download"
    else
        warn "Could not auto-install Windsurf. Install manually after boot."
    fi
fi

# 9. XFCE autostart for Windsurf
log "Configuring Windsurf autostart..."
AUTOSTART_DIR="/home/${VAGRANT_USER}/.config/autostart"
mkdir -p "$AUTOSTART_DIR"
cat > "${AUTOSTART_DIR}/windsurf.desktop" << 'ENDDESKTOP'
[Desktop Entry]
Type=Application
Name=Windsurf IDE
Exec=windsurf /project
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
ENDDESKTOP
chown -R ${VAGRANT_USER}:${VAGRANT_USER} "/home/${VAGRANT_USER}/.config"
ok "Windsurf autostart configured"

# 10. Locale & timezone
log "Setting locale and timezone..."
ln -sf /usr/share/zoneinfo/Asia/Ho_Chi_Minh /etc/localtime
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8

# 11. Git config
runuser -l ${VAGRANT_USER} -c "git config --global core.autocrlf input" || true
runuser -l ${VAGRANT_USER} -c "git config --global core.eol lf" || true

echo ""
echo "============================================"
echo "  VM provision complete!"
echo "============================================"
echo "  RDP:      mstsc -> localhost:<port>"
echo "  Login:    vagrant / vagrant"
echo "  Project:  /project"
if [ "$WINDSURF_INSTALLED" = true ]; then
    echo "  Windsurf: auto-launches on RDP login"
else
    echo "  Windsurf: MANUAL INSTALL REQUIRED"
fi
echo ""