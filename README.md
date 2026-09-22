# Relay
**IT LET'S YOU UPLOAD CODE WITHOUT BEING CONNECTED TO ROBOT WIFI AND AVOID ADB HASSLES**


Relay lets more than one person on a FTC team use Android Studio with one REV Control Hub at
the same time while connected to your home WiFi.  Each laptop sees the Control Hub as an Android device and can
deploy normally—without plugging in USB or joining the robot's Wi-Fi directly.

## How Relay works

One small Linux computer, usually a Raspberry Pi, sits next to the robot. It
joins the Control Hub's Wi-Fi and keeps one shared ADB connection open. Each
laptop makes a secure SSH connection to that computer.

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

### Step 2: Set up each laptop once

On macOS or Linux, open Terminal. On Windows, open **Git Bash** (not
PowerShell or Command Prompt), then run:

```bash
git clone https://github.com/Bob-41/Relay.git
cd Relay/laptop
bash install.sh
```

Enter the bridge host/IP and Linux username from Step 1. Choose **SSH key**
authentication when prompted. You enter the bridge password once so Relay can
add the key; after that, the tunnel reconnects automatically and can receive
safe nightly updates.

Restart Android Studio when the installer finishes. The Control Hub should
appear in the device selector. If it does not, first confirm that the laptop
and bridge are both connected to Tailscale (or to the same LAN if using the
local-IP option).

### Optional: open the robot web tools from a laptop

After the laptop tunnel is running, open:

| Tool | Address |
| --- | --- |
| Control Hub Program & Manage | `http://localhost:8091` |
| FTC Dashboard | `http://localhost:8091/dash` |
| Panels | `http://localhost:8001` |

Program & Manage and FTC Dashboard are the same web server on the hub
(port 8080), so they share one forwarded address - if you're using FTC
Dashboard, that's the URL to open.

## Updates

Relay checks for updates overnight, around 3 AM. An update is applied only
when the repository's `VERSION` is deliberately increased. Downloaded shell
scripts are syntax-checked before Relay uses them; if a check fails, the
current working installation remains in place.

Automatic laptop updates require SSH-key authentication. If you chose password
authentication, re-run `laptop/install.sh` to update that laptop.

## Troubleshooting

- **The bridge cannot find the Control Hub Wi-Fi:** confirm that its chosen
  Wi-Fi adapter supports the Control Hub's band. A 5 GHz Control Hub requires
  a 5 GHz-capable adapter.
- **Android Studio does not show the Control Hub:** restart Android Studio,
  then verify the bridge is reachable and the laptop installer completed.
- **A tunnel will not start because port 5037 is in use:** close Android Studio
  and re-run the laptop installer. Relay recognizes and clears a local ADB
  server on that port; it does not automatically kill unknown programs.
- **Panels loads only a blank page:** make sure you are using the current
  laptop installer, which forwards both the Panels web page and its live-data
  connection.

## Logs

| Component | Location |
| --- | --- |
| Bridge watchdog | `/var/log/adb-forwarder.log`, `journalctl -u adb-forwarder-connect.service` |
| Bridge ADB server | `journalctl -u adb-forwarder-server.service` |
| macOS tunnel | `/tmp/adbtunnel-<host>.log` |
| Windows tunnel | `%APPDATA%\\adb-tunnel\\adb-tunnel-<host>.log` |

## Current limitations

- Windows persistence and automatic updates still need more real-hardware
  verification.
- Relay does not lock deployments. Multiple laptops can be connected, but teams
  should communicate before deploying at the same time.
- Updates never change saved Wi-Fi credentials or site-specific network
  settings.
- On aarch64 Debian-family bridges (e.g. Raspberry Pi OS), if the distro `adb` is older than
  36.0.0, `bridge/install.sh` installs Google's x86_64 platform-tools under
  `box64` (`/opt/adb-google`, libs in `/opt/box64-libs`, wrapper at
  `/usr/local/bin/adb`) and points `adb-forwarder-server.service` at that
  wrapper. Apt's `/usr/bin/adb` is left alone as a rollback path.
