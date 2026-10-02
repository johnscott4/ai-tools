#!/bin/bash
# Turn a headless Raspberry Pi OS (Trixie, Lite or desktop) into a box you can
# Remote-Desktop into from Windows (mstsc) as the current user.
#
#   tr -d '\r' < setup_rdp.sh | ssh user@host 'cat > setup_rdp.sh && bash setup_rdp.sh'
#
# Verified 2026-10-02 on a Pi 5 (Trixie Lite 2026-09-15) and matches the setup
# that has run on a Pi 4 (logger.local) since 2026-08-30. ~5 min on a Pi 5.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
log() { echo "[$(date +%H:%M:%S)] $*"; }

log "apt update"
sudo apt-get update -qq

# The Raspberry Pi desktop, X11 flavour. xrdp needs an X11 session: the default
# Trixie desktop is Wayland (labwc), which xrdp cannot drive.
log "desktop + xrdp (several hundred packages on Lite)"
# NOT --no-install-recommends: the desktop is configured for the PiXtrix theme,
# but pixtrix-icons/pixtrix-theme/gtk2-engines-pixflat/xsettingsd are only
# Recommends. Without them Openbox logs "Unable to load the theme 'PiXtrix'",
# falls back to Clearlooks, and every panel/desktop icon renders wrong
# (hit on the Pi 5, 2026-10-02). They are also named explicitly so a future
# change of Recommends cannot silently drop them again.
sudo apt-get install -y -q \
  rpd-x-core rpd-x-extras rpd-theme rpd-preferences rpd-wallpaper-trixie rpd-common \
  pixtrix-icons pixtrix-theme gtk2-engines-pixflat gtk2-engines-pixbuf xsettingsd \
  adwaita-icon-theme-legacy gnome-themes-extra-data \
  fonts-dejavu-extra fonts-liberation2 xfonts-base xfonts-scalable xfonts-75dpi xfonts-100dpi \
  lxsession lxsession-logout xrdp xorgxrdp >/tmp/apt-rdp.log 2>&1 \
  || { tail -30 /tmp/apt-rdp.log; exit 1; }
# Never add 'pcmanfm' to this list: it conflicts with pcmanfm-pi (rpd-x-core).

# The session xrdp starts for this user: force X11 and launch the Pi desktop.
log "~/.xsession -> startx-rpd (X11)"
cat > "$HOME/.xsession" <<'EOF'
#!/bin/sh
export XDG_SESSION_TYPE=x11
export GDK_BACKEND=x11
exec /usr/bin/startx-rpd
EOF
chmod 775 "$HOME/.xsession"

# xrdp reads the TLS key in /etc/ssl/private.
sudo adduser xrdp ssl-cert >/dev/null 2>&1 || true

# Without this the panel updater pops "Authentication is required to refresh
# the system repositories" on every RDP login. Scoped to PackageKit, sudo group.
log "polkit: PackageKit for the sudo group"
sudo tee /etc/polkit-1/rules.d/49-packagekit-sudo.rules >/dev/null <<'EOF'
// Remote (xrdp) desktops otherwise pop an "Authentication is required to
// refresh the system repositories" dialog from the panel updater at login.
polkit.addRule(function(action, subject) {
    if (action.id.indexOf("org.freedesktop.packagekit.") === 0 &&
        subject.isInGroup("sudo")) {
        return polkit.Result.YES;
    }
});
EOF
sudo systemctl restart polkit

sudo systemctl enable --now xrdp xrdp-sesman
log "status"
systemctl is-active xrdp xrdp-sesman
sudo ss -ltnp | grep ':3389' || { echo "xrdp is NOT listening on 3389"; exit 1; }
for p in pixtrix-icons pixtrix-theme xsettingsd; do
  dpkg -s "$p" >/dev/null 2>&1 || { echo "MISSING $p - icons will render wrong"; exit 1; }
done
log "DONE - connect with: mstsc /v:$(hostname).local  (user $USER)"
