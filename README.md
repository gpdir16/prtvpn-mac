# prtvpn-mac

"Unofficial" Proton VPN client for macOS. It is a fork of Proton AG's open-source [ProtonVPN/ios-mac-app](https://github.com/ProtonVPN/ios-mac-app).

This project is **not** affiliated with, endorsed by, or supported by Proton AG. "Proton" and "Proton VPN" are trademarks of Proton AG. Do not report issues with this fork to Proton.

You need a Proton account. The app talks to Proton's API and uses Proton's servers.

<img width="928" height="720" alt="CleanShot 2026-10-12 at 5 47 40 PM" src="https://github.com/user-attachments/assets/d1e20e68-7638-49cc-9f6b-b3d1e0ffd293" />

## Differences from the official app

- Build a tunnel based on the root daemon. Unlike official apps, it does not use Apple signatures and macOS system extensions with significant functional limitations. This is similar to MullvadVPN.
- A firewall with four modes replaces the kill switch. The kill switch in ProtonVPN's official app didn't work properly in my tests, and it leaked my real IP without any guidance when changing servers. This fork doesn't have that problem because they built the killswitch from scratch in a different way.
- No tracker, telemetry and no crash reports.
- No upsell screens, promotional offers or announcements.
- Built from standard macOS controls. Check out the screenshots below, which are much more beautiful and natural than the official app.
- A setting for virtual servers: use any server, virtual only, physical only, or virtual only when no physical server exists.
- Installs next to the official app. It keeps its own settings and its own encrypted credential store and never touches the official app's session.

There is no auto-update. Install new versions by hand.

## Install

Developed and tested on macOS 27. It may run on macOS 14 or later, but please note that this has not been tested.

1. Unzip `prtvpn-<version>.zip` and move `prtvpn.app` to `/Applications`.
2. The app has no Apple Developer ID signature and is not notarized, so Gatekeeper blocks the first launch. Open it once, then click "Open Anyway" in System Settings > Privacy & Security.
3. On first launch macOS asks for access to the keychain item that holds the app's encryption key. Choose "Always Allow".
4. On the first connection the app asks for an administrator password to install the tunnel daemon. It asks again after an update that includes a newer daemon.

## Firewall

The firewall replaces the kill switch of the official app. Pick the mode with the firewall button in the toolbar of the main window.

| Mode                | Behaviour                                                                                                                                                                                                                                        |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Automatic (default) | Turns on when the VPN connects and turns off only when you disconnect yourself. Traffic outside the tunnel stays blocked if the connection drops, and while the app reconnects after a protocol change, a Secure Core toggle or a server switch. |
| On                  | Allows only traffic through the VPN tunnel, including while disconnected and after a reboot. Disconnecting blocks all internet access.                                                                                                           |
| Lockdown            | Blocks all internet traffic, including the VPN tunnel.                                                                                                                                                                                           |
| Off                 | Blocks nothing.                                                                                                                                                                                                                                  |

While the firewall blocks traffic, the app can still reach the Proton API to sign in and refresh the server list. "Allow LAN connections" in the settings keeps printers, file shares and other devices on your local network reachable.

## Uninstall

Delete `prtvpn.app`. About a minute later the tunnel daemon notices that the app is gone and shows a dialog that offers to remove itself. Choose "Remove". This also turns the firewall off, so internet access comes back.

If the automatic deletion tool doesn't work, you can remove it manually.

To remove everything by hand:

1. Run this command on terminal:

```bash
sudo launchctl bootout system/app.prtvpn.daemon
sudo pfctl -a com.apple/prtvpn -F all
sudo rm -rf /Library/LaunchDaemons/app.prtvpn.daemon.plist /Library/PrivilegedHelperTools/app.prtvpn.daemon /var/db/prtvpn /var/log/prtvpn-daemon.log
```

2. Then delete the lines between `# prtvpn firewall begin` and `# prtvpn firewall end` in `/etc/hosts`, if present. If name resolution still fails, your network service still uses the VPN DNS server. Set DNS back to automatic in System Settings > Network.

## Known limitations

- The app is not notarized and is signed with a self-signed certificate, so macOS cannot tell you who built a copy.
- Without an Apple team identifier the app has to disable library validation. A process that runs as your user and can modify the app bundle can load its own code into the app and send commands to the daemon. Install the app in `/Applications`, and do not run it from a folder that other software can write to.
- Only English and Korean are fully translated. In other languages, the strings this fork added appear in English.
- Most of the code was written by AI. (But I'm not trying to avoid responsibility. I just wanted to let you know.)

## Building from source

See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## Third-party dependencies

See [ACKNOWLEDGEMENTS.md](ACKNOWLEDGEMENTS.md).

## License

The code and data files in this distribution are licensed under the terms of the GPLv3 as published by the Free Software Foundation. See [LICENSE](LICENSE) or <https://www.gnu.org/licenses/> for a copy of this license.

Copyright (c) 2025 Proton Technologies AG

Modifications in this fork are made by their respective authors and are released under the same license.
