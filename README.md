# prtvpn-mac

Unofficial Proton VPN client for macOS, forked from Proton AG's open-source [ProtonVPN/ios-mac-app](https://github.com/ProtonVPN/ios-mac-app) (`develop`, upstream commit `6973fc1f7`, macOS app version 6.5). The fork starts its own version numbering at 1.0.0. It still reports the upstream version to Proton's API, which rejects client versions it considers outdated (`UPSTREAM_VERSION` in `apps/macos/Version.xcconfig`).

This project is **not affiliated with, endorsed by, or supported by Proton AG**. "Proton" and "Proton VPN" are trademarks of Proton AG. Do not report issues with this fork to Proton.

The focus of this fork is the macOS app. The iOS and tvOS apps from upstream are still present in the tree (`apps/ios`, `apps/tvos`) because they share libraries with the macOS app, but they are not maintained here.

## Repository layout

| Path | Contents |
| --- | --- |
| `ProtonVPN.xcworkspace` | Workspace containing all apps, libraries and sample apps. Always open this, not the individual projects. |
| `apps/macos` | macOS app (`macOS.xcodeproj`), the tunnel daemon (`prtvpn-daemon`), the login-item starter and upstream's unused system extensions |
| `scripts` | `build-release.sh`, the build, sign and package script of this fork |
| `apps/ios`, `apps/tvos` | Upstream iOS and tvOS apps (unmaintained in this fork) |
| `libraries` | Local Swift packages, see [Package structure](#package-structure) |
| `external` | Git submodules, see [Submodules](#submodules) |
| `sampleapps` | Small host apps for developing individual feature packages |
| `Integration` | Upstream build, release and CI scripts and templates |

## Requirements

- macOS with a recent Xcode. Upstream CI builds with Xcode 26.2 on macOS 15.6. This fork is built with Xcode 27 (Swift 6.4), which required pinning `swift-composable-architecture` to 1.26.0 and `swift-sharing` to 2.9.1 in the workspace `Package.resolved`; the versions upstream pins do not build with Swift 6.4.
- Deployment targets: macOS 14.0, iOS 17.0, tvOS 17.0.
- [Homebrew](https://brew.sh), for `go` (required to build the tunnel daemon and WireGuardKitGo), `mint`, `imagemagick` and `jq`.
- No Apple Developer account. The app does not use Network Extension or System Extension entitlements. See [How the VPN works](#how-the-vpn-works).

Git LFS is not used by this repository.

## Setup

1. Clone this repository.
2. Fetch the submodules. See [Submodules](#submodules) first: the URLs in `.gitmodules` do not work as-is in this fork.
3. Install the Homebrew dependencies:

   ```bash
   brew bundle
   ```

4. Create the obfuscated constants files, see [Obfuscated constants](#obfuscated-constants).
5. Open `ProtonVPN.xcworkspace` and let Xcode resolve the Swift packages. All third-party dependencies are managed with Swift Package Manager.
6. Build, sign and package the app:

   ```bash
   scripts/build-release.sh
   ```

   The script builds the `ProtonVPN-macOS` scheme without code signing and builds the tunnel daemon (`apps/macos/prtvpn-daemon`) into the app bundle. It signs both with a self-signed certificate, which it creates in `build/signing` on the first run. The output is `build/prtvpn.app` and `build/prtvpn-<version>.zip`. Targets, schemes and modules keep their upstream names, but the built product is `prtvpn.app`.

An app run directly from Xcode cannot connect. The Xcode project does not build the daemon, and the daemon rejects apps that are not signed with the hardened runtime.

`build/signing` contains the private key of the signing certificate. Do not delete or share it. The daemon remembers the certificate of the app that installed it and rejects apps signed with any other certificate until you reinstall the daemon. Anyone who has the key can build an app that an installed daemon trusts.

## Installing a prebuilt copy

1. Unzip `prtvpn-<version>.zip` and move `prtvpn.app` to `/Applications`.
2. The app has no Apple Developer ID signature and is not notarized, so Gatekeeper blocks the first launch. Open it once, then click "Open Anyway" in System Settings > Privacy & Security. You can also remove the quarantine attribute:

   ```bash
   xattr -dr com.apple.quarantine /Applications/prtvpn.app
   ```

3. On first launch macOS asks for access to the keychain item that holds the app's encryption key. Choose "Always Allow".
4. On the first connection the app asks for an administrator password to install the tunnel daemon. It asks again after an update that includes a newer daemon.

Only install a copy from someone you trust. The daemon runs as root and accepts commands from any app signed with the same certificate as the copy you installed.

## How the VPN works

The official app runs WireGuard inside an Apple Network Extension, which requires a paid developer account and entitlements that Apple has to approve. This fork uses a root daemon written in Go instead (`apps/macos/prtvpn-daemon`).

- The app installs it as the LaunchDaemon `app.prtvpn.daemon`. The binary is `/Library/PrivilegedHelperTools/app.prtvpn.daemon` and the launchd plist is `/Library/LaunchDaemons/app.prtvpn.daemon.plist`. The daemon keeps its state in `/var/db/prtvpn` and logs to `/var/log/prtvpn-daemon.log`, which Help > Tunnel Daemon Log shows in Finder.
- The app sends commands over the Unix socket `/var/run/prtvpn-daemon.sock`. Only the user who installed the daemon can open the socket. The daemon also checks the code signature of each connecting process. The process must satisfy the designated requirement of the app that installed the daemon and must run with the hardened runtime.
- The daemon creates a `utun` interface, runs WireGuard on it over UDP, TCP or TLS (Stealth), and sets routes and DNS. Upstream's system extensions are still under `apps/macos`, but the app does not install or use them.

### Firewall

The firewall replaces the kill switch of the official app. The daemon loads `pf` rules into the anchor `com.apple/prtvpn`. You pick the mode with the firewall button in the toolbar of the main window.

| Mode | Behaviour |
| --- | --- |
| Automatic (default) | Turns on when the VPN connects and turns off only when you disconnect yourself. Traffic outside the tunnel stays blocked if the connection drops, and while the app reconnects after a protocol change, a Secure Core toggle or a server switch. |
| On | Allows only traffic through the VPN tunnel, including while disconnected and after a reboot. Disconnecting blocks all internet access. |
| Lockdown | Blocks all internet traffic, including the VPN tunnel. |
| Off | Blocks nothing. |

While the firewall blocks traffic, it still allows port 443 to the Proton API hosts, so the app can sign in and refresh the server list. DNS is blocked too, so the daemon writes the addresses of these hosts to a marked block in `/etc/hosts`. "Allow LAN connections" in the settings also opens the private address ranges.

### Removing the app

Deleting `prtvpn.app` does not remove the daemon, and the firewall keeps blocking the internet if it was on. The daemon checks every 20 seconds whether the app still exists. About a minute after the app disappears, it shows a dialog that offers to remove the daemon. Removing it also clears the firewall rules, the `/etc/hosts` block and the DNS settings. To remove everything by hand:

```bash
sudo launchctl bootout system/app.prtvpn.daemon
sudo pfctl -a com.apple/prtvpn -F all
sudo rm -rf /Library/LaunchDaemons/app.prtvpn.daemon.plist /Library/PrivilegedHelperTools/app.prtvpn.daemon /var/db/prtvpn /var/log/prtvpn-daemon.log
```

Then delete the lines between `# prtvpn firewall begin` and `# prtvpn firewall end` in `/etc/hosts`, if present. If name resolution still fails, your network service still uses the VPN DNS server. Set DNS back to automatic in System Settings > Network.

## Differences from the official app

- The app is named `prtvpn` and uses `app.prtvpn.*` identifiers where upstream uses `ch.protonvpn.mac`, so you can install it next to the official app.
- A root daemon makes the VPN connection instead of a Network Extension, and a firewall with four modes replaces the kill switch. See [How the VPN works](#how-the-vpn-works).
- The app stores credentials in an AES-GCM encrypted file in its Application Support folder. The keychain holds only the encryption key, under the service name `app.prtvpn.mac`, so the fork never reads or overwrites the session of the official app.
- The app sends no telemetry, Sentry crash reports or observability metrics.
- The app shows no upsell screens, promotional offers or announcements. A feature that needs a paid plan shows a short notice.
- The main window, the settings window and the alerts use standard macOS controls. Clicking the menu bar icon opens the main window. Right-clicking it shows a menu with open, connect or disconnect, settings and quit.
- A setting chooses how to treat virtual servers: use any server, virtual only, physical only, or virtual only when no physical server exists.
- Sparkle auto-update is off. `Info.plist` has no `SUFeedURL`, because upstream's feed would replace this fork with the official app. Install new versions by hand.
- The Help menu has no "Report an Issue" item, because that feature sends reports to Proton's support.
- The app still talks to Proton's API and requires a Proton account. Plan names, account and legal texts therefore still say "Proton VPN". The app icon and logo are still upstream's artwork.

## Known limitations

- The app is not notarized and is signed with a self-signed certificate, so macOS cannot tell you who built a copy.
- Without an Apple team identifier the app has to disable library validation. A process that runs as your user and can modify the app bundle can load its own code into the app and send commands to the daemon. Install the app in `/Applications`, and do not run it from a folder that other software can write to.
- Features that need a system extension, such as split tunneling, do not work.
- Only English and Korean are fully translated. In other languages, the strings this fork added appear in English.

## Build details

### Submodules

`.gitmodules` uses relative URLs that point into Proton's internal GitLab. Relative to this fork they resolve to repositories that do not exist, so `git submodule update --init` fails until the URLs are overridden locally.

| Submodule | Pinned at | Public mirror | Used by |
| --- | --- | --- | --- |
| `external/protoncore` | `40e92cbe` (tag `36.0.3`) | <https://github.com/ProtonMail/protoncore_ios> | Most local packages |
| `external/wireguard-apple` | `5742d286` (branch `release/ios`) | <https://github.com/ProtonVPN/wireguard-apple> | WireGuard extensions (`WireGuardKitGo`) |
| `external/apple-fusion` | `5f680d98` (tag `2.1.2`) | <https://github.com/ProtonMail/apple-fusion> | `UITestsHelpers` (UI tests only) |
| `external/swift-cargo` | `a5c3cf9c` | None found | Listed in the workspace and `Mintfile` only; no package manifest or Xcode project depends on it |

To point the submodules at the public mirrors without modifying `.gitmodules`:

```bash
git submodule init
git config submodule.external/protoncore.url https://github.com/ProtonMail/protoncore_ios.git
git config submodule.external/wireguard-apple.url https://github.com/ProtonVPN/wireguard-apple.git
git config submodule.external/apple-fusion.url https://github.com/ProtonMail/apple-fusion.git
git submodule update external/protoncore external/wireguard-apple external/apple-fusion
```

All three public mirrors contain the pinned commits. `external/swift-cargo` stays uninitialized.

If cloning fails with `Couldn't connect to server` while `curl https://github.com` works, try Apple's git (`/usr/bin/git submodule update ...`) instead of a Homebrew-installed one.

### Obfuscated constants

The apps expect a file named `ObfuscatedConstants.swift` containing API hosts, Sentry DSNs and in-app purchase identifiers. These files are git-ignored. Upstream keeps the real ones in a private credentials repository that is synchronized with `Integration/Scripts/credentials.sh`; that repository is not accessible outside Proton, so `credentials.sh` and `Integration/Scripts/bootstrap.sh` are not usable in this fork.

Instead, create the files locally. For the macOS app, copy the example file and fill in the values (they are empty in the example, and the app cannot reach the API without `apiHost`):

```bash
cp apps/macos/ProtonVPN/ObfuscatedConstants.example.swift apps/macos/ProtonVPN/ObfuscatedConstants.swift
```

Three local packages need their own `ObfuscatedConstants.swift` as well, and ship no example. Each file declares `enum ObfuscatedConstants` with the listed `static let` string constants:

| File | Constants |
| --- | --- |
| `libraries/Core/LegacyCommon/Sources/LegacyCommon/ObfuscatedConstants.swift` | `fidoPortal` |
| `libraries/Features/Home/Sources/HomeShared/ObfuscatedConstants.swift` | `fidoPortal` |
| `libraries/Features/Settings/Sources/SettingsShared/ObfuscatedConstants.swift` | `btiAPIHost`, `blackAPIHost` (Proton-internal test environments, can be empty) |

The iOS and tvOS equivalents of the app-level file live at `apps/ios/ProtonVPN/ObfuscatedConstants.example.swift` and `libraries/Features/tvos_app/Sources/tvos_app/Resources/ObfuscatedConstants.example.swift`.

### ProTUN binary

Upstream downloads the `protunFFI` binary framework from Proton's internal Nexus server, which is not reachable from outside. It is only linked on iOS. In this fork `libraries/Core/NEProviders/Package.swift` declares the binary target only when `libraries/Core/NEProviders/Frameworks/protunFFI.xcframework` exists locally, so the macOS app builds without it.

## Schemes

The macOS project (`apps/macos/macOS.xcodeproj`) ships these shared schemes:

- `ProtonVPN-macOS`: the app
- `ProtonVPN-macOS-Staging`: the app, built with the `Debug-Staging` configuration
- `ProtonVPNStarter`: the login-item helper that launches the app at login
- `ProtonVPNmacOSTests`, `ProtonVPNUnitTestsmacOS`, `ProtonVPNmacOSUITests`: test schemes

`ProtonVPN-mac-redesign` and `ProtonVPNmac-redesign-UITests` are leftovers from upstream: they reference a `ProtonVPN-mac-redesign` target that no longer exists in the project. The `REDESIGN` flag in `apps/macos/Config.xcconfig` (default `0`) belonged to the same unfinished upstream prototype and does not build when set to `1`.

## macOS UI

The main window of this fork is a SwiftUI shell (`apps/macos/ProtonVPN/ProtonVPN-redesign/SideBar`) hosted in the existing AppKit app. Its Home tab reuses the iOS home screen: the `Home` package compiles its `Home-iOS` views and the shared `HomeShared` logic for macOS as well. The Countries and Profiles tabs embed the existing AppKit view controllers, and Settings opens the existing settings window.

## Package structure

Local packages under `libraries` are organized by layer in order to avoid module dependency hell:

- **Foundations**: small, single-purpose libraries for building bigger things. These should only ever link each other, if they do so at all.
- **Shared**: slightly larger libraries meant for sharing code between applications or extensions. Portions that get too big or would benefit from being their own module can be broken out into Foundations. These should only ever link Foundations libraries.
- **Features**: self-contained libraries containing a single feature. These should only ever link libraries from the Shared or Foundations categories. They are included and instantiated within application, test, or extension code. `ios_app` and `tvos_app` hold most of the iOS and tvOS application code.
- **Core**: legacy and extension-level code (`LegacyCommon`, `NEHelper`, `NEProviders`, `PlutoniumExtension`, `SharedViews`).
- **WireguardExtensionSupport**: sources compiled directly into the WireGuard extensions.

Adding new code to `LegacyCommon` and `NEHelper` should be avoided if possible. These packages should be gradually chipped away at in order to place their components into packages in the Foundations, Shared and Features layers.

## Development

### Linting and formatting

The Xcode targets run [SwiftLint](https://github.com/realm/SwiftLint) with the root `.swiftlint.yml` as a build phase, and skip it when `swiftlint` is not installed. Formatting rules for [SwiftFormat](https://github.com/nicklockwood/SwiftFormat) are in `.swiftformat`.

Tool versions are pinned in `Mintfile`. Note that `mint bootstrap` fails in this fork, because the `Mintfile` also lists two tools hosted on Proton's internal GitLab (`git-lhc`, `swift-cargo`). Install the public tools individually, for example `mint install realm/SwiftLint@0.53.0`.

`git-hooks/pre-commit` is upstream's pre-commit hook. It formats staged Swift files and regenerates `Version.xcconfig` using `git-lhc`, so it does not work here without changes.

### Localization

Strings live in the `Strings` package (`libraries/Foundations/Strings`). [SwiftGen](https://github.com/SwiftGen/SwiftGen) generates `Sources/Strings/Strings.swift` from the English `Localizable.strings` and `Localizable.stringsdict`. After adding a string to the English files, run `swiftgen` in the directory containing the relevant `swiftgen.yml`, and add the Korean translation to `ko.lproj`. Several other packages (for example `Theme`, `Modals`, `BugReport`) and `apps/macos` have their own `swiftgen.yml` for assets and strings.

## Third-party dependencies

See [ACKNOWLEDGEMENTS.md](ACKNOWLEDGEMENTS.md).

## License

The code and data files in this distribution are licensed under the terms of the GPLv3 as published by the Free Software Foundation. See [LICENSE](LICENSE) or <https://www.gnu.org/licenses/> for a copy of this license.

Copyright (c) 2025 Proton Technologies AG

Modifications in this fork are made by their respective authors and are released under the same license.
