# tihole for iOS

[![Monitored by Cooper&Wright](https://img.shields.io/badge/monitored%20by-Cooper%26Wright-8a6a3b?style=flat-square)](https://cooperwright.com)

[![CI][ci-badge]][ci]
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A native iOS client for [Pi-hole v6](https://pi-hole.net/), ported from the
[tihole](https://github.com/z19r/tihole) terminal UI. It is written in SwiftUI
and covers the same ground as the TUI: query log, allow/deny lists, groups,
clients, adlists, local DNS, the live FTL config, and system tools, across any
number of Pi-holes.

## Where everything went

The TUI's ten sidebar screens map onto five tabs, plus a blocking pill that sits
in every tab's toolbar.

| TUI screen | iOS |
| --- | --- |
| Dashboard | **Dashboard** tab: tiles, health gauges, queries-over-time chart, query types, upstreams, top domains / blocked / clients |
| Blocking | The **blocking pill** in every tab's toolbar. It shows on/off with a live countdown and opens the five blocking actions |
| Query Log | **Queries** tab: live log, domain filter, detail sheet, swipe to allow or block |
| Domains | **Lists → Domains**: allow/deny, exact/regex, add, edit, enable/disable, delete |
| Adlists | **Lists → Adlists**: block/allow lists and a streamed **gravity update** |
| Groups | **Lists → Groups** |
| Clients | **Lists → Clients**, with suggestions from devices FTL has seen |
| Local DNS | **Lists → Local DNS**: A/AAAA host records and CNAMEs |
| System | **System** tab: info, diagnosis messages, network devices, DNS log tail, destructive actions |
| Settings | **Settings** tab: connections, theme, and the full FTL config tree |

The instance switcher (`s` in the TUI) is the menu at the top left of every tab.
With two or more instances it also offers **Combine all Pi-holes** (`m` in the
TUI): the Dashboard and Query Log then merge every instance as one network.
Counts add up, the blocked percentage is recomputed from the totals, and
overlapping figures (active clients, unique domains, gravity) take the largest
value instead of a sum. An unreachable Pi-hole is named in a banner and the rest
still show. Allow/block on a domain and every other change still go to the
active instance. The one exception is **blocking on/off**: disabling one
redundant Pi-hole does not disable blocking on the network, so in combined mode
the pill shows how many Pi-holes block (`On 2/2`, `Partial 1/2`, `Off 0/2`) and
its actions change every Pi-hole. A Pi-hole that takes over 2 seconds to answer
counts as unreachable, and reads skip it for 30 seconds before trying again.

### What is different from the TUI

- **Polling is slower.** The TUI refreshes four times a second on a LAN. The
  app refreshes the dashboard every 3 seconds and the query log every 2, and
  only while that screen is visible and the app is in the foreground.
- **Groups are picked, not typed.** Forms list the instance's groups with
  checkmarks instead of asking for comma-separated ids.
- **List-valued settings get a list editor.** Settings such as `dns.upstreams`
  are edited row by row. Settings whose value is an object are read-only.
- **Passwords live in the Keychain.** There is no `config.yaml` and no
  `password_env`. Instances are added in the app.
- **No Omarchy theme.** The four built-in themes are the same palettes as the
  TUI's. `Auto` follows the system appearance.

## Requirements

- Xcode 16 or later (CI and App Store builds use Xcode 27)
- iOS 17 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- A Pi-hole running v6 (the FTL REST API at `/api`)

## Getting started

```bash
brew install xcodegen just
just open        # generates Tihole.xcodeproj and opens it in Xcode
```

Pick your development team under Signing & Capabilities, then run. On first
launch the app asks for a name, the Pi-hole's address, and an app password.

The Xcode project is generated from [`project.yml`](project.yml) and is not
checked in. Run `just gen` again after adding or removing files.

## Development

```bash
just test        # PiholeKit + TiholeCore unit tests, on the Mac, no simulator
just build       # generate the project and build for the iOS Simulator
just ui-test     # drive the app through every tab against a mock Pi-hole
just ci          # test + build
just fmt         # swift-format + ruff at 80 columns (Swift runs in Docker)
just fmt-check   # what CI checks
```

The UI smoke test needs no Pi-hole.
[`Tihole/Demo/MockPihole.swift`](Tihole/Demo/MockPihole.swift)
is a small loopback HTTP server that answers like FTL, including rejecting
requests without the session id it issued, so the test exercises the app's
real login path. The test runner runs one copy; the app runs another as the
demo Pi-hole behind the welcome screen's "Try the demo" button, which is how
App Review gets in. Each stop is captured as a screenshot in the test
results; CI uploads them as the `screenshots` artifact.

### App Store listing

The listing lives in the repo. [`metadata/`](metadata) holds the
description, promotional text, keywords, subtitle and URLs, wrapped at 80
columns, and `review_notes.txt`, the notes for App Review. Run the
**App Store assets** workflow from the Actions tab to upload the
screenshots, the header image and all of that text to the editable version.

### Website

[tihole-ios.z19r.com](https://tihole-ios.z19r.com) is built from
[`site/`](site): plain HTML, CSS and JavaScript, no build tools. Its
[privacy page](site/privacy.html) is the policy the App Store listing links
to. Netlify deploys `main`, running `scripts/site_data.py` to write the
version and release feed from `project.yml` and `CHANGELOG.md`. Preview it
with `just site`.

### Layout

```
Packages/TiholeKit/
├── Sources/PiholeKit/     Pi-hole v6 API client: the only code that speaks HTTP
├── Sources/TiholeCore/    config, formatting, config-tree logic (no UI)
└── Tests/                 unit tests for both, against a mock FTL server
Tihole/
├── App/                   app entry, AppModel, tabs, toolbar chrome, blocking
├── Store/                 Keychain passwords, saved config
├── Theme/                 semantic color tokens and the built-in themes
├── Components/            cards, banners, form frame, group picker
├── Demo/                  the mock Pi-hole: the in-app demo and the UI tests'
└── Screens/               one folder per tab
TiholeUITests/             smoke test
```

The layering is the same as the TUI's: **the client knows nothing about the
UI, and the UI depends on the client, never the reverse.** `PiholeKit` and
`TiholeCore` import neither SwiftUI nor UIKit, which is why their tests run on
the host.

- `PiholeClient` is an actor with one method per FTL endpoint. It authenticates
  with the `X-FTL-SID` header, logs in on demand, and on a 401 re-authenticates
  once and retries. Concurrent 401s share a single login, so a burst of parallel
  dashboard fetches never eats more than one of FTL's session seats.
- `AppModel` is the app's equivalent of the TUI's `AppContext`. It owns the
  saved config, the active instance's client, the theme, and the blocking
  status. Screens key their loading tasks on `AppModel.generation`, so
  switching instances reloads everything.
- `CombinedClient` fans the dashboard and query-log reads out to every
  instance and merges the results (the TUI's `pihole.Group`). The merge rules
  are pure functions in `Merge`, tested on their own.
- Screens load in `.task`, which SwiftUI cancels when the view goes away. That
  is the equivalent of the TUI's `Focus()` / `Blur()`.

## Security

- Passwords are stored in the Keychain
  (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`), one item per instance.
  The saved config in UserDefaults holds names and URLs only.
- Passwords and session ids are never logged.
- The app closes its FTL session when it goes to the background so it does not
  hold one of the server's session seats, and logs in again on return.
- "Verify TLS certificate" can be turned off per instance for self-signed
  certificates. That trust exception applies to that instance's host only.
- App Transport Security allows arbitrary loads, because Pi-holes are reached
  over plain HTTP, bare IPs, `.lan` names, and VPN hostnames that cannot be
  listed ahead of time. The app only ever contacts the instances you configure.
  App Review asks for a justification of this setting.
- Restart DNS, flush logs, and flush network need
  `webserver.api.allow_destructive` enabled on the Pi-hole. The app says so when
  FTL refuses.
- Every TestFlight build carries a GitHub build provenance attestation for
  the exact `.ipa` sent to Apple. Download the `Tihole-ipa` artifact from the
  TestFlight run and check it with
  `gh attestation verify Tihole.ipa --repo z19r/tihole-iOS`.

## License

Released under the [MIT License](LICENSE).

The app links only Apple's system frameworks and contains no third-party
code, fonts, or artwork. Build and release tooling (XcodeGen, Pillow, PyJWT,
GitHub Actions) runs in CI and never ships in the app.

Pi-hole is a registered trademark of Pi-hole LLC. tihole talks to Pi-hole
only through its documented API, includes none of its code or logo, and is
not affiliated with or endorsed by Pi-hole LLC.

[ci-badge]:
  https://github.com/z19r/tihole-iOS/actions/workflows/ci.yml/badge.svg
[ci]: https://github.com/z19r/tihole-iOS/actions/workflows/ci.yml
