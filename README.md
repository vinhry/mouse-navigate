# MouseNavigate

<p align="center">
  <img src="./Assets/mouse-navigation-icon.png" alt="Mouse Navigation Icon" width="96" />
</p>

Global mouse side-button navigation and keyboard cursor control for macOS.

## Why This Project

I wanted simple mouse side-button behavior on macOS without running a heavy helper suite.
MouseNavigate focuses on the button mapping logic and keeps everything minimal, and adds
keyboard cursor control so the pointer is reachable without leaving the home row.

## Device Support

MouseNavigate detects the attached mouse and applies that model's button profile
automatically. Each model keeps its own saved mapping, so switching mice never means
remapping.

| Model | Status |
|-------|--------|
| Logitech MX Master 4 | Auto-detected |
| Logitech MX Master 3 / 3S | Auto-detected |
| Anything else | Falls back to a generic profile |

Detection reads the HID product string first and falls back to a product-ID table, so the
same mouse is recognised over Bluetooth, a Bolt receiver or a Unifying receiver. Override
it manually in **Preferences → Mouse** if you prefer.

To see what MouseNavigate detects:

```bash
./.build/release/MouseNavigate --list-devices
```

## Behavior

- Buttons `3`–`9` are individually configurable via **Preferences** (see [Button Mapping](#button-mapping) below).
- Hold `A` to drive the pointer from the keyboard (see [Keyboard Cursor](#keyboard-cursor) below).
- Default mapping:
  - Button `3` → Back (`⌘[`) in supported browsers & Finder
  - Button `4` → Forward (`⌘]`) in supported browsers & Finder
  - Button `5` → App Exposé system-wide (uses your configured Mission Control shortcut if enabled)
  - Button `6` → Mission Control system-wide (uses your configured Mission Control shortcut if enabled)
- Single-instance guard: launching again shows `MouseNavigate is already running.`
- Background daemon architecture: `.app` launch starts a lightweight background daemon, keeping the main process footprint minimal.

## Status Bar

- While running, MouseNavigate shows a mouse icon (🖱) in the macOS menu bar.
- The icon is a gray/white template image that automatically adapts to light and dark menu bar appearances.
- When **Paused**, the icon switches to an outline mouse to indicate navigation is suspended.
- While keyboard cursor mode is engaged, the icon switches to a motion cursor so it is obvious that keys are being captured.
- Hover the icon to see a tooltip confirming the running or paused state.
- Right-click (or click) the icon for the context menu:
  - **MouseNavigate** / **vX.Y.Z** — app name and version header (non-interactive)
  - **⚠ Grant Accessibility Permission…** — shown only when the permission has been revoked; clicking opens System Settings → Accessibility directly
  - **Pause** / **Resume** — temporarily suspends all button handling without quitting
  - **Launch at Login** ✓ — toggle to start MouseNavigate automatically at login
  - **⚠ Grant Input Monitoring…** — shown only when keyboard events are blocked
  - **Preferences…** — open the Preferences window
  - **Quit MouseNavigate** — stops the daemon

## Button Mapping

Open **Preferences…** from the status bar menu to configure each button.

Mappings are saved **per device profile**, so the MX Master 4 and MX Master 3 each keep
their own layout.

| Button | MX Master 4 default | MX Master 3 default |
|--------|---------------------|---------------------|
| 3 | Back (`⌘[`) | Back (`⌘[`) |
| 4 | Forward (`⌘]`) | Forward (`⌘]`) |
| 5 | App Exposé | — |
| 6 | Mission Control | — |
| 7–9 | — | — |

Available actions: Back, Forward, App Exposé, Mission Control, Toggle Keyboard Cursor, Disabled.

Not sure which physical button is which? Open **Preferences → Mouse** and press a button —
the panel reports the number it reported, so you can map it directly.

Changes apply immediately and persist across restarts (stored in `UserDefaults` suite `com.vinhry.MouseNavigate`).

**Back / Forward — supported apps:**
Safari, Finder, Chrome, Chrome Canary, Firefox, Firefox Developer Edition, Arc, Brave, Edge, Opera, Vivaldi, Orion

## Keyboard Cursor

Drive the pointer without leaving the home row. **Hold** the activate key (`A` by default)
to engage, then:

| Key | Action |
|-----|--------|
| `I` / `K` / `J` / `L` | Move up / down / left / right |
| `S` | Left click — hold it while moving to drag |
| `D` | Right click |
| `F` | Middle click |
| `Space` (hold) | `IJKL` scrolls instead of moving |
| `;` | Lock cursor mode so it stays on after releasing `A` |
| `Esc` | Exit, releasing anything still held |

Speed tiers, held alongside `A`:

| Modifier | Effect |
|----------|--------|
| *(none)* | Normal — eases from 280 up to 1400 pt/s |
| `Shift` | Fast (×2.2) |
| `Shift`+`Ctrl` | Fastest (×4.0) |
| `Option` | Precision (×0.25) |

Movement eases in rather than starting at full speed, and diagonals travel at the same
rate as the axes. Every key and every speed is rebindable in **Preferences → Keyboard
Cursor**, along with the hold delay.

### Why it does not break typing

`A` is an ordinary letter, so MouseNavigate never simply swallows it. The key is withheld
for the hold delay (250 ms by default) and cursor mode engages only if it is *still* down
when that expires. Anything else hands the letter straight back:

- **Released early** — a tap types `a` as usual.
- **Another key arrives first** — typing `as` or `ad` at speed replays the `a` and gets out
  of the way, so a roll never fires a click.
- **A modifier is involved** — `⌘A`, `⇧A` and friends pass through untouched.
- **A password field has focus** — Secure Event Input cuts the tap off entirely, so `A`
  behaves completely normally.

While engaged, only the mapped keys are captured; everything else still reaches the
frontmost app, so `⌘Tab` and `⌘W` keep working. Cursor mode also releases everything and
stands down on sleep, screen lock, **Pause**, and if the event tap is ever cut off
mid-hold.

You can also bind a mouse button to **Toggle Keyboard Cursor** to latch the mode without
using the keyboard at all.

## Resource Usage

- Designed for idle background use.
- Typical idle usage: less than `30 MB` memory and around `0%` CPU most of the time.
  - The daemon runs `NSApplication` with a status bar item, which loads AppKit — the primary baseline cost. The `ServiceManagement` framework (Launch at Login) adds a small fixed overhead on top.
  - Opening Preferences for the first time allocates the mapping panel (~2 MB additional); it stays resident until the app quits.
- No network activity required.

## Quick Start

1. Build app bundle:
```bash
./scripts/build-app.sh
```

2. Install:
```bash
cp -R dist/MouseNavigate.app /Applications/
```

3. Launch:
```bash
open /Applications/MouseNavigate.app
```

4. Grant permissions:
- `System Settings` -> `Privacy & Security` -> `Accessibility`
- `System Settings` -> `Privacy & Security` -> `Input Monitoring` (if prompted)

## Build

```bash
swift build
```

## Test

```bash
swift test
```

The pure logic — device matching, the movement curve, screen clamping and the activation
state machine that protects normal typing — lives in the `MouseNavigateCore` target so it
can be tested without any UI.

## Build .app Bundle

```bash
./scripts/build-app.sh
```

Use stable signing (recommended for Accessibility permission persistence):

```bash
security find-identity -v -p codesigning
SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./scripts/build-app.sh
```

If `SIGN_IDENTITY` is not set, the script tries to auto-pick an `Apple Development` identity.
If none is found, it falls back to ad-hoc signing (`-`), which may require re-adding Accessibility permission after rebuilds.

This creates:

```bash
dist/MouseNavigate.app
```

## Run from Source

```bash
swift run
```

Or run the built binary directly:

```bash
./.build/debug/MouseNavigate
```

## Security & Privacy

- MouseNavigate listens to global side-button mouse events, and to key events when
  keyboard cursor control is enabled. Keystrokes are inspected only to match them against
  your configured bindings; nothing is recorded or stored.
- MouseNavigate sends local keyboard/system actions.
- MouseNavigate requires macOS Accessibility/Input Monitoring permissions.
- MouseNavigate does not require network access to function.

## Gatekeeper Notes

- If app is ad-hoc signed, macOS may warn on first launch.
- For stable identity and fewer permission resets, sign with a persistent development certificate.

## Images

![Mouse Navigate Logitech MX4](./Assets/mouse-navigate-logitech-mx4.png)

## Versioning

- Current release: `0.1.0`
- Create a git tag for release:
```bash
git tag v0.1.0
git push origin v0.1.0
```

## Icon Attribution

- App icon source: Noun Project, "Mouse Navigation" by Sergey Demushkin
  https://thenounproject.com/icon/mouse-navigation-376186/
- Ensure your use complies with Noun Project license terms/attribution requirements.
