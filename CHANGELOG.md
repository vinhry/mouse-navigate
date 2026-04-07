# Changelog

All notable changes to this project will be documented in this file.

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
