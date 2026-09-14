// Native iOS camera.
//
// Target: @capacitor-community/camera-preview, which renders a real AVFoundation
// preview layer BEHIND the WebView so the teleprompter HTML stays readable on
// top of it. Until that package is installed and synced on the Mac, this
// service reports itself unavailable and the browser implementation is used —
// it never pretends a recording started.

import { hasPlugin } from "../runtime";
import { fail } from "../types";
import type { CameraCapabilities, CameraService } from "./types";

const PLUGIN = "CameraPreview";
const unavailable = "The native camera plugin is not installed in this build.";

export const nativeCamera: CameraService = {
  name: "camera.ios",
  available: () => hasPlugin(PLUGIN),

  capabilities(): CameraCapabilities {
    // What camera-preview genuinely exposes today. Focus, exposure, lens
    // selection and stabilisation need a small custom Swift/AVFoundation
    // plugin — see NATIVE_READINESS.md.
    return {
      supportsZoom: true,
      supportsFocus: false,
      supportsExposure: false,
      supportsLensSelection: false,
      supports4K: false,
      supports60fps: false,
      supportsStabilization: false,
      supportsTorch: true,
      previewMode: "native-surface",
      recordingOutput: "native-file",
    };
  },

  async startPreview() {
    return fail(unavailable, "plugin-missing");
  },
  async stopPreview() {
    /* nothing running */
  },
  async switchCamera() {
    return fail(unavailable, "plugin-missing");
  },
  async setZoom() {
    return fail(unavailable, "plugin-missing");
  },
  async startRecording() {
    return fail(unavailable, "plugin-missing");
  },
};
