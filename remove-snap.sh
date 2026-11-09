#!/usr/bin/env bash
# Removes snapd from Ubuntu Server and blocks it from being reinstalled,
# and also disables and removes Ubuntu telemetry.
# Usage: sudo ./remove-snap.sh [-y]
#   -y  do not ask for confirmation

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (use sudo)." >&2
    exit 1
fi

if [[ "${1:-}" != "-y" ]]; then
    echo "This script will remove ALL snap packages and snapd, and block snapd from being reinstalled."
    echo "It will also disable and remove telemetry (apport, whoopsie, popularity-contest, motd-news, etc.)."
    read -r -p "Continue? [y/N] " ans
    [[ "$ans" =~ ^[yY]$ ]] || { echo "Aborted."; exit 0; }
fi

log() { echo -e "\n==> $*"; }

if command -v snap >/dev/null 2>&1; then
    log "Removing installed snaps"
    # Remove in a loop: base snaps (core*, snapd, bare) can only be removed
    # once nothing depends on them any more.
    for attempt in 1 2 3 4 5; do
        mapfile -t snaps < <(snap list 2>/dev/null | awk 'NR>1 {print $1}')
        [[ ${#snaps[@]} -eq 0 ]] && break
        echo "Pass $attempt: ${snaps[*]}"
        # regular apps first, then bases, snapd last
        for s in "${snaps[@]}"; do
            case "$s" in core|core[0-9]*|snapd|bare) continue ;; esac
            snap remove --purge "$s" || true
        done
        for s in "${snaps[@]}"; do
            case "$s" in core[0-9]*|bare) snap remove --purge "$s" || true ;; esac
        done
        for s in "${snaps[@]}"; do
            case "$s" in core|snapd) snap remove --purge "$s" || true ;; esac
        done
    done
    # If anything is left, do not remove snapd blindly (rm -rf /snap could fail
    # on mounted snaps and leave the data half-deleted).
    left=$(snap list 2>/dev/null | awk 'NR>1 {print $1}' | tr '\n' ' ')
    if [[ -n "$left" ]]; then
        echo "ERROR: failed to remove snaps: $left" >&2
        echo "Remove them manually (snap remove --purge <name>) and run the script again." >&2
        exit 1
    fi
else
    log "snap command not found - skipping snap removal"
fi

log "Stopping snapd services"
for unit in snapd.socket snapd.service snapd.seeded.service snapd.apparmor.service; do
    systemctl stop "$unit" 2>/dev/null || true
    systemctl disable "$unit" 2>/dev/null || true
done

log "Unmounting leftover snap mounts"
awk '$2 ~ /^\/snap\// {print $2}' /proc/mounts | sort -r | while read -r m; do
    umount -l "$m" 2>/dev/null || true
done

log "Removing the snapd package (apt purge)"
if dpkg -l snapd 2>/dev/null | grep -q '^ii\|^rc'; then
    DEBIAN_FRONTEND=noninteractive apt-get purge -y snapd
fi
apt-get autoremove --purge -y

log "Removing snap directories"
rm -rf /snap /var/snap /var/lib/snapd /var/cache/snapd /usr/lib/snapd
for home in /root /home/*; do
    [[ -d "$home/snap" ]] && rm -rf "$home/snap"
done

log "Blocking snapd reinstallation (APT pinning)"
cat > /etc/apt/preferences.d/nosnap.pref <<'EOF'
# Block snapd - never install it, not even as a dependency
Package: snapd
Pin: release a=*
Pin-Priority: -10
EOF

apt-mark hold snapd 2>/dev/null || true

log "Preventing deb packages from being replaced by snaps (e.g. firefox, chromium)"
cat > /etc/apt/preferences.d/no-snap-transitional.pref <<'EOF'
# Transitional packages that install a snap instead of a deb on Ubuntu
Package: chromium-browser chromium-browser-l10n chromium-codecs-ffmpeg chromium-codecs-ffmpeg-extra
Pin: release o=Ubuntu*
Pin-Priority: -1
EOF

############################################################################
# TELEMETRY
############################################################################
log "Disabling telemetry"

# ubuntu-report: send a one-time opt-out (if the tool exists)
command -v ubuntu-report >/dev/null 2>&1 && ubuntu-report -f send no 2>/dev/null || true

# popularity-contest
[[ -f /etc/popularity-contest.conf ]] && \
    sed -i 's/^PARTICIPATE=.*/PARTICIPATE="no"/' /etc/popularity-contest.conf

# apport / whoopsie (crash reports)
[[ -f /etc/default/apport ]] && sed -i 's/^enabled=.*/enabled=0/' /etc/default/apport
[[ -f /etc/default/whoopsie ]] && sed -i 's/^report_crashes=.*/report_crashes=false/' /etc/default/whoopsie
for unit in apport.service apport-autoreport.path apport-autoreport.timer \
            apport-forward.socket whoopsie.service whoopsie.path \
            kerneloops.service pollinate.service; do
    systemctl disable --now "$unit" 2>/dev/null || true
done

# motd-news (fetches news from motd.ubuntu.com, sending system details)
[[ -f /etc/default/motd-news ]] && sed -i 's/^ENABLED=.*/ENABLED=0/' /etc/default/motd-news
systemctl disable --now motd-news.timer 2>/dev/null || true
[[ -f /etc/update-motd.d/50-motd-news ]] && chmod -x /etc/update-motd.d/50-motd-news

# Ubuntu Pro: apt news and ESM ads
if command -v pro >/dev/null 2>&1; then
    pro config set apt_news=false 2>/dev/null || true
fi
systemctl disable --now apt-news.service esm-cache.service 2>/dev/null || true

# NetworkManager connectivity check (connectivity-check.ubuntu.com)
if [[ -d /etc/NetworkManager ]]; then
    mkdir -p /etc/NetworkManager/conf.d
    printf '[connectivity]\nenabled=false\n' > /etc/NetworkManager/conf.d/99-no-connectivity-check.conf
    systemctl is-active --quiet NetworkManager && systemctl reload NetworkManager || true
fi

log "Removing telemetry packages"
TELEMETRY_PKGS=(popularity-contest ubuntu-report apport apport-symptoms
                python3-apport whoopsie kerneloops pollinate)
# Metapackages that must never be removed as a side effect
PROTECTED_RE='^(ubuntu-server|ubuntu-server-minimal|ubuntu-minimal|ubuntu-standard|ubuntu-cloud-minimal)$'

removed=()
for pkg in "${TELEMETRY_PKGS[@]}"; do
    dpkg -s "$pkg" >/dev/null 2>&1 || continue
    # Simulate: would removing this package take a system metapackage with it?
    victims=$(apt-get -s purge "$pkg" 2>/dev/null | awk '/^Purg /{print $2}')
    if grep -Eq "$PROTECTED_RE" <<<"$victims"; then
        echo "SKIPPING $pkg - removing it would also remove: $(grep -E "$PROTECTED_RE" <<<"$victims" | tr '\n' ' ')"
        echo "        (package is kept, but disabled above)"
        continue
    fi
    DEBIAN_FRONTEND=noninteractive apt-get purge -y "$pkg" && removed+=("$pkg")
done

if [[ ${#removed[@]} -gt 0 ]]; then
    log "Blocking reinstallation of: ${removed[*]}"
    {
        echo "# Blocked telemetry packages (removed by remove-snap.sh)"
        echo "Package: ${removed[*]}"
        echo "Pin: release a=*"
        echo "Pin-Priority: -10"
    } > /etc/apt/preferences.d/no-telemetry.pref
fi

log "Updating APT indexes"
apt-get update -qq || true

log "Verification"
if command -v snap >/dev/null 2>&1; then
    echo "WARNING: snap command still exists: $(command -v snap)"
else
    echo "snap: removed"
fi
echo "APT policy for snapd:"
apt-cache policy snapd | sed 's/^/    /'
echo "Telemetry packages still installed:"
for pkg in "${TELEMETRY_PKGS[@]}"; do
    dpkg -s "$pkg" >/dev/null 2>&1 && echo "    $pkg (disabled)"
done
true

echo -e "\nDone. A reboot is recommended: sudo reboot"
