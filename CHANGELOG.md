# Changelog

All notable changes to this project will be documented in this file.

## [0.3.0] - 2026-09-22

### Added
- **Touch tab** with jitouch-style gestures, off by default:
  - Trackpad: tab switching by tapping beside a resting finger, three-finger tap and
    one-fix two-tap to open links in new tabs, close / reopen tabs, click-slide to quit,
    index double-tap to refresh, four-finger rolls to minimize and maximize, and a
    move / resize window mode.
  - Magic Mouse: near / far taps for tabs, slides for closing tabs, refreshing, minimizing,
    maximizing and changing spaces, three-finger swipes for Show Desktop and Mission
    Control, a middle click, and a corner hold to move / resize windows.
  - Drawn letters A–Z and eight directions, from the trackpad, a right-button drag or a
    middle-button drag.
  - Drawn strokes appear on screen as they are made, around the pointer, followed in the
    middle of the screen by the letter recognised and the action it ran, or "no match".
    Switched off with **Show the drawing on screen**.
  - **Finger spacing** for drawn letters, setting how far apart the two fingers must be
    before a movement counts as drawing rather than scrolling.
  - Hovering a character in Preferences traces its stroke beside the list, looping, with a
    ring marking where the stroke starts.
  - Left-handed mode, and `--touch-debug` for seeing what the recognizer sees.
- **About tab** with the version, developer, GitHub and issue links, and license.
- New actions for buttons and gestures: next / previous / new / close / reopen tab, refresh,
  open link in new tab, copy, paste, new, open, save, quit, minimize, maximize, maximize
  left / right (walking across displays), move / resize window, Show Desktop, move a space
  left / right, launch Finder and launch the default browser.

### Changed
- Preferences now has four tabs: **Mouse**, **Keyboard Cursor**, **Touch** and **About**.
- Action pickers are grouped by kind.
- Clicks and scrolls pass through the event tap only while touch gestures are on.

### Fixed
- **The built-in keyboard and trackpad are no longer detected as a mouse.** A MacBook's
  internal keyboard / trackpad reports the HID Mouse usage, so with no mouse attached it was
  shown as the detected device and given the generic button profile. Built-in devices,
  trackpads and keyboards are now skipped, and `--list-devices` marks them as ignored.
- **Universal binary.** Recent toolchains put every `swift build` in the same output
  directory whatever `--arch` asks for, so the Intel build overwrote the Apple silicon one
  and `build-app.sh` shipped an Intel-only app. Each architecture now builds in its own
  scratch path, and the script checks what it got before merging.
- A retain cycle in the Characters preference pane kept the character list and its views
  alive for the life of the process.
- A long drawing thins its path instead of growing without limit, bounding both memory and
  recognition cost while keeping the shape.
- The overlay no longer resizes its window and rewrites layer scales on every frame of a
  stroke, and scroll events check a cached flag instead of walking the recognizers.

### Security
- The single-instance lock file moved from `/tmp` to the per-user temporary directory, kept
  at `0600`. Any account on the machine could create and hold the old path, which would stop
  the daemon from ever starting.
- Finger data from `MultitouchSupport` is checked before use: a finger count beyond what any
  hand has is rejected rather than walked, and coordinates must be finite and on the surface.
- The private frameworks the app loads are no longer unloaded on teardown, since they run
  their own callback threads.

## [0.2.0] - 2026-09-12

### Added
- **Device auto-detection.** The attached mouse is identified over IOKit and its button
  profile applied automatically. Logitech MX Master 4 and MX Master 3 / 3S are recognised
  by HID product string, with a product-ID fallback so Bluetooth, Bolt and Unifying
  connections all match. Anything else gets a generic profile.
- **Per-device button mappings**, so switching mice no longer means remapping. Buttons
  `3`–`9` are now configurable, up from `3`–`6`.
- **Keyboard cursor control.** Hold `A` to drive the pointer: `IJKL` to move, `S` / `D` /
  `F` to click (hold `S` to drag), `Space` to scroll, `;` to lock, `Esc` to exit. `Shift`
  and `Shift`+`Ctrl` are speed tiers, `Option` is precision. Movement eases in and
  diagonals are normalised.
- Every cursor key and speed value is rebindable in Preferences.
- **Toggle Keyboard Cursor** as a mouse button action.
- Button tester in Preferences, which reports the number of whichever button you press.
- Input Monitoring warning in the status menu, alongside the existing Accessibility one.
- `--list-devices` flag for diagnosing detection.
- **Universal binary**, so the app runs on Intel Macs as well as Apple silicon.
- Unit tests covering device matching, the movement curve, screen clamping and the
  activation state machine.

### Changed
- Preferences is now a two-tab window: **Mouse** and **Keyboard Cursor**.
- The status bar icon changes while cursor mode is engaged.
- Without Accessibility permission the app no longer quits silently. It stays in the menu
  bar with a warning icon and starts working as soon as the permission is granted.
- Local builds are signed with a Developer ID identity when one is available, so
  permissions survive rebuilds.
- `main.swift` split into focused files, with the pure logic moved to a new
  `MouseNavigateCore` library target.

### Notes
- The activation key is withheld rather than swallowed: cursor mode engages only if it is
  still held after the delay, so typing rolls like `as` and shortcuts like `⌘A` are
  unaffected.

## [0.1.0] - 2026-04-06

### Added
- Global mouse side-button support for Logitech MX4.
- Safari/Finder back/forward mapping:
  - Button `3` -> `⌘ + [`
  - Button `4` -> `⌘ + ]`
- System action mapping:
  - Button `5` -> App Exposé
  - Button `6` -> Mission Control
- Single-instance behavior with popup prompt and quit-running-instance action.
- Low-memory launcher/daemon runtime architecture.
- App bundle packaging script (`scripts/build-app.sh`) with icon generation.
- Optional stable code signing support via `SIGN_IDENTITY`.
