# Swegukin Teleprompter — native iPhone app

A real Swift + SwiftUI iOS app. No WebView, no Capacitor, no JavaScript, no web build.
The web application in `src/` is untouched and keeps working as before.

## Open it on your Mac

```bash
cd ~/Developer/henry1234
git pull
open ios-native/SwegukinTeleprompter/SwegukinTeleprompter.xcodeproj
```

Then choose your iPhone and press Command + R.

No `bun install`, no `npx cap sync`, no dev server.

## One-time Xcode setup

1. Select the **SwegukinTeleprompter** target → **Signing & Capabilities**.
2. Team: your **Personal Team** (your Apple ID). Xcode will create the profile.
3. If the bundle identifier `com.swegukin.teleprompter` is taken, change it to
   something unique such as `com.yourname.teleprompter`.
4. On the iPhone: Settings → General → VPN & Device Management → trust your
   developer certificate (first install only).

Source files live in a *synchronized folder group*, so any Swift file added by
Lovable later appears in Xcode automatically after `git pull` — nothing to drag in.

Requires Xcode 16 or newer and iOS 17 or newer on the phone.

## Frameworks used

SwiftUI, UIKit, AVFoundation, AVKit, Photos, Speech, QuartzCore (CADisplayLink),
Foundation (FileManager, UserDefaults), CoreMedia.

No external Swift packages. No CocoaPods. No SPM dependencies.

## Permissions (already declared in build settings, generated into Info.plist)

- `NSCameraUsageDescription`
- `NSMicrophoneUsageDescription`
- `NSPhotoLibraryAddUsageDescription`
- `NSSpeechRecognitionUsageDescription`

Each one is requested the first time the relevant feature is used, never at launch.
