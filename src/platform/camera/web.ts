// Browser camera: exactly the getUserMedia / MediaRecorder behaviour the
// teleprompter already relies on, moved behind the service interface.

import { fail, ok } from "../types";
import type {
  CameraCapabilities,
  CameraQuality,
  CameraService,
  PreviewHandle,
  RecordingHandle,
} from "./types";

const DIMS: Record<CameraQuality, { width: number; height: number }> = {
  "4k": { width: 3840, height: 2160 },
  "1080p": { width: 1920, height: 1080 },
  "720p": { width: 1280, height: 720 },
};

function constraintsFor(q: CameraQuality, facing: "front" | "back"): MediaStreamConstraints {
  const dims = DIMS[q];
  return {
    // Every value is a preference, never a requirement: one unsatisfiable
    // requirement makes the whole camera fail to open.
    video: {
      facingMode: { ideal: facing === "front" ? "user" : "environment" },
      width: { ideal: dims.width },
      height: { ideal: dims.height },
      frameRate: { ideal: 60 },
    } as MediaTrackConstraints,
    audio: {
      echoCancellation: true,
      noiseSuppression: true,
      autoGainControl: true,
      sampleRate: { ideal: 48000 },
      channelCount: { ideal: 2 },
    } as MediaTrackConstraints,
  };
}

function trackCaps(stream: MediaStream | null): MediaTrackCapabilities | null {
  const track = stream?.getVideoTracks()[0];
  try {
    return track?.getCapabilities?.() ?? null;
  } catch {
    return null;
  }
}

export function pickRecorderMime(): string {
  const candidates = [
    "video/mp4;codecs=h264,mp4a.40.2",
    "video/mp4",
    "video/webm;codecs=h264,opus",
    "video/webm;codecs=vp9,opus",
    "video/webm",
  ];
  for (const m of candidates) {
    if (typeof MediaRecorder !== "undefined" && MediaRecorder.isTypeSupported(m)) return m;
  }
  return "";
}

let lastCaps: MediaTrackCapabilities | null = null;

export const webCamera: CameraService = {
  name: "camera.web",
  available: () => typeof navigator !== "undefined" && !!navigator.mediaDevices?.getUserMedia,

  capabilities(): CameraCapabilities {
    const caps = lastCaps as (MediaTrackCapabilities & Record<string, unknown>) | null;
    return {
      // Browser capabilities are only knowable once a track exists; before
      // that we report the conservative truth.
      supportsZoom: !!caps && "zoom" in caps,
      supportsFocus: !!caps && "focusMode" in caps,
      supportsExposure: !!caps && "exposureMode" in caps,
      supportsLensSelection: false,
      supports4K: !!caps?.height && Number(caps.height.max) >= 2160,
      supports60fps: !!caps?.frameRate && Number(caps.frameRate.max) >= 60,
      supportsStabilization: false,
      supportsTorch: !!caps && "torch" in caps,
      previewMode: "stream",
      recordingOutput: "media-recorder",
    };
  },

  async startPreview({ quality, facing }) {
    if (!navigator.mediaDevices?.getUserMedia) return fail("This browser has no camera access.");
    const tiers: CameraQuality[] =
      quality === "4k" ? ["4k", "1080p", "720p"] : quality === "1080p" ? ["1080p", "720p"] : ["720p"];
    const attempts: MediaStreamConstraints[] = [
      ...tiers.map((t) => constraintsFor(t, facing)),
      { video: { facingMode: { ideal: facing === "front" ? "user" : "environment" } }, audio: true },
      { video: true, audio: true },
    ];
    let stream: MediaStream | null = null;
    let lastErr: unknown = null;
    for (const c of attempts) {
      try {
        stream = await navigator.mediaDevices.getUserMedia(c);
        break;
      } catch (e) {
        lastErr = e;
      }
    }
    if (!stream) {
      return fail(
        (lastErr as { message?: string })?.message ||
          "Camera unavailable. Check Settings → Safari → Camera.",
      );
    }
    lastCaps = trackCaps(stream);
    const s = stream.getVideoTracks()[0]?.getSettings?.() ?? {};
    return ok({ stream, width: Number(s.width) || 0, height: Number(s.height) || 0 });
  },

  async stopPreview(handle) {
    handle?.stream?.getTracks().forEach((t) => {
      try {
        t.stop();
      } catch {
        /* already gone */
      }
    });
  },

  async switchCamera(handle, facing) {
    await this.stopPreview(handle);
    return this.startPreview({ quality: "1080p", facing });
  },

  async setZoom(handle, zoom) {
    const track = handle.stream?.getVideoTracks()[0];
    if (!track) return fail("No live camera to zoom.");
    try {
      await track.applyConstraints({ advanced: [{ zoom }] } as unknown as MediaTrackConstraints);
      return ok(undefined);
    } catch {
      return fail("This camera does not accept zoom from the browser.", "unsupported");
    }
  },

  async startRecording(handle, opts) {
    const stream = handle.stream;
    if (!stream) return fail("No live camera to record.");
    const mimeType = opts.mimeType ?? pickRecorderMime();
    let rec: MediaRecorder;
    try {
      rec = new MediaRecorder(
        stream,
        mimeType
          ? {
              mimeType,
              videoBitsPerSecond: opts.videoBitsPerSecond,
              audioBitsPerSecond: opts.audioBitsPerSecond,
            }
          : {
              videoBitsPerSecond: opts.videoBitsPerSecond,
              audioBitsPerSecond: opts.audioBitsPerSecond,
            },
      );
    } catch {
      try {
        rec = new MediaRecorder(stream);
      } catch {
        return fail("This browser can't record video. Open the app in Safari and try again.");
      }
    }

    const handleOut: RecordingHandle = {
      output: "media-recorder",
      onChunk: (cb) => {
        rec.ondataavailable = (e) => {
          if (e.data && e.data.size) cb(e.data);
        };
      },
      onError: (cb) => {
        rec.onerror = (e) => cb(e);
      },
      requestData: () => {
        try {
          if (rec.state === "recording") rec.requestData();
        } catch {
          /* nothing pending */
        }
      },
      state: () => rec.state,
      stop: () =>
        new Promise((resolve) => {
          const finish = () => resolve({ mimeType: rec.mimeType || mimeType || "video/mp4" });
          rec.onstop = finish;
          try {
            if (rec.state !== "inactive") rec.stop();
            else finish();
          } catch {
            finish();
          }
        }),
    };
    rec.start(opts.timesliceMs);
    return ok(handleOut);
  },
};
