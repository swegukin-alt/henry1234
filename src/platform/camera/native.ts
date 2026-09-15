// iOS camera.
//
// One native back-end:
//
//  `TeleprompterCapture` — the small custom Swift/AVFoundation plugin in
//     `ios-plugin/TeleprompterCapture`. It is the only back-end that gives us
//     everything continuous teleprompter recording needs: chosen bitrate and
//     resolution, live recording state and duration, interruption events, audio
//     route control, zoom/torch, and a file path we own.
// There is no browser fallback here on purpose. Inside the app the camera is
// TeleprompterCapture or it fails visibly. The generic camera-preview plugin is
// deliberately not a recording fallback because it cannot honor device modes
// or return a finished long recording reliably.

import { noteImpl } from "../runtime";
import { captureProbeError, probeCapturePlugin } from "../native-plugins";
import { fail, ok } from "../types";
import type {
  CameraCapabilities,
  CameraQuality,
  CameraService,
  PreviewHandle,
  RecordingHandle,
  StabilizationMode,
} from "./types";

type CaptureResult = {
  path: string;
  relativePath?: string;
  mimeType?: string;
  durationMs?: number;
  width?: number;
  height?: number;
};

type CapturePlugin = {
  startPreview: (o: Record<string, unknown>) => Promise<{ width?: number; height?: number }>;
  stopPreview: () => Promise<void>;
  flip: (o?: Record<string, unknown>) => Promise<void>;
  setZoom: (o: { zoom: number }) => Promise<void>;
  startRecording: (o: Record<string, unknown>) => Promise<void>;
  deviceCapabilities?: (o?: Record<string, unknown>) => Promise<{
    resolutions?: string[];
    frameRates?: number[];
    hdr?: boolean;
    stabilization?: string[];
    maxZoom?: number;
    modes?: Array<{
      quality: CameraQuality;
      width: number;
      height: number;
      fps: number;
      hdr: boolean;
      stabilization: StabilizationMode[];
    }>;
  }>;
  stopRecording: () => Promise<CaptureResult>;
  recordingState: () => Promise<{ state: "inactive" | "recording"; durationMs: number }>;
};

const DIMS = {
  "4k": { width: 3840, height: 2160 },
  "1080p": { width: 1920, height: 1080 },
  "720p": { width: 1280, height: 720 },
} as const;

let custom: CapturePlugin | null = null;
let backEnd: "custom" | "none" = "none";

let lastResolveError = "";

/** Plain-language detail about why the native camera is (not) there. */
export function nativeCameraDetail(): string {
  return lastResolveError;
}

async function resolveBackEnd(): Promise<typeof backEnd> {
  if (backEnd !== "none") return backEnd;
  // The custom Swift plugin is always tried for real rather than trusted to a
  // registry flag, which can be empty for a plugin built into the app target.
  custom = await probeCapturePlugin<CapturePlugin>();
  if (custom) {
    backEnd = "custom";
    lastResolveError = "";
  } else lastResolveError = captureProbeError();
  noteImpl("camera", backEnd === "none" ? "native (no plugin)" : `native (${backEnd})`);
  return backEnd;
}

/** What is genuinely missing without the custom plugin — never hidden from the UI. */
export function nativeCameraBackEnd(): typeof backEnd {
  return backEnd;
}

const missing =
  "The native camera plugin is not registered. Add all three TeleprompterCapture Swift files and set the storyboard Bridge View Controller class to TeleprompterViewController.";

export const nativeCamera: CameraService = {
  name: "camera.ios",
  // Inside the app the camera is always the native one; a missing plugin
  // surfaces as a visible error from startPreview, never as a browser fallback.
  available: () => true,

  capabilities(): CameraCapabilities {
    const full = backEnd === "custom";
    return {
      supportsZoom: full,
      // Focus, exposure, lens choice, 4K, 60 fps and stabilisation are only
      // reachable through the custom AVFoundation plugin. camera-preview does
      // not expose them and we do not claim them.
      supportsFocus: full,
      supportsExposure: full,
      supportsLensSelection: full,
      supports4K: full,
      supports60fps: full,
      supportsStabilization: full,
      supportsTorch: full,
      previewMode: "native-surface",
      recordingOutput: "native-file",
    };
  },

  async deviceCapabilities() {
    const be = await resolveBackEnd();
    if (be !== "custom" || !custom?.deviceCapabilities) return null;
    try {
      const r = await custom.deviceCapabilities();
      return {
        resolutions: (r.resolutions ?? []) as CameraQuality[],
        frameRates: r.frameRates ?? [],
        hdr: !!r.hdr,
        stabilization: (r.stabilization ?? []) as StabilizationMode[],
        maxZoom: r.maxZoom ?? 1,
        modes: r.modes ?? [],
      };
    } catch {
      return null;
    }
  },

  async startPreview({ quality, facing, fps, hdr, stabilization }) {
    const be = await resolveBackEnd();
    if (be === "none") return fail(`${missing}${lastResolveError ? ` (${lastResolveError})` : ""}`, "plugin-missing");
    const dims = DIMS[quality] ?? DIMS["1080p"];
    try {
      const res = await custom!.startPreview({
        position: facing === "front" ? "front" : "rear",
        quality,
        width: dims.width,
        height: dims.height,
        fps: fps ?? 30,
        hdr: !!hdr,
        stabilization: stabilization ?? "auto",
      });
      return ok({ stream: null, width: res.width ?? dims.width, height: res.height ?? dims.height });
    } catch (e) {
      return fail(
        (e as { message?: string })?.message ||
          "The camera could not start. Check the camera permission in iOS Settings.",
      );
    }
  },

  async stopPreview() {
    try {
      await custom?.stopPreview();
    } catch {
      /* already down */
    }
  },

  async switchCamera(_handle: PreviewHandle, facing) {
    const be = await resolveBackEnd();
    if (be === "none") return fail(missing, "plugin-missing");
    try {
      await custom!.flip({ position: facing === "front" ? "front" : "rear" });
      return ok({ stream: null, width: 0, height: 0 });
    } catch (e) {
      return fail((e as { message?: string })?.message || "The camera could not be switched.");
    }
  },

  async setZoom(_handle, zoom) {
    if (backEnd === "custom") {
      try {
        await custom!.setZoom({ zoom });
        return ok(undefined);
      } catch {
        return fail("This camera refused the zoom level.");
      }
    }
    return fail("Zoom needs the custom camera plugin on iOS.", "unsupported");
  },

  async startRecording(_handle, opts) {
    const be = await resolveBackEnd();
    if (be === "none") return fail(missing, "plugin-missing");

    if (be === "custom") {
      try {
        await custom!.startRecording({
          recordingId: opts.recordingId,
        });
      } catch (e) {
        return fail((e as { message?: string })?.message || "Recording could not start.");
      }
      const handle: RecordingHandle = {
        output: "native-file",
        onChunk: () => {
          /* the file is written by iOS; there are no chunks to hand over */
        },
        onError: () => {
          /* interruptions arrive through the audio/lifecycle services */
        },
        requestData: () => {},
        state: () => "recording",
        stop: async () => {
          const res = await custom!.stopRecording();
          return { mimeType: res.mimeType || "video/quicktime", filePath: res.relativePath || res.path };
        },
      };
      return ok(handle);
    }

    return fail(missing, "plugin-missing");
  },
};
