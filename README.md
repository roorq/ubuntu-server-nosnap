# 🧹 Ubuntu Server: No Snap, No Telemetry

A bash script for **Ubuntu Server** that removes Snap completely, blocks it from coming back, and turns off and removes Ubuntu's telemetry.

---

## 🚀 Quick start

```bash
# Run straight from GitHub (asks for confirmation)
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/roorq/ubuntu-server-nosnap/main/remove-snap.sh)"

# Same, without confirmation
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/roorq/ubuntu-server-nosnap/main/remove-snap.sh)" _ -y
```

> **Note:** `curl` is required. If you don't have it installed, run:
> ```bash
> sudo apt update && sudo apt install -y curl
> ```

Prefer to read the script before running it? Download it first:

```bash
curl -fsSLO https://raw.githubusercontent.com/roorq/ubuntu-server-nosnap/main/remove-snap.sh
less remove-snap.sh
chmod +x remove-snap.sh
sudo ./remove-snap.sh        # asks for confirmation
sudo ./remove-snap.sh -y     # no confirmation
```

Reboot afterwards: `sudo reboot`

### Options

| Flag | Effect |
|---|---|
| `-y` | Do not ask for confirmation |

---

## 📋 What does it do?

| Step | Action |
|------|--------|
| 1 | Removes every installed snap: apps first, then `core*`/`bare` bases, then `snapd`. Retries up to 5 passes because of dependencies |
| 2 | **Stops if any snap is still installed**, so `/snap` is never deleted halfway |
| 3 | Stops and disables `snapd.socket`, `snapd.service`, `snapd.seeded`, `snapd.apparmor` and unmounts leftover `/snap/*` mounts |
| 4 | `apt-get purge snapd` + `autoremove --purge` |
| 5 | Deletes `/snap`, `/var/snap`, `/var/lib/snapd`, `/var/cache/snapd`, `/usr/lib/snapd` and every user's `~/snap` |
| 6 | Blocks snapd: APT pin `/etc/apt/preferences.d/nosnap.pref` (priority -10) and `apt-mark hold snapd` |
| 7 | Blocks the `chromium-browser*` transitional packages that silently install a snap (`no-snap-transitional.pref`) |
| 8 | Turns off telemetry (see below) |
| 9 | Removes telemetry packages and pins them so they cannot come back (`no-telemetry.pref`) |
| 10 | Prints a summary: whether `snap` still exists, the APT policy for snapd, and any telemetry packages that were kept |

---

## 🔇 Telemetry

**Turned off:**

| Component | How |
|---|---|
| apport, whoopsie (crash reports) | `/etc/default/apport` `enabled=0`, `/etc/default/whoopsie` `report_crashes=false`, services disabled |
| kerneloops | service disabled |
| popularity-contest | `PARTICIPATE="no"` |
| ubuntu-report | sends an explicit opt-out |
| motd-news (`motd.ubuntu.com`) | `ENABLED=0`, timer disabled, `50-motd-news` made non-executable |
| Ubuntu Pro apt news / ESM ads | `pro config set apt_news=false`, `apt-news` and `esm-cache` services disabled |
| pollinate (`entropy.ubuntu.com`) | service disabled |
| NetworkManager connectivity check | `conf.d/99-no-connectivity-check.conf` (only if NetworkManager is installed) |

**Removed:** `popularity-contest`, `ubuntu-report`, `apport`, `apport-symptoms`, `python3-apport`, `whoopsie`, `kerneloops`, `pollinate`.

### 🛡️ Metapackage protection

Before purging each telemetry package, the script runs `apt-get -s purge` (a simulation). If removing the package would also take `ubuntu-server`, `ubuntu-server-minimal`, `ubuntu-minimal`, `ubuntu-standard` or `ubuntu-cloud-minimal` with it, the package **stays installed but disabled**, and the summary lists it.

---

## ⚠️ Notes

- Run it on **Ubuntu Server**. On Ubuntu Desktop, removing snaps also removes the App Center, the snap Firefox and other apps. For the desktop, use [`ubuntu-snap-to-flatpak`](https://github.com/roorq/ubuntu-snap-to-flatpak) and [`ubuntu-privacy`](https://github.com/roorq/ubuntu-privacy).
- Data stored inside snaps (`/var/snap`, `~/snap`) is **deleted permanently**. Back it up first.
- The script has been syntax-checked, but not yet run on a real Ubuntu Server.

---

## ↩️ Reverting

```bash
sudo rm /etc/apt/preferences.d/{nosnap,no-snap-transitional,no-telemetry}.pref
sudo apt-mark unhold snapd
sudo apt update && sudo apt install snapd
```

This brings back `snapd` only. Removed snaps and their data are not restored. Telemetry settings in `/etc/default/*` stay off until you change them by hand.
