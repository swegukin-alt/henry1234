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

The iPhone recording path requires TeleprompterCapture. It never falls back to
camera-preview or the browser camera: either the custom AVFoundation session is
live, or the app shows a visible native-camera error.

## Adding it to the Xcode project

1. `bun run build:ios && npx cap add ios && npx cap sync ios`
2. In Xcode, drag all three Swift files in this folder into the `App` target:
   `TeleprompterCapture.swift`, `TeleprompterCapturePlugin.swift`, and
   `TeleprompterViewController.swift` (Create folder
   references off, Copy items on).
3. Open `Base.lproj/Main.storyboard`, select **Bridge View Controller**, open
   Identity Inspector, and set its Custom Class to `TeleprompterViewController`
   with Module `App`. This is required: Capacitor 8 does not auto-register an
   app-local Swift plugin merely because its files are in the target.
4. Build. `TeleprompterViewController.capacitorDidLoad()` registers the native
   plugin instance; JavaScript reaches it with
   `registerPlugin("TeleprompterCapture")`.

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
