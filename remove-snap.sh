#!/usr/bin/env bash
# Usuwa snapd z Ubuntu Server i blokuje jego ponowną instalację,
# a także wyłącza i usuwa telemetrię Ubuntu.
# Użycie: sudo ./remove-snap.sh [-y]
#   -y  bez pytania o potwierdzenie

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Uruchom jako root: sudo $0" >&2
    exit 1
fi

if [[ "${1:-}" != "-y" ]]; then
    echo "Ten skrypt usunie WSZYSTKIE pakiety snap, snapd oraz zablokuje jego ponowną instalację."
    echo "Wyłączy też i usunie telemetrię (apport, whoopsie, popularity-contest, motd-news itd.)."
    read -r -p "Kontynuować? [t/N] " ans
    [[ "$ans" =~ ^[tTyY]$ ]] || { echo "Przerwano."; exit 0; }
fi

log() { echo -e "\n==> $*"; }

if command -v snap >/dev/null 2>&1; then
    log "Usuwanie zainstalowanych snapów"
    # Usuwamy w pętli, bo snapy bazowe (core*, snapd, bare) da się usunąć
    # dopiero, gdy nic od nich nie zależy.
    for attempt in 1 2 3 4 5; do
        mapfile -t snaps < <(snap list 2>/dev/null | awk 'NR>1 {print $1}')
        [[ ${#snaps[@]} -eq 0 ]] && break
        echo "Przebieg $attempt: ${snaps[*]}"
        # najpierw zwykłe aplikacje, na końcu bazy i snapd
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
    # Jeśli coś zostało, nie kasujemy snapd na ślepo (rm -rf /snap mógłby się wysypać
    # na zamontowanych snapach, a dane zostałyby w połowie usunięte).
    left=$(snap list 2>/dev/null | awk 'NR>1 {print $1}' | tr '\n' ' ')
    if [[ -n "$left" ]]; then
        echo "BŁĄD: nie udało się usunąć snapów: $left" >&2
        echo "Usuń je ręcznie (snap remove --purge <nazwa>) i uruchom skrypt ponownie." >&2
        exit 1
    fi
else
    log "Polecenie snap nie jest dostępne - pomijam usuwanie snapów"
fi

log "Zatrzymywanie usług snapd"
for unit in snapd.socket snapd.service snapd.seeded.service snapd.apparmor.service; do
    systemctl stop "$unit" 2>/dev/null || true
    systemctl disable "$unit" 2>/dev/null || true
done

log "Odmontowywanie pozostałych montowań snapów"
awk '$2 ~ /^\/snap\// {print $2}' /proc/mounts | sort -r | while read -r m; do
    umount -l "$m" 2>/dev/null || true
done

log "Usuwanie pakietu snapd (apt purge)"
if dpkg -l snapd 2>/dev/null | grep -q '^ii\|^rc'; then
    DEBIAN_FRONTEND=noninteractive apt-get purge -y snapd
fi
apt-get autoremove --purge -y

log "Usuwanie katalogów snapa"
rm -rf /snap /var/snap /var/lib/snapd /var/cache/snapd /usr/lib/snapd
for home in /root /home/*; do
    [[ -d "$home/snap" ]] && rm -rf "$home/snap"
done

log "Blokowanie ponownej instalacji snapd (APT pinning)"
cat > /etc/apt/preferences.d/nosnap.pref <<'EOF'
# Zablokowanie snapd - nie instaluj go nigdy, także jako zależności
Package: snapd
Pin: release a=*
Pin-Priority: -10
EOF

apt-mark hold snapd 2>/dev/null || true

log "Zapobieganie podmianie pakietów deb na snapy (np. firefox, chromium)"
cat > /etc/apt/preferences.d/no-snap-transitional.pref <<'EOF'
# Pakiety przejściowe, które w Ubuntu instalują snapa zamiast deb
Package: chromium-browser chromium-browser-l10n chromium-codecs-ffmpeg chromium-codecs-ffmpeg-extra
Pin: release o=Ubuntu*
Pin-Priority: -1
EOF

############################################################################
# TELEMETRIA
############################################################################
log "Wyłączanie telemetrii"

# ubuntu-report: wyślij jednorazowo odmowę (jeśli narzędzie istnieje)
command -v ubuntu-report >/dev/null 2>&1 && ubuntu-report -f send no 2>/dev/null || true

# popularity-contest
[[ -f /etc/popularity-contest.conf ]] && \
    sed -i 's/^PARTICIPATE=.*/PARTICIPATE="no"/' /etc/popularity-contest.conf

# apport / whoopsie (raporty awarii)
[[ -f /etc/default/apport ]] && sed -i 's/^enabled=.*/enabled=0/' /etc/default/apport
[[ -f /etc/default/whoopsie ]] && sed -i 's/^report_crashes=.*/report_crashes=false/' /etc/default/whoopsie
for unit in apport.service apport-autoreport.path apport-autoreport.timer \
            apport-forward.socket whoopsie.service whoopsie.path \
            kerneloops.service pollinate.service; do
    systemctl disable --now "$unit" 2>/dev/null || true
done

# motd-news (pobiera wiadomości z motd.ubuntu.com, wysyłając dane o systemie)
[[ -f /etc/default/motd-news ]] && sed -i 's/^ENABLED=.*/ENABLED=0/' /etc/default/motd-news
systemctl disable --now motd-news.timer 2>/dev/null || true
[[ -f /etc/update-motd.d/50-motd-news ]] && chmod -x /etc/update-motd.d/50-motd-news

# Ubuntu Pro: wiadomości w apt i reklamy ESM
if command -v pro >/dev/null 2>&1; then
    pro config set apt_news=false 2>/dev/null || true
fi
systemctl disable --now apt-news.service esm-cache.service 2>/dev/null || true

# Sprawdzanie łączności NetworkManagera (connectivity-check.ubuntu.com)
if [[ -d /etc/NetworkManager ]]; then
    mkdir -p /etc/NetworkManager/conf.d
    printf '[connectivity]\nenabled=false\n' > /etc/NetworkManager/conf.d/99-no-connectivity-check.conf
    systemctl is-active --quiet NetworkManager && systemctl reload NetworkManager || true
fi

log "Usuwanie pakietów telemetrycznych"
TELEMETRY_PKGS=(popularity-contest ubuntu-report apport apport-symptoms
                python3-apport whoopsie kerneloops pollinate)
# Metapakiety, których nie wolno pociągnąć przy usuwaniu
PROTECTED_RE='^(ubuntu-server|ubuntu-server-minimal|ubuntu-minimal|ubuntu-standard|ubuntu-cloud-minimal)$'

removed=()
for pkg in "${TELEMETRY_PKGS[@]}"; do
    dpkg -s "$pkg" >/dev/null 2>&1 || continue
    # Symulacja: czy usunięcie tego pakietu zabierze metapakiet systemu?
    victims=$(apt-get -s purge "$pkg" 2>/dev/null | awk '/^Purg /{print $2}')
    if grep -Eq "$PROTECTED_RE" <<<"$victims"; then
        echo "POMIJAM $pkg - jego usunięcie pociągnęłoby: $(grep -E "$PROTECTED_RE" <<<"$victims" | tr '\n' ' ')"
        echo "        (pakiet zostaje, ale jest wyłączony powyżej)"
        continue
    fi
    DEBIAN_FRONTEND=noninteractive apt-get purge -y "$pkg" && removed+=("$pkg")
done

if [[ ${#removed[@]} -gt 0 ]]; then
    log "Blokowanie ponownej instalacji: ${removed[*]}"
    {
        echo "# Zablokowane pakiety telemetryczne (usunięte przez remove-snap.sh)"
        echo "Package: ${removed[*]}"
        echo "Pin: release a=*"
        echo "Pin-Priority: -10"
    } > /etc/apt/preferences.d/no-telemetry.pref
fi

log "Aktualizacja indeksów APT"
apt-get update -qq || true

log "Weryfikacja"
if command -v snap >/dev/null 2>&1; then
    echo "UWAGA: polecenie snap nadal istnieje: $(command -v snap)"
else
    echo "snap: usunięty"
fi
echo "Polityka APT dla snapd:"
apt-cache policy snapd | sed 's/^/    /'
echo "Pakiety telemetryczne nadal zainstalowane:"
for pkg in "${TELEMETRY_PKGS[@]}"; do
    dpkg -s "$pkg" >/dev/null 2>&1 && echo "    $pkg (wyłączony)"
done
true

echo -e "\nGotowe. Zalecany restart systemu: sudo reboot"
