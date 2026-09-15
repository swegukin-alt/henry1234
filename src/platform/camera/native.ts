// iOS camera.
//
// Two native back-ends, in order of preference:
//
//  1. `TeleprompterCapture` — the small custom Swift/AVFoundation plugin in
//     `ios-plugin/TeleprompterCapture`. It is the only back-end that gives us
//     everything continuous teleprompter recording needs: chosen bitrate and
//     resolution, live recording state and duration, interruption events, audio
//     route control, zoom/torch, and a file path we own.
//  2. `@capacitor-community/camera-preview` — a real AVFoundation preview layer
//     behind the WebView with start/stop video recording. Enough to film, but
//     it cannot report duration, cannot set bitrate, and its `stopRecordVideo`
//     never resolves on iOS (the file URL arrives on the `startRecordVideo`
//     promise instead), so we drive it defensively.
//
// There is no browser fallback here on purpose. Inside the app the camera is
// native or it fails visibly — it never quietly reverts to getUserMedia.

import { noteImpl } from "../runtime";
import { captureProbeError, loadModule, PLUGIN_MODULES, probeCapturePlugin } from "../native-plugins";
import { fail, ok } from "../types";
import type {
  CameraCapabilities,
  CameraQuality,
  CameraService,
  PreviewHandle,
  RecordingHandle,
  StabilizationMode,
} from "./types";

type PreviewPlugin = {
  start: (o: Record<string, unknown>) => Promise<void>;
  stop: () => Promise<void>;
  flip: () => Promise<void>;
  startRecordVideo: (o: Record<string, unknown>) => Promise<{ value?: string } | void>;
  stopRecordVideo: () => Promise<{ videoFilePath?: string } | void>;
  isCameraStarted: () => Promise<{ value: boolean }>;
};

type CaptureResult = {
  path: string;
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
let preview: PreviewPlugin | null = null;
let backEnd: "custom" | "camera-preview" | "none" = "none";

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
  } else {
    lastResolveError = captureProbeError();
    const mod = await loadModule<{ CameraPreview?: PreviewPlugin }>(PLUGIN_MODULES.cameraPreview);
    if (mod?.CameraPreview) {
      try {
        await mod.CameraPreview.isCameraStarted();
        preview = mod.CameraPreview;
        backEnd = "camera-preview";
      } catch (e) {
        lastResolveError += ` CameraPreview: ${(e as { message?: string })?.message || "not installed"}.`;
      }
    }
  }
  noteImpl("camera", backEnd === "none" ? "native (no plugin)" : `native (${backEnd})`);
  return backEnd;
}

/** What is genuinely missing without the custom plugin — never hidden from the UI. */
export function nativeCameraBackEnd(): typeof backEnd {
  return backEnd;
}

const missing =
  "The native camera plugin (TeleprompterCapture) did not answer. Check that both Swift files are in the Xcode App target, then rebuild.";

export const nativeCamera: CameraService = {
  name: "camera.ios",
  // Inside the app the camera is always the native one; a missing plugin
  // surfaces as a visible error from startPreview, never as a browser fallback.
  available: () => true,

  capabilities(): CameraCapabilities {
    const full = backEnd === "custom";
    return {
      supportsZoom: backEnd !== "none",
      // Focus, exposure, lens choice, 4K, 60 fps and stabilisation are only
      // reachable through the custom AVFoundation plugin. camera-preview does
      // not expose them and we do not claim them.
      supportsFocus: full,
      supportsExposure: full,
      supportsLensSelection: full,
      supports4K: full,
      supports60fps: full,
      supportsStabilization: full,
      supportsTorch: backEnd !== "none",
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
        resolutions: (r.resolutions ?? ["1080p"]) as CameraQuality[],
        frameRates: r.frameRates ?? [30],
        hdr: !!r.hdr,
        stabilization: (r.stabilization ?? ["off"]) as StabilizationMode[],
        maxZoom: r.maxZoom ?? 1,
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
      if (be === "custom") {
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
      }
      await preview!.start({
        position: facing === "front" ? "front" : "rear",
        // The teleprompter HTML must stay readable on top of the camera layer.
        toBack: true,
        width: typeof window === "undefined" ? dims.width : window.screen.width,
        height: typeof window === "undefined" ? dims.height : window.screen.height,
        enableHighResolution: quality === "4k",
        enableZoom: true,
        disableAudio: false,
        rotateWhenOrientationChanged: true,
      });
      return ok({ stream: null, width: dims.width, height: dims.height });
    } catch (e) {
      return fail(
        (e as { message?: string })?.message ||
          "The camera could not start. Check the camera permission in iOS Settings.",
      );
    }
  },

  async stopPreview() {
    try {
      if (backEnd === "custom") await custom?.stopPreview();
      else await preview?.stop();
    } catch {
      /* already down */
    }
  },

  async switchCamera(_handle: PreviewHandle, facing) {
    const be = await resolveBackEnd();
    if (be === "none") return fail(missing, "plugin-missing");
    try {
      if (be === "custom") await custom!.flip({ position: facing === "front" ? "front" : "rear" });
      else await preview!.flip();
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
          videoBitrate: opts.videoBitsPerSecond,
          audioBitrate: opts.audioBitsPerSecond,
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
          return { mimeType: res.mimeType || "video/mp4", filePath: res.path };
        },
      };
      return ok(handle);
    }

    // camera-preview: the file URL is delivered on the START promise when the
    // recording finishes, and stopRecordVideo() resolves nothing. Keep the
    // start promise and treat it as the result of stop.
    let settled: string | null = null;
    let failure: unknown = null;
    const filePromise = Promise.resolve(preview!.startRecordVideo({}))
      .then((r) => {
        settled = (r as { value?: string } | undefined)?.value ?? null;
        return settled;
      })
      .catch((e) => {
        failure = e;
        return null;
      });
    // A rejection in the first moments means recording never began.
    await new Promise((r) => setTimeout(r, 60));
    if (failure) {
      return fail((failure as { message?: string })?.message || "Recording could not start.");
    }

    const handle: RecordingHandle = {
      output: "native-file",
      onChunk: () => {},
      onError: () => {},
      requestData: () => {},
      state: () => (settled ? "inactive" : "recording"),
      stop: async () => {
        let direct: string | null = null;
        try {
          const r = (await Promise.race([
            preview!.stopRecordVideo(),
            new Promise((res) => setTimeout(() => res(undefined), 4000)),
          ])) as { videoFilePath?: string } | undefined;
          direct = r?.videoFilePath ?? null;
        } catch {
          /* the plugin does not resolve this call on iOS */
        }
        const path = direct ?? (await Promise.race([
          filePromise,
          new Promise<string | null>((res) => setTimeout(() => res(null), 15000)),
        ]));
        if (!path) throw new Error("The recording finished but iOS did not return the file.");
        return { mimeType: "video/mp4", filePath: path };
      },
    };
    return ok(handle);
  },
};
