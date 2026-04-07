# Contributing

Thanks for your interest in contributing.

## Prerequisites

- macOS 13+
- Swift toolchain from Xcode Command Line Tools
- A mouse that emits side-button events (MX4 preferred for current support)

## Development workflow

1. Build:
```bash
swift build
```

2. Run from source:
```bash
swift run
```

3. Build `.app` bundle:
```bash
./scripts/build-app.sh
```

4. Optional stable signing (recommended):
```bash
SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./scripts/build-app.sh
```

## Pull request guidance

- Keep changes focused and small.
- Update `README.md` if behavior changes.
- Update `CHANGELOG.md` for user-facing changes.
- Include reproduction and verification steps in PR description.

## Bug reports

Please include:
- macOS version
- Mouse model
- Logitech Options / Options+ button mappings
- Accessibility/Input Monitoring permission status
- Steps to reproduce
