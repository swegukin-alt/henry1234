// What each feature is ACTUALLY running on right now.
//
// Used by the dev-only /diagnostics page. Critical features (camera, video
// recording, microphone, recording storage) must be native inside the app; if
// one of them is not, it is flagged as an unexpected fallback rather than
// quietly working in the WebView.

import { hasPlugin, isNative } from "./runtime";
import { cameraService } from "./camera";
import { audioService } from "./audio";
import { mediaStore } from "./storage/media-store";
import { nativeCameraBackEnd } from "./camera/native";
import { mediaLibraryCapabilities } from "./media-library";
import { shareCapabilities } from "./share";
import { keepAwakeSupported } from "./keep-awake";
import { orientationSupport } from "./orientation";
import { hapticsSupported } from "./haptics";

export type ImplRow = {
  feature: string;
  impl: string;
  critical: boolean;
  /** True when the app is native but this feature is not. */
  fallback: boolean;
};

export async function implementationReport(): Promise<ImplRow[]> {
  const native = isNative();
  const cam = await cameraService();
  const caps = cam.capabilities();
  const audio = await audioService();
  const store = await mediaStore();
  const backEnd = native ? nativeCameraBackEnd() : "web";

  const row = (feature: string, impl: string, isNativeImpl: boolean, critical = false): ImplRow => ({
    feature,
    impl,
    critical,
    fallback: native && !isNativeImpl,
  });

  return [
    row(
      "Camera preview",
      native ? `native (${backEnd})` : "web (getUserMedia)",
      caps.previewMode === "native-surface",
      true,
    ),
    row(
      "Video recorder",
      caps.recordingOutput === "native-file" ? "native file output" : "web (MediaRecorder)",
      caps.recordingOutput === "native-file",
      true,
    ),
    row(
      "Recording microphone",
      audio.name === "audio.ios" ? "native capture session" : "web (getUserMedia)",
      audio.name === "audio.ios",
      true,
    ),
    row(
      "Recording storage",
      store.kind === "native-filesystem" ? "native files (@capacitor/filesystem)" : "web (IndexedDB)",
      store.kind === "native-filesystem",
      true,
    ),
    row(
      "Save to Photos",
      native && mediaLibraryCapabilities().canSaveToPhotos ? "native (@capacitor-community/media)" : "web (share sheet / download)",
      native && mediaLibraryCapabilities().canSaveToPhotos,
    ),
    row(
      "Share",
      native && hasPlugin("Share") ? "native (@capacitor/share)" : "web (navigator.share)",
      native && hasPlugin("Share"),
    ),
    row(
      "Preferences",
      native && hasPlugin("Preferences") ? "native (@capacitor/preferences)" : "web (localStorage)",
      native && hasPlugin("Preferences"),
    ),
    row(
      "Keep awake",
      native && hasPlugin("KeepAwake") ? "native (keep-awake plugin)" : keepAwakeSupported() ? "web (wake lock)" : "unavailable",
      native && hasPlugin("KeepAwake"),
    ),
    row(
      "Orientation",
      native && hasPlugin("ScreenOrientation") ? "native (@capacitor/screen-orientation)" : orientationSupport().canLock ? "web (screen.orientation)" : "read-only",
      native && hasPlugin("ScreenOrientation"),
    ),
    row(
      "Lifecycle",
      native && hasPlugin("App") ? "native (@capacitor/app)" : "web (visibilitychange)",
      native && hasPlugin("App"),
    ),
    row(
      "Haptics",
      native && hasPlugin("Haptics") ? "native (@capacitor/haptics)" : hapticsSupported() ? "web (vibrate)" : "none",
      native && hasPlugin("Haptics"),
    ),
    row("Voice follow", "web capture + server transcription", false),
    row("Remote control", "keyboard/HID events (identical on both)", false),
    // Share and Photos legitimately use the browser path on the website.
  ];
}
