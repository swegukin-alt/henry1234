# Fix native iPhone camera and teleprompter

## Changes
- Expose the iPhone camera’s real supported recording modes before and during video mode, with clear quality, frame-rate, HDR, stabilization, and front/back controls.
- Correct the front-camera device/format selection so preview framing starts at the physical wide view, uses continuous autofocus/exposure, and does not inherit digital zoom.
- Keep the web-matched bottom controls permanently visible above the iPhone safe area in portrait and landscape.
- Remove per-frame SwiftUI layout work from script scrolling so long scripts move smoothly while the camera is running.
- Preserve the web app and all native recording/storage architecture.

## Validation
- Check the complete native source for compile issues and forbidden web-runtime dependencies.
- Run any available native project validation; physical camera and focus verification remains on the iPhone through Xcode.
