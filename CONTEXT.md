# Context — SensiboToggle

Fast orientation for a fresh agent/session. This complements `AGENTS.md`
(which is the operational how‑to: build / test / install / launch). Read the
two together.

> Note: this volume is **case‑insensitive**, so `context.md`/`CONTEXT.md` and
> `agent.md`/`AGENTS.md` are the **same files on disk**. Use uppercase.

## One‑liner

`SensiboToggle` is a SwiftUI iOS app that toggles an AC (via the Sensibo cloud
API) and a Tapo light (local Tapo API) from a touch control panel. It runs
permanently on an old iPhone (SE 2nd gen) mounted on the wall under iOS
Guided Access. It also ships a home‑screen WidgetKit widget (`Bedroom 1 AC`)
and, on the `macos-menubar` branch, a menu‑bar alternative.

## The two things the app does

- **AC toggle** — `ACController` talks to `SensiboClient` (live HTTP) or
  `MockSensiboClient` (offline). Optimistic update; flips a bar icon.
- **Light toggle** — `TapoController` toggles a Tapo bulb (verandah light,
  `type: "tapo"`) over the local Tapo API.
- **Wall‑panel / kiosk mode** — see `feature/wall-panel-kiosk` below.

## Run modes

- **Mock mode** — `SENSIBO_MOCK=1` (or `mockMode` in config). No Sensibo
  network; AC toggles are simulated. **Safe; never touches a real AC.** Use
  this for any screenshot, UI check, or test. In `xcrun simctl launch` prefix
  the env var with `SIMCTL_CHILD_` so it reaches the spawned app process.
- **Live mode** — no mock flag. Reads `config/local.config.json` and calls
  `https://home.sensibo.com/api/v2`; toggling changes the **REAL** AC. Needs
  explicit user approval; do not run casually.

## Config (precedence: env > JSON > defaults)

- `config/local.config.json` — **git‑ignored, SECRET‑BEARING** (contains
  `apiKey`). Do **not** print it; report only whether it is configured. Edit
  via a script that never echoes the key.
- `config/local.config.example.json` — checked‑in schema with safe placeholders.
- Keys: `apiKey`, `baseURL`, `mockMode`, `tapo{email,password,devices:[...]}`,
  and the wall‑panel block `wallPanel{enabled,idleSeconds}` plus flat
  `wallPanelEnabled` / `wallPanelIdleSeconds`.
- Env overrides: `WALL_PANEL` (1/true/yes/on) and `WALL_PANEL_IDLE_SECONDS`;
  in `xcrun simctl launch` prefix with `SIMCTL_CHILD_`.

## Wall‑panel / kiosk mode  (branch `feature/wall-panel-kiosk`, commit `3285523`)

Goal: run on the wall‑mounted SE as a permanent touch panel under Guided
Access.

- **Never sleeps** — `KioskAppDelegate` sets
  `application.isIdleTimerDisabled = config.wallPanelEnabled` while kiosk is on
  (pairs with Guided Access so the OS never auto‑locks/dims). Process stays
  alive while blank.
- **Blanks on idle** — `IdleDimmingController`
  (`Sources/IdleDimmingController.swift`) drops a full‑bleed opaque black
  overlay and hides the status bar after `wallPanelIdleSeconds` (default 15s)
  of no movement. iOS has **no public hardware‑brightness API**, so "dim to
  zero" is a black overlay (≈no light), not real brightness.
- **Wakes on any touch** — `registerActivity()` clears the overlay and
  restarts the countdown; every toggle and the root tap also count as activity.
- **Configurable & off by default** — overlay renders only when enabled *and*
  dimmed; disabled ⇒ zero behavior change; `registerActivity()` early‑returns
  when disabled; the idle timer is disabled only when enabled.
- **Testable** — an `IdleScheduler` seam (prod `TaskIdleScheduler`; tests
  `ManualIdleScheduler`, hermetic, no `Task.sleep`) drives dimming, mirroring
  the existing "inject `client:`" pattern.
- **Proven in the simulator:** idle→blank (`0/0/0`), then tap→woken (full
  dashboard, status bar hidden), process alive the whole time (never locked).

## Seeing the simulator on the desktop  ← standing user preference

> **When you run the simulator, open its window on the user's desktop so they
> can watch and interact — do it whenever possible.** Don't launch headless.

Recipe (Xcode 26.x — note `xcrun simctl open` *does not exist here*):

```sh
xcrun simctl boot <iPhone-17-UDID>          # e.g. 10E477E3-AB80-452A-9C05-8B8C65B40D90
open -a Simulator
osascript -e 'tell application "Simulator" to activate'   # bring its window to front
```

Gotchas when watching a wall‑panel run:

- A launched wall‑panel app **blanks after its idle window**; a "just
  launched" screenshot can therefore look black. To let the user watch it
  live, start it with a long idle so it stays visible:
  `SIMCTL_CHILD_WALL_PANEL_IDLE_SECONDS=120 SIMCTL_CHILD_SENSIBO_MOCK=1 xcrun
  simctl launch --terminate-running-process booted com.a.SensiboToggle`.
- `xcrun simctl` **cannot** synthesize a coordinate tap (no `io tap` / `open`
  subcommand). "Wake on touch" is proven by the committed UI test
  `SensiboUITests/WallPanelUITests`, not the CLI. `xcrun simctl launch` with
  no `--terminate` does not re‑fire `scenePhase=.active`, so it will **not**
  re‑wake a blanked panel.
- Capture a frame: `xcrun simctl io booted screenshot <path>`
  ("No display specified" is normal with one display).

## Safety rules

- `config/local.config.json` and any real `apiKey`: never print / commit / echo
  into summaries. Edit via a key‑agnostic script.
- Default to **MOCK** mode for any launch / screenshot / test. Only run
  **LIVE / real AC** after explicit user approval.
- Live tests may read/write real AC state — get approval first.
- The `edit` tool is atomtic (all‑or‑nothing); `Config.swift` has odd
  indentation — use tiny exact `oldText` anchors, or fall back to `write`.

## Layout pointers

- `@main App`: `Sources/SensiboToggleApp.swift` (scene‑based; adds
  `KioskAppDelegate` on this branch).
- UI: `Sources/ContentView.swift` (toggles + `WallBlankOverlay`).
- Core: `Sources/ACController.swift` (flat, the LIVE one),
  `Sources/TapoController.swift`, `Sources/{Config,Models}.swift`,
  `Sources/IdleDimmingController.swift`.
- **ORPHAN (ignore):** `Sources/Controllers/ACController.swift` is not wired
  into `project.yml`; the flat `Sources/ACController.swift` is used.
- Project is generated from `project.yml` with `xcodegen` 2.46 — re‑run
  `xcodegen generate` after adding files/targets.
- Tests: `Tests/Unit/*` (hermetic — `IdleDimmingControllerTests`,
  `ModelAndConfigTests`) and `Tests/UI/*` (launch the app in mock mode —
  `WallPanelUITests`).

## Current state (last session)

- Branch `feature/wall-panel-kiosk` @ `3285523`; clean tree (only pre‑existing
  untracked `.github/`).
- `config/local.config.json` has `wallPanel {enabled: true, idleSeconds: 15}`
  and a real `apiKey` (present, not printed).
- Full wall‑panel loop demonstrated on the desktop simulator.
