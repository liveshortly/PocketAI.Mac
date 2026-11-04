# PocketAI for Mac

PocketAI for Mac is a SwiftUI macOS app for running AI models locally: model management, chat, projects, voice input, a local OpenAI-compatible server, and a pairing host so a paired iPhone can use this Mac's models over the local network. It also integrates [LiveShortly](https://github.com/liveshortly/liveshortly-server): it can sign in to a LiveShortly server, follow sessions, and run the [`live` CLI](https://github.com/liveshortly/live) daemon so this Mac hosts sessions. Updates for direct (non-App Store) builds use [Sparkle](https://sparkle-project.org).

## How the repos fit together

| Repo | What it is |
|------|------------|
| [PocketAI.Core](https://github.com/liveshortly/PocketAI.Core) | Rust core and shared Swift packages (`PocketKit`, `PocketUI`, `PocketMLX`, `PocketImageGen`, `PocketLiveShortly`). Required. |
| [PocketAI.Mac](https://github.com/liveshortly/PocketAI.Mac) | This repo. |
| [PocketAI.Iphone](https://github.com/liveshortly/PocketAI.Iphone) | The iOS app, which pairs with this Mac. |

`project.yml` references Core as a local package at `../PocketAI.Core`, so Core must be checked out as a sibling folder:

```
getpocketai/
├── PocketAI.Core
├── PocketAI.Mac
└── PocketAI.Iphone   (optional for a Mac build)
```

```sh
mkdir getpocketai && cd getpocketai
git clone https://github.com/liveshortly/PocketAI.Core.git
git clone https://github.com/liveshortly/PocketAI.Mac.git
```

## Requirements

- A Mac with Apple Silicon. The app is arm64 only (`ARCHS: arm64`): it runs MLX models on the Metal GPU, and Core ships only an arm64 macOS slice.
- macOS 14.0 or later to run the app (deployment target in `project.yml`).
- Xcode with a Swift 6 toolchain. <!-- TODO(owner): state the exact Xcode version you build with. -->
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
- Everything PocketAI.Core needs to build its XCFramework (Rust via rustup plus the Apple targets, CMake). See the [Core README](https://github.com/liveshortly/PocketAI.Core#requirements).

## Build and run

1. Build Core's XCFramework (once, and again after Core's Rust code changes):
   ```sh
   cd ../PocketAI.Core && scripts/build-xcframework.sh
   ```
2. Generate the Xcode project. `PocketAI.xcodeproj` is generated from `project.yml` and is not committed; edit `project.yml`, never the project file.
   ```sh
   cd ../PocketAI.Mac && xcodegen generate
   ```
3. Build and run. Either open `PocketAI.xcodeproj` in Xcode and run the `PocketAI` scheme, or:
   ```sh
   xcodebuild -scheme PocketAI -destination 'platform=macOS' build
   ```

### Tests

```sh
xcodebuild test -scheme PocketAI -destination 'platform=macOS'
```

The `PocketAI` scheme includes the unit tests (`Tests/`) and the UI tests (`UITests/`). To run only the unit tests, add `-only-testing:PocketAITests`. `scripts/uitest-run.sh` builds and runs the UI tests with an ad-hoc signed runner; it needs automation/Accessibility permission for the test runner (`sudo DevToolsSecurity -enable` once, or approve the macOS prompt).

The other `scripts/*-selftest.sh` scripts build the app and exercise a single subsystem (audio, speech, network, send, remote generation).

## Signing

`project.yml` sets `CODE_SIGNING_ALLOWED: NO` for the app target, so a local build needs no certificate. If you want a signed development build (for example to keep Keychain items or permissions stable across rebuilds), set your own `DEVELOPMENT_TEAM` and, if needed, a `PRODUCT_BUNDLE_IDENTIFIER` of your own in `project.yml`, turn `CODE_SIGNING_ALLOWED` on, and re-run `xcodegen generate`. You can also pass `CODE_SIGNING_ALLOWED=NO` on the `xcodebuild` command line to force an unsigned build.

Release builds are maintainer only. These scripts need the maintainer's Developer ID certificate, notarization credentials and Sparkle signing key, none of which are in this repo:

| Script | Purpose |
|--------|---------|
| `scripts/notarize-mac.sh` | Archive, export with Developer ID, notarize, staple, and package a DMG. |
| `scripts/sign-notarize-local.sh` | Developer ID sign, notarize, staple and package an already built unsigned `PocketAI.app`. |
| `scripts/make-appcast.sh` | Sign a notarized DMG and update the Sparkle appcast. |

`SUFeedURL` and `SUPublicEDKey` are empty in `project.yml`. With an empty feed the updater is treated as unconfigured and the update menu item is disabled, so a local build never tries to update itself.

## Using a self-hosted LiveShortly server

The Mac app talks to LiveShortly in two places. Both default to `https://liveshortly.com` and both can point at your own [liveshortly-server](https://github.com/liveshortly/liveshortly-server).

**The `live` daemon (LiveShortly card in the main window).** This card installs or updates the `live` CLI (into `~/.local/bin/live`, from the published `live` releases), signs in with `live login`, and runs `live daemon` for the folders you choose. The app finds `live` on your login shell's `PATH` plus `~/.local/bin`, `/opt/homebrew/bin` and `/usr/local/bin`; the daemon also needs `tmux`. The app must not be sandboxed for this to work.

The server row on the card shows which server `live` uses. Choose **Change → Custom…** and enter your server's origin (for example `https://live.example.com` or `http://localhost:8080`). The app runs `live host set <url>` (or, for older CLIs without `live host`, writes `~/.liveshortly/host.json` with `api_url` and `web_url`) and restarts a running daemon. **Change → liveshortly.com** runs `live host reset`. You can do the same from a terminal:

```sh
live host set https://live.example.com
live host reset
```

The server is resolved the same way the CLI does it: `~/.liveshortly/host.json`, then the `LIVESHORTLY_API_URL` environment variable, then `https://liveshortly.com`. Before offering sign-in the app checks `<server>/health`; any HTTP answer below 500 counts as reachable.

**The in-app account (Settings → LiveShortly).** This connects the app itself to a LiveShortly account to list and follow sessions. Enter your server URL in the **Server** field before connecting. The connection is a device-code sign-in; the server URL and tokens are stored together in the Keychain. If you type a host without a scheme, `https://` is assumed. The app declares no App Transport Security exceptions, so use an HTTPS server for this connection.

## Repo layout

| Path | Contents |
|------|----------|
| `Sources/` | App code. Top-level folders: `Chat`, `Devices` (iPhone pairing), `Images`, `Intents`, `LiveShortly` (`live` daemon control and session views), `Models`, `Onboarding`, `Palette`, `Projects`, `QuickAsk`, `Server` (local OpenAI-compatible server UI), `Settings`, `Shared`, `Shell`, `Theme`, `Updates` (Sparkle). |
| `Resources/` | String catalog (`Localizable.xcstrings`). |
| `Entitlements/` | App entitlements (hardened runtime). |
| `Tests/` | Unit and integration tests. |
| `UITests/` | XCUITest suite. |
| `scripts/` | Self-tests, UI test runner, and maintainer release scripts. |
| `docs/` | Maintainer notes. <!-- TODO(owner): docs/launch-runbook.md is an internal launch checklist; consider removing it before going public. --> |
| `project.yml` | XcodeGen project definition. |

## Contributing

- Edit `project.yml`, never `PocketAI.xcodeproj`, and do not commit the generated project.
- Use colors, fonts and spacing from `PocketUI` tokens rather than literals.
- Shared logic and UI components belong in PocketAI.Core; open the change there.
- Make sure `xcodebuild -scheme PocketAI -destination 'platform=macOS' build` and the unit tests pass before opening a pull request.

<!-- TODO(owner): add contribution terms (issues/PRs welcome? CLA?). The current LICENSE grants no rights to use or modify the code. -->

## License

Copyright (c) 2026 Rohit Sehgal. All rights reserved. This is proprietary software; see [`LICENSE`](LICENSE). Making the repository public does not grant any license to use, copy, modify or distribute it.

<!-- TODO(owner): a public repo keeps this proprietary "All rights reserved" license unless you change LICENSE. -->
