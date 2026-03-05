# zet-ssh

A stripped-down, desktop-first Flutter terminal emulator.

## Target
- Linux

## Run
```bash
flutter pub get
flutter run -d linux
```

## Build
```bash
flutter build linux
```

## Optional Debug Logs
Debug logs are off by default.

Enable them with env var:
```bash
ZET_SSH_DEBUG_KEYS=1 ./build/linux/x64/release/bundle/zet_ssh
```

Or with Flutter define:
```bash
flutter run -d linux --dart-define=ZET_SSH_DEBUG_KEYS=true
```
