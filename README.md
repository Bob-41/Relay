# Relay

Shared ADB bridge for FTC (FIRST Tech Challenge) workshops. Relay lets any
laptop running Android Studio deploy to a REV Control Hub over WiFi through
one shared bridge machine — no USB, no direct WiFi connection to the robot
per laptop, and multiple laptops can deploy at the same time. If you will 
use Tailscale, then you can upload to your robot from anywhere in the world 
as long as you have internet access and the bridge is near the robot. 
Instructions for Tailscale are down below.

## How it works

One Linux machine (the **bridge**) joins the robot's WiFi AP and runs a
shared `adb` server. Each laptop opens an SSH tunnel into that server, so
Android Studio's normal deploy flow just works, unmodified.

## Install

### 1. Bridge machine (once)

Any Linux box with `systemd` + `NetworkManager` (a Raspberry Pi, a spare
laptop, etc.):

```bash
git clone https://github.com/Bob-41/Relay.git
cd Relay/bridge
sudo bash install.sh
```

It'll ask a few questions:
- how laptops should reach this machine (**Tailscale** recommended, or a
  static LAN IP)
- the robot's WiFi name/password and device IP (defaults are correct for a
  stock REV Control Hub)

At the end it prints the host/user/port to give to laptops — write those
down.

### 2. Each laptop (once per laptop)

IMPORTANT: WINDOWS IS IN ALPHA SO DON'T EXPECT IT TO WORK CURRENTLY

Mac or Linux — Terminal. Windows — **Git Bash** (not PowerShell/cmd):

```bash
git clone https://github.com/Bob-41/Relay.git
cd Relay/laptop
bash install.sh
```

Enter the host/user/port from step 1. Pick **SSH key** auth when asked
(needed for auto-update, and you only enter the bridge's password once).

Restart Android Studio — the Control Hub should show up in the device
dropdown like it's plugged in by USB.

## Auto-update

Both installers register a nightly check (~03:00) that pulls fixes from
this repo automatically:

- Only applies if `VERSION` in this repo has increased — a push doesn't
  roll out until that file is deliberately bumped.
- Every downloaded script is syntax-checked before it's ever run. A bad
  download or commit fails closed: the current install keeps running,
  the failure is logged, and it retries the next night.
- Only the watchdog/tunnel is restarted — never the shared adb server —
  so an update doesn't interrupt an unrelated live connection.
- **Laptop auto-update only applies to SSH-key tunnels.** Password-auth
  tunnels aren't auto-updated; re-run `laptop/install.sh` manually on
  those.



## Tailscale

## Logs

| Component | Location |
|---|---|
| Bridge watchdog | `/var/log/adb-forwarder.log`, `journalctl -u adb-forwarder-connect.service` |
| Bridge adb server | `journalctl -u adb-forwarder-server.service` |
| Mac tunnel | `/tmp/adbtunnel-<host>.log` |
| Windows tunnel | `%APPDATA%\adb-tunnel\adb-tunnel-<host>.log` |

## Known limitations

- Windows persistence/auto-update is unverified on real hardware.
- No concurrent-deploy locking — two laptops deploying at once is visible
  and non-destructive; verbal coordination is the accepted mitigation.
- Auto-update never touches WiFi credentials or site-specific network
  config — only the generic watchdog/tunnel logic.
