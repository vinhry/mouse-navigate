# MouseNavigate

<p align="center">
  <img src="./Assets/mouse-navigation-icon.png" alt="Mouse Navigation Icon" width="96" />
</p>

Global mouse side-button navigation, touch gestures and keyboard cursor control for macOS.

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
| Built-in keyboard / trackpad, Magic Trackpad | Ignored — never treated as a mouse |

Detection reads the HID product string first and falls back to a product-ID table, so the
same mouse is recognised over Bluetooth, a Bolt receiver or a Unifying receiver. A MacBook's
built-in keyboard and trackpad report themselves as a pointing device too, so built-in
devices, trackpads and keyboards are skipped; with no mouse attached the Mouse tab says
**No mouse detected**. Override the profile manually in **Preferences → Mouse** if you prefer.

To see what MouseNavigate detects:

```bash
./.build/release/MouseNavigate --list-devices
```

## Behavior

- Buttons `3`–`9` are individually configurable via **Preferences** (see [Button Mapping](#button-mapping) below).
- Hold `A` to drive the pointer from the keyboard (see [Keyboard Cursor](#keyboard-cursor) below).
- Opt-in trackpad, Magic Mouse and drawn-letter gestures (see [Touch Gestures](#touch-gestures) below).
- Default mapping:
  - Button `3` → Back (`⌘[`) in supported browsers & Finder
  - Button `4` → Forward (`⌘]`) in supported browsers & Finder
  - Button `5` → App Exposé system-wide (uses your configured Mission Control shortcut if enabled)
  - Button `6` → Mission Control system-wide (uses your configured Mission Control shortcut if enabled)
- Single-instance: one process, registered with macOS. Launching it again opens Preferences
  rather than starting a second copy.
- The menu bar icon appears first, before permissions, device detection and gesture support
  are started, so the app can always be seen and quit even when something below it stalls.

## Status Bar

- While running, MouseNavigate shows a mouse icon (🖱) in the macOS menu bar.
- The icon is a gray/white template image that automatically adapts to light and dark menu bar appearances.
- When **Paused**, the icon switches to an outline mouse to indicate navigation is suspended.
- While keyboard cursor mode is engaged, the icon switches to a motion cursor so it is obvious that keys are being captured.
- Until Accessibility permission is granted, the icon shows a warning triangle. MouseNavigate keeps running and starts working as soon as the permission is turned on — no relaunch needed.
- Hover the icon to see a tooltip confirming the running or paused state.
- Right-click (or click) the icon for the context menu:
  - **MouseNavigate** / **vX.Y.Z** — app name and version header (non-interactive)
  - **⚠ Grant Accessibility Permission…** — shown only while the permission is missing; clicking opens System Settings → Accessibility directly
  - **Pause** / **Resume** — temporarily suspends all button handling without quitting
  - **Launch at Login** ✓ — toggle to start MouseNavigate automatically at login
  - **⚠ Grant Input Monitoring…** — shown only when keyboard events are blocked
  - **Preferences…** — open the Preferences window
  - **Quit MouseNavigate** — quits the app

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

Available actions, shared by mouse buttons, touch gestures and drawn letters:

| Group | Actions |
|-------|---------|
| Browsing | Back, Forward, Next Tab (`⌃⇥`), Previous Tab (`⌃⇧⇥`), New Tab, Close Tab / Window, Reopen Closed Tab, Refresh, Open Link in New Tab (middle click) |
| Editing | Copy, Paste, New, Open, Save, Quit App |
| Windows | Minimize, Maximize (again to restore), Maximize Left, Maximize Right, Move / Resize (gestures only) |
| System | App Exposé, Mission Control, Show Desktop, Move Left / Right a Space |
| Launch | Finder, Default Browser |
| App | Toggle Keyboard Cursor, Disabled |

Maximize Left / Right on a window that already fills that half carries it on to the next
display. Window actions use the Accessibility permission the app already has.

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
for the hold delay (0.5 s by default) and cursor mode engages only if it is *still* down
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

### Typing the letter repeatedly

Holding a key down is how every other letter repeats, and on `A` that is spoken for. The
way back in is to **tap `A`, then press it again straight away and keep it down**: the
second press is handed over untouched, so `aaaa…` comes out exactly as it would from any
other key and cursor mode stays out of it. How soon that second press has to land is
**Double-tap to repeat** in **Preferences → Keyboard Cursor** — 0.4 s by default, and
`Off` at zero.

## Touch Gestures

jitouch-style multitouch gestures for the trackpad and Magic Mouse, plus drawn letters.
They are **off by default**: turn them on in **Preferences → Touch**, where every gesture
can be bound to any action. Hover over a gesture's name there to see how to do it. Finger
names assume the right hand; tick **Left-handed** to mirror them.

Gestures run alongside the ones built into macOS rather than replacing them, so turn off
any that overlap in `System Settings` → `Trackpad` (for example **Look up & data detectors**
with a three-finger tap). While a gesture is using finger movement, MouseNavigate holds back
the scrolling macOS would otherwise do.

### Trackpad

| Gesture | How | Default |
|---------|-----|---------|
| One-Fix Left-Tap / Right-Tap | Rest one finger, tap another beside it | Previous / Next Tab |
| Three-Finger Tap | Tap with three fingers at once | Open Link in New Tab |
| One-Fix Two-Tap | Rest one finger, tap two others together | Open Link in New Tab |
| One-Fix Two-Slide Down / Up | Rest the index, slide middle and ring down / up | Close Tab / Reopen Closed Tab |
| Click Two-Slide Down | Click and hold with the index, slide middle and ring down | Quit App |
| Two-Fix Index Double-Tap | Rest middle and ring, double-tap the index | Refresh |
| Index-to-Pinky / Pinky-to-Index | Roll four fingers down in order, lift together | Minimize / Maximize |
| One-Fix One-Slide Down | Rest the index, slide the middle down, then move with the index; tap the middle to switch to resizing; lift to finish | Move / Resize Window |

A finger resting in the bottom edge of the trackpad is taken for a thumb and never starts a
gesture, so resting your thumb while tapping or scrolling stays safe.

### Magic Mouse

| Gesture | How | Default |
|---------|-----|---------|
| Middle-Fix Index Near-Tap / Far-Tap | Rest the middle finger, tap the index close by / further away | Next / Previous Tab |
| Middle-Fix Index Slide Left / Right | Rest the middle finger, slide the index | Close Tab / Refresh |
| Index-Fix Middle Slide Left / Right | Rest the index, slide the middle finger | Minimize / Maximize |
| Two-Fix Index Slide Left / Right | Rest middle and ring, slide the index | Move Left / Right a Space |
| Three-Finger Swipe Up / Down | Swipe along the mouse with three fingers | Show Desktop / Mission Control |
| Middle Click | Rest the middle finger, click with the index held nearer the back | Open Link in New Tab |
| Corner Hold | Hold index and middle on opposite corners, move the mouse; lift one finger to resize | Move / Resize Window |

### Drawn letters

Draw a letter or a straight line and it runs the bound action. Sources, each toggled in
**Preferences → Touch → Characters**:

- **Trackpad** (on): move two widely spread fingers, such as index and ring, together.
  **Finger spacing** sets how far apart they must be, from 12% to 60% of the trackpad's
  width (30% by default, about 47 mm on a MacBook Pro). Lower it to draw with index and
  middle; raise it if ordinary two-finger scrolling is being taken for a drawing. The
  slider reads in millimetres once a trackpad is connected.
- **Right-button drag** (off): hold the right button — the right half of a Magic Mouse —
  and draw.
- **Middle-button drag** (off): hold the middle button of any mouse and draw.

A button drag holds the click back until release; a short one is replayed as a normal
click, so context menus open on release while this is on.

The stroke is drawn on screen as you make it, so you can see the shape the app sees. It
appears around the pointer, where you are already looking: a trackpad drawing in the
trackpad's own proportions, a button drag along the path the pointer takes. When you
finish, the ink gives way for half a second to what it was recognised as and the action it
ran — "T" over "New Tab (⌘T)" — in the middle of the screen, or a "no match" when nothing
fit. Untick **Show the drawing on screen** in the Characters section to work without it.

Letters are single strokes, loosely after Graffiti. `I` is a straight line down. To see how
one goes, hover it in **Preferences → Touch → Characters**: the stroke traces itself beside
the list, over and over, with a ring showing where to start.

| Drawn | Default |
|-------|---------|
| `B` | Launch Default Browser |
| `F` | Launch Finder |
| `N` / `O` / `S` | New / Open / Save |
| `T` | New Tab |
| Up / Down (`I`) | Copy / Paste |
| Left / Right | Maximize Left / Right |

Every other letter and the four diagonals start out unbound.

### Not included

Per-app gesture sets, custom keyboard-shortcut actions, and jitouch's Safari-only gestures.

### How it works and tuning

Raw finger positions come from Apple's private `MultitouchSupport` framework, the same
source jitouch and BetterTouchTool read. It is loaded at runtime, so if a future macOS
removes it the Touch tab says gestures are unavailable and nothing else is affected.
Gesture recognition itself is plain Swift in `MouseNavigateCore`, covered by unit tests.

To see what the recognizer sees, quit the app and run it from a terminal:

```bash
dist/MouseNavigate.app/Contents/MacOS/MouseNavigate --touch-debug
```

It prints each surface, every change in finger count with positions, and every recognized
gesture and drawn letter with its match score.

## Resource Usage

- Designed for idle background use, at around `0%` CPU most of the time.
- Memory, measured as the footprint Activity Monitor reports:
  - About `12 MB` sitting in the menu bar, before Preferences has ever been opened. The
    app runs `NSApplication` with a status bar item, which loads AppKit — the baseline
    cost. `ServiceManagement` (Launch at Login) adds a little on top.
  - About `30 MB` once Preferences has been opened. The window and its four pages are kept
    rather than rebuilt: reopening is then instant and costs nothing, where building a fresh
    one each time would add roughly `10 MB` of AppKit caches that are never given back.
  - Touch gestures add the drawing overlay, a window only as large as the drawing itself.
- Drawn strokes are capped and thinned rather than kept whole, so a long one cannot grow
  without bound.
- No network activity required.

## Install

Requires macOS 13 Ventura or later, on Apple silicon or Intel.

1. Download `MouseNavigate.zip` from the [latest release](https://github.com/vinhry/mouse-navigate/releases/latest) and unzip it.
2. Move **MouseNavigate.app** into your **Applications** folder. Run it from there rather
   than from Downloads: macOS launches apps left in Downloads from a temporary read-only
   location, which can break **Launch at Login**.
3. Open it. A notarized release only asks you to confirm that it was downloaded from the
   internet — click **Open**. A release that has not been notarized is refused on first
   open: allow it under `System Settings` → `Privacy & Security` → **Open Anyway**. Every
   release is signed with a Developer ID either way; the release notes say which it is.
4. When asked, allow Accessibility access: `System Settings` → `Privacy & Security` →
   `Accessibility` → turn on **MouseNavigate**. The menu bar icon shows a warning triangle
   until you do, then switches to a mouse — no relaunch needed.
5. If keyboard cursor keys do nothing, also allow `Input Monitoring` in the same place.

Permissions survive updates: download the new release and replace the app.

## Build from Source

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

The pure logic — device matching, the movement curve, screen clamping, the activation
state machine that protects normal typing, window placement, and touch gesture and letter
recognition — lives in the `MouseNavigateCore` target so it can be tested without any UI.

## Build .app Bundle

```bash
./scripts/build-app.sh
```

The script builds `arm64` and `x86_64` separately and merges them into a universal binary.

Use stable signing (recommended for Accessibility permission persistence):

```bash
security find-identity -v -p codesigning
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/build-app.sh
```

If `SIGN_IDENTITY` is not set, the script picks the first `Developer ID Application` identity,
then the first `Apple Development` one. If neither exists, it falls back to ad-hoc signing
(`-`), which ties the permission to that exact build, so macOS asks again after every rebuild.

This creates:

```bash
dist/MouseNavigate.app
```

## About

**Preferences → About** shows the version, links to this repository and the issue tracker,
and the license. MouseNavigate is developed by Vinh Ry and released under the MIT License.

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
- With touch gestures on, it also reads finger positions from the trackpad and Magic
  Mouse, and sees clicks and scrolls, only to recognize gestures. Nothing is recorded or
  stored.
- MouseNavigate sends local keyboard/system actions.
- MouseNavigate requires macOS Accessibility/Input Monitoring permissions.
- MouseNavigate does not require network access to function.

## Gatekeeper Notes

- Releases built by the tag workflow are signed with a Developer ID, notarized and
  stapled, so they open with only the standard downloaded-from-the-internet confirmation.
  A release published by hand from a local build is signed but **not** notarized and needs
  **Open Anyway** once.
- A local build is signed but not notarized. macOS 15 and later block it when it arrives
  from another Mac; allow it under `System Settings` → `Privacy & Security` → **Open Anyway**.
- An ad-hoc signed build loses its Accessibility permission on every rebuild. Sign with a
  Developer ID or Apple Development certificate to avoid that.

## Images

![Mouse Navigate Logitech MX4](./Assets/mouse-navigate-logitech-mx4.png)

## Versioning

- Current release: `0.3.2`
- Pushing a version tag builds, signs, notarizes and publishes the release
  (`.github/workflows/release.yml`):
```bash
git tag v0.3.2
git push origin v0.3.2
```

## Icon Attribution

- App icon source: Noun Project, "Mouse Navigation" by Sergey Demushkin
  https://thenounproject.com/icon/mouse-navigation-376186/
- Ensure your use complies with Noun Project license terms/attribution requirements.
