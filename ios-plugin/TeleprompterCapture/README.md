# TeleprompterCapture — custom Capacitor plugin (iOS)

This is the small Swift/AVFoundation plugin the teleprompter needs for the
things no off-the-shelf Capacitor plugin exposes:

| Capability | `@capacitor-community/camera-preview` | TeleprompterCapture |
| --- | --- | --- |
| Live preview behind the WebView | yes | yes |
| Record video + audio to a file | yes | yes |
| Recording state and live duration | no | yes |
| Chosen bitrate / resolution / 60 fps | no | yes |
| Stop returns the file path reliably | no (`stopRecordVideo` never resolves on iOS) | yes |
| Camera / microphone permission state | no | yes |
| Microphone selection (built-in, wired, USB-C, DJI, AirPods) | no | yes |
| Audio route changes and interruptions (call, Siri) | no | yes |
| Zoom, focus, exposure, torch, stabilization | zoom/torch only | yes |

The app works with either back-end: if TeleprompterCapture is registered it is
used, otherwise camera-preview is used with the limitations above reported
truthfully in `/diagnostics`. The app never falls back to the browser camera on
iOS.

## Adding it to the Xcode project

1. `bun run build:ios && npx cap add ios && npx cap sync ios`
2. In Xcode, drag `ios-plugin/TeleprompterCapture/TeleprompterCapture.swift` and
   `TeleprompterCapturePlugin.swift` into the `App` target (Create folder
   references off, Copy items on).
3. Build. Capacitor registers the plugin automatically through
   `CAP_PLUGIN`; the JavaScript side reaches it with
   `registerPlugin("TeleprompterCapture")` — no npm package required.

## Info.plist keys

```xml
<key>NSCameraUsageDescription</key>
<string>The teleprompter films you while you read your script.</string>
<key>NSMicrophoneUsageDescription</key>
<string>Your voice is recorded with the video, including an external microphone.</string>
<key>NSPhotoLibraryAddUsageDescription</key>
<string>Saves a finished take to your photo library.</string>
<key>NSPhotoLibraryUsageDescription</key>
<string>Lets you save and pick takes in your photo library.</string>
```

Speech recognition (`NSSpeechRecognitionUsageDescription`) is only needed if
native voice-follow is adopted later; today voice-follow is web-only.
