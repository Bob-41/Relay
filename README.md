# Relay
**Upload code without joining the robot Wi-Fi, and without ADB hassles.**


Relay lets more than one person on an FTC team use Android Studio with one REV Control Hub at
the same time while connected to your home WiFi.  Each laptop sees the Control Hub as an Android device and can
deploy normally—without plugging in USB or joining the robot's Wi-Fi directly.

## How Relay works

One small Linux computer, usually a Raspberry Pi, sits next to the robot. It
joins the Control Hub's Wi-Fi and keeps one shared ADB connection open. Each
laptop makes a secure SSH connection to that computer and forwards a local port
to the shared server.

```text
Android Studio on each laptop
            │ secure SSH tunnel
            ▼
      Relay bridge (Raspberry Pi)
            │ Control Hub Wi-Fi
            ▼
       REV Control Hub
```

This means several laptops can build and deploy to the same robot. Coordinate
before deploying at the exact same moment, just as you would when sharing any
robot.

The bridge's ADB server listens on the bridge's own `localhost` only. Nothing on
the shop or home network can reach it directly - laptops get to it through the
SSH tunnel, and the tunnel is authenticated.

## What is Tailscale?

[Tailscale](https://tailscale.com/) is a private network for your own devices.
After you sign in to the same Tailscale account on the bridge and on each
laptop, they can reach each other securely from different Wi-Fi networks. It
does not make the bridge public on the internet.

Use Tailscale if you want the simplest setup or need to reach a bridge from
somewhere else. Relay can also use a fixed local-network IP when every laptop
and the bridge are on the same network.

## Before you start

You need:

- A Linux bridge with `systemd`, NetworkManager, and an SSH server. A
  Raspberry Pi is a common choice. Debian-family (`apt`) and Arch-family
  (`pacman`: Arch, CachyOS, EndeavourOS, Manjaro, Arch Linux ARM) distros are
  supported. The installer installs `iw` and `adb` for you if they are missing.
- The Control Hub's Wi-Fi name and password.
- One network connection for the bridge besides the robot Wi-Fi (for example,
  home Wi-Fi or Ethernet). With Tailscale, it needs internet access.
- Android Studio on each laptop.
- For the recommended setup, Tailscale installed and signed in on the bridge
  and every laptop that will use Relay.

The stock Control Hub address is already built into Relay:
`192.168.43.1:5555`. You do not need to look it up.

## Install Relay

### Step 1: Set up the bridge once

On the Linux bridge, run:

```bash
git clone https://github.com/Bob-41/Relay.git
cd Relay/bridge
sudo bash install.sh
```

The installer asks for:

1. The non-root Linux user that should run Relay.
2. How laptops will find the bridge: choose **Tailscale** for the recommended
   setup, or provide a fixed local-network address.
3. The Wi-Fi adapter that should join the Control Hub.
4. The Control Hub Wi-Fi name and password.
5. Optionally, the port the shared ADB server should listen on (default
   `5037`, which almost every installation keeps).

At the end it prints the three values every laptop needs:

```text
On laptops, point setup at:
  host: 100.x.y.z   user: pi   port: 5037
```

Enter those same three values on each laptop.

If you choose Tailscale and it is not installed, the installer can install it
(from the distro package on Arch-family systems) and opens the sign-in step. When setup finishes, save the bridge host/IP and
the Linux username it reports. You will enter both on every laptop.

**Arch-family bridges:** the installer never runs `pacman -Sy` (a partial
upgrade is unsupported on Arch). If a package install fails with a 404 or
"failed retrieving file", run `sudo pacman -Syu` and re-run the installer.
NetworkManager must already be installed and running
(`sudo pacman -S networkmanager && sudo systemctl enable --now NetworkManager`)
and an SSH server must be enabled
(`sudo pacman -S openssh && sudo systemctl enable --now sshd`) - Arch does not
enable either by default. If this machine uses `systemd-networkd`, `netctl` or
`iwd` for networking, switching to NetworkManager changes how it manages
Wi-Fi, so do that deliberately.

**Ubuntu bridges:** Ubuntu Desktop already uses NetworkManager. Ubuntu Server
manages networking with netplan and `systemd-networkd` instead, so
NetworkManager is usually not installed or running, and Relay needs it. Check
first, then install only what's missing:

```bash
systemctl is-active NetworkManager   # active = already installed and running
systemctl is-active ssh              # active = OpenSSH server already installed
```

If the Ubuntu Server install had the "Install OpenSSH server" option checked,
`ssh` will already show `active` and you can skip that package below.

```bash
sudo apt update
sudo apt install network-manager   # add openssh-server too if that check wasn't active
sudo systemctl enable --now NetworkManager
```

Switching a machine over to NetworkManager changes how it manages Wi-Fi, and
the network can drop while it changes over. Do this on a keyboard and monitor
(or another console), not over an SSH session you depend on.

### Step 2: Set up each laptop once

On macOS or Linux, open Terminal. On Windows, open **Git Bash** (not
PowerShell or Command Prompt), then run:

```bash
git clone https://github.com/Bob-41/Relay.git
cd Relay/laptop
bash install.sh
```

Enter the bridge host/IP and Linux username from Step 1, plus the port it
printed (press Enter for `5037`). Choose **SSH key**
authentication when prompted. You enter the bridge password once so Relay can
add the key; after that, the tunnel reconnects automatically and can receive
safe nightly updates.

**Windows: enter the bridge's IP address, not a hostname.** Use the Tailscale
IP (for example `100.x.y.z`) when the installer asks for the bridge host. A
short name such as `raspi` can fail to resolve on Windows, especially at logon
while Tailscale is still starting, and the tunnel then retries forever with
`Could not resolve hostname`. An IP address does not depend on DNS. Tailscale
must also be running and signed in on the Windows laptop for the tunnel to
connect.

Restart Android Studio when the installer finishes. The Control Hub should
appear in the device selector. If it does not, first confirm that the laptop
and bridge are both connected to Tailscale (or to the same LAN if using the
local-IP option). If the installer cannot confirm the tunnel came up it says so
and exits non-zero instead of reporting success - read what it printed.

**Linux laptops:** the installer starts the tunnel and verifies it, but plain
Linux has no built-in way to keep something running at logon, so persistence and
automatic updates are not set up. The installer prints a `systemd --user` unit
it has written for you, along with the two commands that enable it. Re-run
`laptop/install.sh` after `git pull` to pick up updates.

### Optional: open the robot web tools from a laptop

After the laptop tunnel is running, open:

| Tool | Address |
| --- | --- |
| Control Hub Program & Manage | `http://localhost:8091` |
| FTC Dashboard | `http://localhost:8091/dash` |
| Panels | `http://localhost:8001` |
| PedroPathing autotuner | `localhost:10158` |

Program & Manage and FTC Dashboard are the same web server on the hub
(port 8080), so they share one forwarded address - if you're using FTC
Dashboard, that's the URL to open.

## Updates

Relay checks for updates overnight, around 3 AM. An update is applied only
when the repository's `VERSION` is deliberately **increased** - a version that
merely differs, including one that was reverted, is ignored so a mistake on
`main` can never roll every machine backwards. Downloaded shell scripts are
syntax-checked before Relay uses them; if a check fails, the current working
installation remains in place.

On the bridge, an applied update is also checked afterwards: the ADB unit must
be active and its port bound, and if it is not, the previous install is restored
and the version is not recorded - so a bad release retries the next night
instead of breaking the bridge quietly.

Automatic laptop updates require SSH-key authentication. If you chose password
authentication, re-run `laptop/install.sh` to update that laptop.

To check for an update immediately instead of waiting for 3 AM, run:

```bash
bash laptop/check-for-updates.sh
```

It runs exactly the same updater the nightly job runs. It only exists for
key-auth tunnels; a password-auth laptop has no updater installed.

> **Automatic updates execute code from the repository as root on every bridge.**
> Syntax-checking is not a security check. Keep the repository protected: two
> factor authentication on every account that can push, branch protection on
> `main`, no edits from the web UI, and a `VERSION` bump only in its own
> reviewed commit. To take a bridge out of automatic updates without removing
> the timer, write `manual` to `/etc/adb-forwarder/update-policy`; the nightly
> job then only reports that an update exists.

## Troubleshooting

- **The bridge cannot find the Control Hub Wi-Fi:** confirm that its chosen
  Wi-Fi adapter supports the Control Hub's band. A 5 GHz Control Hub requires
  a 5 GHz-capable adapter.
- **Android Studio does not show the Control Hub:** restart Android Studio,
  then verify the bridge is reachable and the laptop installer completed.
- **A tunnel will not start because port 5037 is in use:** close Android Studio
  and re-run the laptop installer. Relay recognizes and clears a local ADB
  server on that port; it does not automatically kill unknown programs.
- **The Control Hub disappears overnight and re-running the installer brings it
  back:** a known bug that the current laptop installer fixes. A sleeping laptop
  can wake with a local ADB server sitting on port 5037, which made the tunnel
  bind only half the address it should have, so Android Studio talked to a local
  server that had never seen the robot. Relay clears that server automatically
  every time the tunnel (re)starts, on every platform. If it happens again,
  check the tunnel log for `adb-tunnel-guard` messages - and capture the
  evidence listed below before re-running anything.
- **Panels loads only a blank page:** make sure you are using the current
  laptop installer, which forwards both the Panels web page and its live-data
  WebSocket on port 8002. This is the expected fix; it has not yet been
  confirmed in a browser against a live Control Hub, so if the dashboard is
  still blank, treat it as an open bug rather than a solved one.

### Capturing evidence before re-running the installer

Re-running the installer clears the tunnel and its processes, which destroys
most of the evidence for why it failed. On macOS, run this first and keep the
output:

```bash
bash laptop/diagnose.sh
```

It is read-only: it reports who owns port 5037, whether the tunnel agent is
registered and running through its guard, what `adb devices` shows, the
installed version, and the tail of the tunnel and updater logs.

## Logs

| Component | Location |
| --- | --- |
| Bridge watchdog | `/var/log/adb-forwarder.log`, `journalctl -u adb-forwarder-connect.service` |
| Bridge ADB server | `journalctl -u adb-forwarder-server.service` |
| macOS tunnel | `/tmp/adbtunnel-<host>.log`, `/tmp/adbtunnel-<host>.err` |
| macOS updater | `/tmp/adbtunnel-updater.log` |
| Windows tunnel | `%APPDATA%\\adb-tunnel\\adb-tunnel-<host>.log` |
| Windows updater | `%APPDATA%\\adb-tunnel\\updater.log` |

Logs are capped so they cannot fill the disk. On the bridge this depends on
`logrotate` being installed - the installer writes a rotation policy when it is
there and says so when it is not, but a bridge without `logrotate` has no size
cap on `/var/log/adb-forwarder.log`. Laptop logs are trimmed to their newest
2.5 MB whenever they pass 5 MB - on macOS at install and each time the agent
restarts, on Windows on every reconnect attempt.

While it is working, the bridge watchdog logs every state change, every failed
join, and a "Healthy" line about once an hour (not every 5 seconds). It says so
explicitly when it cannot make progress. If the Control Hub's Wi-Fi never
appears, it names the likely cause - most often that the chosen Wi-Fi adapter is
not managed by NetworkManager, which happens when a netplan config claims other
interfaces but never mentions that one. Fix that from a local console with a
netplan drop-in, not over SSH on that interface, or the connection will drop.
The bridge installer now refuses to configure an unmanaged adapter in the first
place, unless you tell it to continue.

The robot Wi-Fi profile is set to never provide a default route, so the Control
Hub's DHCP gateway cannot become the bridge's route to the internet and take
Tailscale and your SSH session down with it. Check with `ip route`.

## Current limitations

Read this before you rely on Relay in a workshop.

- **The tunnel takes over local port 5037 on each laptop.** That is the port
  Android Studio and every `adb` client use, so while Relay's tunnel is up, a
  USB-connected phone and any running emulator disappear from Android Studio -
  they are on a different adb server. To use a USB device, stop the Relay tunnel
  first (macOS: `launchctl unload ~/Library/LaunchAgents/com.adbtunnel.<host>.plist`).
- **There is one shared adb server, so `adb kill-server` is a team-wide event.**
  Running it on any laptop - including Android Studio's "Restart adb", and
  including a `adb` command typed over SSH on the bridge - stops the server every
  other laptop is using. It comes back on its own, but the bridge also needs
  about ten seconds to reconnect to the robot. Coordinate before doing it.
- **Automatic updates run unreviewed code from the repository, as root, on
  every registered bridge.** See the warning in [Updates](#updates).
- **Windows persistence and automatic updates still need more real-hardware
  verification.**
- **Plain Linux laptops get a verified tunnel but no persistence and no
  automatic updates** unless you enable the `systemd --user` unit the installer
  prints.
- **A laptop's `adb` client version must be able to talk to the bridge's adb
  server.** Android Studio bundles its own `adb`; if a laptop reports a version
  mismatch after an update, update that laptop's SDK platform-tools.
- Relay does not lock deployments. Multiple laptops can be connected, but teams
  should communicate before deploying at the same time.
- Updates never change saved Wi-Fi credentials or site-specific network
  settings.
- On aarch64 Debian-family bridges (e.g. Raspberry Pi OS), if the distro `adb` is older than
  36.0.0, `bridge/install.sh` installs Google's x86_64 platform-tools under
  `box64` (`/opt/adb-google`, libs in `/opt/box64-libs`, wrapper at
  `/usr/local/bin/adb`) and points `adb-forwarder-server.service` at that
  wrapper. Apt's `/usr/bin/adb` is left alone as a rollback path. The temporary
  `amd64` package architecture this needs is removed again before the installer
  finishes.
