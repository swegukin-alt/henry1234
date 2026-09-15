# Restore exact web-app parity in the native iPhone app

## Goal
Make the separate SwiftUI iPhone app look and behave like the existing web app on every screen, while retaining native camera recording and limiting completed-video actions to **Save to camera roll** and **Share**.

## Implementation
1. **Fix complete long-script loading**
   - Remove any native text-layout or persistence path that truncates large scripts.
   - Preserve the complete script through editing, saving, reopening, scrolling, highlighting, and reading-position restoration.
   - Keep text layout memory-efficient so long scripts remain smooth.

2. **Match the web library and editor**
   - Reproduce the web app’s original black layout, branding, script list, title/body editor, settings placement, spacing, colors, and control sizes in SwiftUI.
   - Match the same defaults, ranges, labels, toggles, and enabled/disabled behavior.

3. **Match the web teleprompter exactly**
   - Preserve the approved Pretendard rolling-text typography, white text, Korean-safe wrapping, 1.5 line spacing, width, opening space, and subtle reading highlight.
   - Match the web camera scrim, indicators, progress line, toolbar order, equal button hit areas, sliders, popovers, tap-to-play, drag/seek behavior, mirror rules, speed, punctuation pacing, voice follow, remote controls, and orientation behavior.
   - Tune safe-area placement for iPhone 16 Pro Max portrait and landscape without changing the camera/recording architecture.

4. **Match clips while keeping native-only actions**
   - Reproduce the web clips list, titles, ordering, playback, and delete flow.
   - Keep only **Save to camera roll** and **Share** for completed recordings, using Apple’s native sheets.

5. **Validate the native project**
   - Check the entire `ios-native/` source for web-runtime dependencies and accidental truncation limits.
   - Run all available Swift/project validation here; document that final Apple compilation and physical-camera checks require Xcode on the iPhone-connected Mac.

## Boundaries
- Do not alter the existing web application.
- Do not alter native camera, recording, storage, signing, or permission architecture.
- Do not introduce WebView, Capacitor, React, JavaScript, browser storage, or duplicated iPhone UI.
