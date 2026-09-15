# Match the native teleprompter to the web screen

## Changes
- Make video mode use the same full-screen camera treatment as the web app, including an unmistakable 45% black overlay above the preview.
- Keep the front-camera preview mirrored like a selfie while keeping the rolling script completely unflipped in video mode, regardless of saved beam-splitter settings.
- Lock the rolling script to white Pretendard-style Korean-readable typography, matching the web font size, weight, 1.5 line spacing, width, wrapping, tracking, and 20% opening space.
- Reproduce the web top indicators, 2px progress line, bottom black toolbar, icon order, dimensions, colors, opacity, and popover placement.
- Size and inset the native layout specifically for the iPhone 16 Pro Max in portrait and landscape using native safe areas, without changing the web app or native camera architecture.
- Prevent reading highlight from turning normal script text blue; any enabled highlight will remain subtle while all ordinary rolling text stays white.

## Verification
- Review all mirror transforms so video mode can never flip the script or controls.
- Check portrait and landscape geometry against iPhone 16 Pro Max dimensions.
- Run the available project checks and inspect the final Swift sources for compile-safe APIs.

## Technical details
- Changes are limited to the native SwiftUI presentation layer and typography rendering under `ios-native/`.
- Camera capture, recording, storage, permissions, signing, and the existing web application remain unchanged.
