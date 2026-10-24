# Relay + 

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
git clone https://github.com/6165-MSET-Cuttlefish/Relay.git
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
git clone https://github.com/6165-MSET-Cuttlefish/Relay.git
cd Relay/laptop
bash install.sh
```

Enter the bridge host/IP and Linux username from Step 1. Choose **SSH key**
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

FTC Dashboard's live data (op modes, telemetry, configuration) uses a second
connection on port 8000, which Relay also forwards. Keep local port 8000 free:
if another program is using it, the whole tunnel fails to start.

## Change the robot Wi-Fi

If you switch Control Hubs or change the hub's Wi-Fi name or password, you do
not need to re-run the full installer. On the bridge, run:

```bash
cd Relay/bridge
sudo bash change-robot-wifi.sh
```

It asks only for the new Wi-Fi name and password. Press Enter at the name
prompt to keep the current name and change only the password. Everything else
stays as it was, and laptops need no changes. The old Wi-Fi profile is kept
with auto-connect turned off, so you can switch back by running the script
again.

Every hub the bridge has a Wi-Fi profile for is a fallback. If the configured
hub is off, the bridge joins another known hub that is in range, and laptops
keep working because every Control Hub uses the same address. The log says
which hub it is on (`Now on configured hub ...` or `Now on fallback hub ...`).
The bridge stays on a fallback hub until that hub goes off, so it never cuts
off a robot that is in use. To stop using a hub as a fallback, delete its
profile with `sudo nmcli connection delete "<hub name>"`.

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
- **The Control Hub disappears overnight and re-running the installer brings it
  back:** this was a known bug and the current laptop installer fixes it. A
  sleeping laptop can wake with a local ADB server sitting on port 5037, which
  made the tunnel bind only half the address it should have, so Android Studio
  talked to a local server that had never seen the robot. Relay now clears an
  idle local server like that whenever the tunnel (re)starts and can reach the
  bridge. If it still happens, check the tunnel log for `adb-tunnel-guard`
  messages.
- **ADB keeps disconnecting on a Mac while the bridge is off, or while the
  laptop is on a Control Hub's own Wi-Fi or USB:** older laptop installs shut
  down every local ADB server each time the tunnel retried, which made adb and
  Android Studio unusable without the bridge. The current macOS installer clears
  a local ADB server only when ssh can log in to the bridge and bind the
  tunnel's ports, and that server had no usable device when Relay checked;
  otherwise it leaves it alone and retries every 15 seconds. A laptop on an
  older install that can't reach the bridge can't update itself, so pause its
  tunnel until it can: find its name with `ls ~/Library/LaunchAgents/com.adbtunnel.*`
  (not the `.updater` one), then run
  `launchctl bootout gui/$(id -u)/<that name without .plist>`. It comes back at
  the next login or the next install. Windows laptops still clear a local ADB
  server on every retry.
- **The tunnel stays down and the log says a local adb server `has been used
  for` a device, `didn't answer`, or `refused to shut down`:** a phone, Control
  Hub or other device was attached through this laptop's own ADB server, so
  Relay won't take the port from it. Unplug or `adb disconnect` that device,
  then run `adb kill-server`; the tunnel starts within about 15 seconds. A phone
  paired for Wireless debugging reconnects to every new ADB server by itself,
  so turn Wireless debugging off on it.
- **Panels loads only a blank page:** make sure you are using the current
  laptop installer, which forwards both the Panels web page and its live-data
  connection.

## Logs

| Component | Location |
| --- | --- |
| Bridge watchdog | `/var/log/adb-forwarder.log`, `journalctl -u adb-forwarder-connect.service` |
| Bridge ADB server | `journalctl -u adb-forwarder-server.service` |
| macOS tunnel | `/tmp/adbtunnel-<host>.log`, `/tmp/adbtunnel-<host>.err` |
| macOS updater | `/tmp/adbtunnel-updater.log` |
| Windows tunnel | `%APPDATA%\\adb-tunnel\\adb-tunnel-<host>.log` |
| Windows updater | `%APPDATA%\\adb-tunnel\\updater.log` |

Logs are capped so they cannot fill the disk. The bridge log rotates weekly at
5 MB, keeping 4 compressed generations. Laptop logs are trimmed to their newest
2.5 MB whenever they pass 5 MB - on macOS at install and each time the agent
restarts, on Windows on every reconnect attempt.

The bridge watchdog logs a line roughly every 5 seconds while it is working and
says so explicitly when it cannot make progress. If the Control Hub's Wi-Fi never
appears, it names the likely cause - most often that the chosen Wi-Fi adapter is
not managed by NetworkManager, which happens when a netplan config claims other
interfaces but never mentions that one. Fix that from a local console with a
netplan drop-in, not over SSH on that interface, or the connection will drop.

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
