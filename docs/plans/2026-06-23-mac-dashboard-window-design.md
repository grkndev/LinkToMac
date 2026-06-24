# Mac dashboard window — design

**Date:** 2026-06-23
**Component:** `mac/` (SwiftUI menu-bar agent)
**Status:** Phase 2 implemented (2026-06-24) — phone battery+name (`stat`), Mac battery, clip
history, transport + status all wired to real data. Right-panel tabs / media / Lock / Cast remain
roadmap placeholders.

## Goal

Expand the macOS app from a menu-bar-only agent into a **menu-bar + windowed app**. The
menu-bar extra stays; a new main **dashboard window** opens on launch and mirrors the Android
app's home: phone identity, battery, transport, clipboard, settings — plus scaffolding for
roadmap features (notifications/messages/calls/photos sync, screen cast, media player, reverse
remote-lock).

Reference layout: `local-assets/MacBook Air - 1.png` — a wide two-column dark dashboard.

## Decisions (from brainstorming)

- **Regular Dock app** now (was an `LSUIElement` accessory). Dock icon appears; the menu-bar
  extra is kept. Closing the window leaves the app alive in the menu bar; quit via menu/⌘Q.
- **Window every launch.** Opens on start, reopenable from the menu and the Dock.
- **Menu shrinks** to a quick-glance surface: status pill + the load-bearing toggles
  (Send-to-Android, Lock-when-phone-leaves) + "Open Window…" + Quit. Everything structural
  (pairing, server settings, connect, login item, updates, about, unpair) moves into the window.
- **Layout** follows the mock: left `PhonePanel` (identity + action grid + media-player card),
  right `FeaturePanel` (Notifications/Messages/Calls/Photos tabs + rows).
- **Folded sub-screens.** Settings / Pairing QR / About move from 3 standalone `NSWindow`s into
  the main window (NavigationStack pushes; Pairing as a sheet). The existing
  `ServerSettingsView` / `PairingView` / `AboutView` are reused, not rewritten.
- **Clip history** shown in the window is a Mac-local list (no protocol change). Phase 2.
- **Icons:** SF Symbols throughout (no phone-render asset in phase 1).

### Phase 1 = static UI shell (this round)

All displayed **telemetry is hardcoded placeholder** — phone name "grkn's S24 Ultra", battery
68% / 100%, "Connected", LAN/Relay pills, clip rows, notification rows. Roadmap actions
(Lock Phone, Cast Screen) render **disabled with a "soon" badge**. The right-panel tabs render
**faithful placeholders** (dummy rows) per the mock. The folded **Settings / Pairing / About
stay fully functional** (they are controls, not telemetry).

### Phase 2 = real data — **DONE (2026-06-24)**

Wire every placeholder to real data (implemented as described below, except the right-panel
Notifications/Messages/Calls/Photos tabs, which stay placeholder — roadmap, no data source):

- **Phone battery + name plumbing (cross-language, new):** the phone has never sent its own
  battery or name. Reuse the existing `stat` frame; extend the payload to
  `{"level":N,"charging":bool,"name":"…"}` (the Mac already sends `{level,charging}` — symmetric,
  it ignores `name`). The relay already forwards `stat` opaque → **server untouched**.
  - Phone (Kotlin): read `BatteryManager` + device name (`Settings.Global "device_name"` →
    `Build.MODEL`); send `stat` on connect + battery-change, on both `RelayClient.kt` and
    `LanClient.kt`; do it in the foreground service so it survives a JS-dead app.
  - Mac (Swift): add inbound `case stat` to `ServerMessage` in `RelayProtocol.swift`; decode in
    `RelayClient` → new `@MainActor` observables `phoneBatteryLevel` / `phoneCharging` /
    `phoneName`; add `onRemoteStat` to `LanServer` and funnel through `AppDelegate` like clip/cmd.
- **Mac-local clip history ring** feeding `ClipHistoryScreen`.
- Wire status pill, LAN/Relay pills, Mac battery, toggles to the real `client` / `proximity`
  observables (the menu already reads these).

Contracts touched in phase 2 (the hand-mirror rule): `RelayProtocol.swift` (+inbound stat),
Kotlin inline `JSONObject`. Crypto/`ClipCodec` already byte-compatible. `server/src/protocol.ts`
already defines `StatMsg` (doc only).

## File plan (phase 1)

**New (`mac/Sources/LinkToMac/`):**

- `DashboardWindow.swift` — `Window(id:"dashboard")` scene + `DashboardView` root (HStack inside
  `NavigationStack`).
- `PhonePanel.swift` — left column: phone tile (SF Symbol), name, status, pills, action grid,
  media-player placeholder card.
- `FeaturePanel.swift` — right column: segmented tabs + dummy rows.
- `DashboardComponents.swift` — `Pill`, `ActionButton`, `FeatureTab`, `FeatureRow`.
- `SettingsScreen.swift` — aggregates `ServerSettingsView` + general rows (pairing, connect,
  login item, updates, about) + unpair.
- `ClipHistoryScreen.swift` — placeholder clip list.

**Edited:**

- `LinkToMacApp.swift` — add the `Window` scene; `AppDelegate` open-on-launch + activate,
  `applicationShouldTerminateAfterLastWindowClosed=false`, `applicationShouldHandleReopen`;
  delete the 3 `NSWindow` vars + `showPairing/ServerSettings/About` builders.
- `MenuPanel.swift` — shrink; add "Open Window…".
- `Resources/Info.plist` — `LSUIElement` → `false` (Dock icon).
- `mac/CLAUDE.md` + root `CLAUDE.md` — keep in sync.

`project.yml` is untouched (sources auto-globbed) but **`xcodegen generate`** is required so the
generated, gitignored `.xcodeproj` picks up the new files.

## Verification

No test target. `cd mac && xcodegen generate` → build. Manual: launch shows the window + a Dock
icon; the menu-bar extra still works; closing the window keeps the app alive in the menu bar;
reopen from the menu and the Dock; Settings / Pairing / About reachable in-window.
