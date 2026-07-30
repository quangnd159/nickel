# Nickel

Nickel is a native macOS menu-bar scratchpad app: a lightweight, always-available floating panel for quick notes, built with AppKit and SwiftUI on top of SwiftPM (no Xcode project required).

## Build & run

```bash
swift build                 # compile the SwiftPM executable
bash scripts/build-app.sh   # assemble build/Nickel.app and ad-hoc code-sign it
open build/Nickel.app       # launch
```
