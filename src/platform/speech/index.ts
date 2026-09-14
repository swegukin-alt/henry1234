// Voice-follow speech recognition.
//
// The teleprompter's scrolling engine must never be bolted to one recognition
// API. Today the working implementation streams short audio windows to the
// app's own transcription endpoint (`src/lib/voice-follow-v2.ts` →
// /api/public/transcribe), which behaves identically in Safari and inside a
// Capacitor WebView. On iOS, on-device SFSpeechRecognizer would be faster and
// work offline, but it needs a small Swift plugin — documented, not faked.

import { hasPlugin, isNative } from "../runtime";

export type SpeechMode = "server-window" | "browser-native" | "ios-native";

export type SpeechCapabilities = {
  mode: SpeechMode;
  onDevice: boolean;
  worksOffline: boolean;
  supportsKorean: boolean;
  requiresNetwork: boolean;
};

export function speechCapabilities(): SpeechCapabilities {
  if (isNative() && hasPlugin("SpeechRecognition")) {
    return {
      mode: "ios-native",
      onDevice: true,
      worksOffline: true,
      supportsKorean: true,
      requiresNetwork: false,
    };
  }
  // The browser recognizer is unreliable on iOS (and absent for Korean), so
  // the server window path is the honest answer everywhere today.
  return {
    mode: "server-window",
    onDevice: false,
    worksOffline: false,
    supportsKorean: true,
    requiresNetwork: true,
  };
}
