# Development

This document covers building prtvpn and how it works inside. For what the app does and how to install it, see the [README](../README.md).

The fork is based on the `develop` branch of [ProtonVPN/ios-mac-app](https://github.com/ProtonVPN/ios-mac-app) at commit `6973fc1f7`, macOS app version 6.5. Only the macOS app is maintained here. The iOS and tvOS apps are still in the tree because they share libraries with it.

## Repository layout

| Path                    | Contents                                                                                                                           |
| ----------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| `ProtonVPN.xcworkspace` | Workspace containing all apps, libraries and sample apps. Always open this, not the individual projects.                           |
| `apps/macos`            | macOS app (`macOS.xcodeproj`), the tunnel daemon (`prtvpn-daemon`), the login-item starter and upstream's unused system extensions |
| `scripts`               | `build-release.sh`, the build, sign and package script of this fork                                                                |
| `apps/ios`, `apps/tvos` | Upstream iOS and tvOS apps (unmaintained in this fork)                                                                             |
| `libraries`             | Local Swift packages, see [Package structure](#package-structure)                                                                  |
| `external`              | Git submodules, see [Submodules](#submodules)                                                                                      |
| `sampleapps`            | Small host apps for developing individual feature packages                                                                         |
| `Integration`           | Upstream build, release and CI scripts and templates                                                                               |

## Requirements

- macOS with a recent Xcode. Upstream CI builds with Xcode 26.2 on macOS 15.6. This fork is built with Xcode 27 (Swift 6.4), which required pinning `swift-composable-architecture` to 1.26.0 and `swift-sharing` to 2.9.1 in the workspace `Package.resolved`; the versions upstream pins do not build with Swift 6.4.
- Deployment targets: macOS 14.0, iOS 17.0, tvOS 17.0.
- [Homebrew](https://brew.sh), for `go` (required to build the tunnel daemon and WireGuardKitGo), `imagemagick` and `jq`.
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

## How the VPN works

The official app runs WireGuard inside an Apple Network Extension, which requires a paid developer account and entitlements that Apple has to approve. This fork uses a root daemon written in Go instead (`apps/macos/prtvpn-daemon`).

- The app installs it as the LaunchDaemon `app.prtvpn.daemon`. The binary is `/Library/PrivilegedHelperTools/app.prtvpn.daemon` and the launchd plist is `/Library/LaunchDaemons/app.prtvpn.daemon.plist`. The daemon keeps its state in `/var/db/prtvpn` and logs to `/var/log/prtvpn-daemon.log`, which Help > Tunnel Daemon Log shows in Finder.
- The app sends commands over the Unix socket `/var/run/prtvpn-daemon.sock`. Only the user who installed the daemon can open the socket. The daemon also checks the code signature of each connecting process. The process must satisfy the designated requirement of the app that installed the daemon and must run with the hardened runtime.
- The daemon creates a `utun` interface, runs WireGuard on it over UDP, TCP or TLS (Stealth), and sets routes and DNS. Upstream's system extensions are still under `apps/macos`, but the app does not install or use them.

### Firewall

The daemon loads `pf` rules into the anchor `com.apple/prtvpn`. While the firewall blocks traffic, it still allows port 443 to the Proton API hosts, so the app can sign in and refresh the server list. DNS is blocked too, so the daemon writes the addresses of these hosts to a marked block in `/etc/hosts`. It only accepts host names under `proton.me`, `protonvpn.ch` and `protonvpn.com`.

In automatic mode the daemon remembers that the firewall is on in `/var/db/prtvpn/firewall-armed`, together with an id of the current boot, so a reboot turns it off again. The on and lockdown modes survive a reboot.

### App version

The fork has its own version number (`MARKETING_VERSION` in `apps/macos/Version.xcconfig`). Proton's API rejects client versions it considers outdated, so the app reports upstream's version to the API instead (`UPSTREAM_VERSION` in the same file).

## Build details

### Submodules

`.gitmodules` uses relative URLs that point into Proton's internal GitLab. Relative to this fork they resolve to repositories that do not exist, so `git submodule update --init` fails until the URLs are overridden locally.

| Submodule                  | Pinned at                         | Public mirror                                  | Used by                                                                                         |
| -------------------------- | --------------------------------- | ---------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| `external/protoncore`      | `40e92cbe` (tag `36.0.3`)         | <https://github.com/ProtonMail/protoncore_ios> | Most local packages                                                                             |
| `external/wireguard-apple` | `5742d286` (branch `release/ios`) | <https://github.com/ProtonVPN/wireguard-apple> | WireGuard extensions (`WireGuardKitGo`)                                                         |
| `external/apple-fusion`    | `5f680d98` (tag `2.1.2`)          | <https://github.com/ProtonMail/apple-fusion>   | `UITestsHelpers` (UI tests only)                                                                |
| `external/swift-cargo`     | `a5c3cf9c`                        | None found                                     | Listed in the workspace only; no package manifest or Xcode project depends on it |

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

| File                                                                           | Constants                                                                      |
| ------------------------------------------------------------------------------ | ------------------------------------------------------------------------------ |
| `libraries/Core/LegacyCommon/Sources/LegacyCommon/ObfuscatedConstants.swift`   | `fidoPortal`                                                                   |
| `libraries/Features/Home/Sources/HomeShared/ObfuscatedConstants.swift`         | `fidoPortal`                                                                   |
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

## Tools

### Linting and formatting

The Xcode targets run [SwiftLint](https://github.com/realm/SwiftLint) with the root `.swiftlint.yml` as a build phase, and skip it when `swiftlint` is not installed. Formatting rules for [SwiftFormat](https://github.com/nicklockwood/SwiftFormat) are in `.swiftformat`.

Install SwiftLint with `brew install swiftlint` if you want the lint build phase to run.

### Localization

Strings live in the `Strings` package (`libraries/Foundations/Strings`). [SwiftGen](https://github.com/SwiftGen/SwiftGen) generates `Sources/Strings/Strings.swift` from the English `Localizable.strings` and `Localizable.stringsdict`. After adding a string to the English files, run `swiftgen` in the directory containing the relevant `swiftgen.yml`, and add the Korean translation to `ko.lproj`. Several other packages (for example `Theme`, `Modals`, `BugReport`) and `apps/macos` have their own `swiftgen.yml` for assets and strings.
