# Agent Guide

Use this guide when an agent needs to build, test, install, or launch the iOS app in Simulator.

## Project

- Root: `/Users/a/SensiboToggle`
- Xcode project: `SensiboToggle.xcodeproj`
- Scheme: `SensiboToggle`
- Bundle id: `com.a.SensiboToggle`
- Preferred simulator: `iPhone 17`
- Live config file: `config/local.config.json`

Treat `config/local.config.json` as secret-bearing. It is git-ignored. Do not print the API key; report only whether it is configured.

## Simulator Diagnosis

If `xcrun simctl ...` fails with `CoreSimulatorService connection became invalid`, do not conclude that iOS runtimes are missing. In Codex-style sandboxes this can be a permissions boundary. Re-run the same simulator query with normal local permissions / user approval.

Check Xcode and simulator availability:

```sh
xcodebuild -version
xcrun simctl list runtimes
xcrun simctl list devices available
```

Expected healthy state on this machine during the original setup:

- Xcode was installed.
- iOS 26.5 runtime was installed.
- `iPhone 17` existed and could be booted.

Use the current command output as authoritative; the expected state above may age.

## Build

Run builds through Xcode, not `swift build`.

```sh
cd /Users/a/SensiboToggle
xcodebuild -quiet \
  -project SensiboToggle.xcodeproj \
  -scheme SensiboToggle \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath build/DerivedData \
  build
```

If this reaches Swift compile errors, the simulator runtime is working. Fix the source error instead of telling the user the runtime is missing.

## Install

After a successful build:

```sh
cd /Users/a/SensiboToggle
xcrun simctl install booted \
  build/DerivedData/Build/Products/Debug-iphonesimulator/SensiboToggle.app
```

## Bedroom 1 Widget

The app embeds a WidgetKit extension named `BedroomOneWidgetExtension`. Its widget UI source is `BedroomOneWidget/BedroomOneWidget.swift`, shared action/client support is in `Sources/BedroomOneWidgetSupport.swift`, and the installed widget is displayed as `Bedroom 1 AC`.

Verify the built app includes the extension before installing:

```sh
find build/DerivedData/Build/Products/Debug-iphonesimulator/SensiboToggle.app/PlugIns \
  -maxdepth 2 \
  -type d \
  -name '*.appex' \
  -print
```

The widget reads the same secret-bearing `config/local.config.json` resource as the app. The simulator CLI can install the app with the widget extension, but it does not provide a supported command to place the widget on the Home Screen. Add it manually from the simulator widget gallery.

In real mode, tapping the `Bedroom 1 AC` widget toggles the physical Bedroom 1 air conditioner. During verification, confirm the widget exists but do not tap it unless the user explicitly approves changing the AC state.

## Launch Safely

Use mock mode for screenshots, UI checks, and tests where tapping should not affect the real air conditioner:

```sh
SIMCTL_CHILD_SENSIBO_MOCK=1 \
xcrun simctl launch --terminate-running-process booted com.a.SensiboToggle
```

Use real mode only when the user explicitly wants the app connected to Sensibo:

```sh
xcrun simctl launch --terminate-running-process booted com.a.SensiboToggle
```

In real mode, the app reads `config/local.config.json` and connects to `https://home.sensibo.com/api/v2`. Tapping switches can change the physical AC state.

## Screenshot

Capture the visible simulator state:

```sh
cd /Users/a/SensiboToggle
xcrun simctl io booted screenshot build/sensibo-iphone17.png
```

`No display specified` is normal when the simulator has one display.

## Menu Bar Target

The `macos-menubar` branch offers a front-end *alternative* to the home-screen
widget: a **resident menu-bar app** (`MenuBarExtra`, macOS 14+) that pins a
toggle to the status bar, so the AC can be flipped on/off without placing a
widget. It reuses the **identical core** (`ACController` + `SensiboClient` /
`MockSensiboClient` / `Config`), so behaviour (optimistic toggle, mock mode,
live mode) is the same.

- `SensiboToggleMenuBar` (application, scheme `SensiboToggleMenuBar`, product
   `SensiboMenuBar.app`, id `com.a.SensiboToggle.MenuBar`) — a menu-bar-only
   agent (`LSUIElement`: no Dock icon). Its `MenuBar/Info.plist` is
   hand-maintained and protected from xcodegen (`INFOPLIST_FILE` +
   `GENERATE_INFOPLIST_FILE: NO`, `info:` omitted) exactly like the widget plists.
- Sources: `Sources/MenuBar/SensiboMenuBarApp.swift` (`@main`, `MenuBarExtra`)
   and `Sources/MenuBar/SensiboMenuBarView.swift` (one toggle row per AC). The
   bar icon flips `flame` → `flame.fill` to show on/off at a glance.

Build:

```sh
cd /Users/a/SensiboToggle
xcodebuild -quiet \
  -project SensiboToggle.xcodeproj \
     -scheme SensiboToggleMenuBar \
      -destination 'platform=macOS,arch=arm64' \
     -derivedDataPath build/macOS-DerivedData \
  build
```

Launch WITHOUT affecting the physical AC (mock mode):

```sh
cd /Users/a/SensiboToggle
SENSIBO_MOCK=1 \
  build/macOS-DerivedData/Build/Products/Debug/SensiboMenuBar.app/Contents/MacOS/SensiboMenuBar
```

Real mode = launch without `SENSIBO_MOCK=1`; the agent then reads the
secret-bearing `config/local.config.json` and a toggle changes the physical AC.
Set `SENSIBO_API_KEY` only with user approval. To quit the agent:
`pkill -f SensiboMenuBar`.

## Safe Tests

The full test scheme includes live integration paths that may touch the Sensibo API and can change real device state. Prefer the hermetic controller tests and mock-mode UI tests unless the user explicitly approves live testing.

```sh
cd /Users/a/SensiboToggle
xcodebuild -quiet \
  -project SensiboToggle.xcodeproj \
  -scheme SensiboToggle \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath build/DerivedData \
  -only-testing:SensiboTests/ControllerTests \
  -only-testing:SensiboUITests/SensiboUITests \
  test
```

UI tests pass `SENSIBO_MOCK=1`, so they do not contact the real device.

## Live Checks

Only run live tests after explicit user approval. They may read and write real AC state.

If a live test needs a key, prefer an environment variable:

```sh
SENSIBO_LIVE_KEY='<redacted>' \
xcodebuild -quiet \
  -project SensiboToggle.xcodeproj \
  -scheme SensiboToggle \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath build/DerivedData \
  -only-testing:SensiboTests/SensiboIntegrationTests \
  test
```

Do not put the literal key in test source, README examples, terminal summaries, or final responses.
