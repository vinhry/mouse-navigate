# Changelog

All notable changes to this project will be documented in this file.

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
