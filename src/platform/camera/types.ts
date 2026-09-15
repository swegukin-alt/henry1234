import type { PlatformService, ServiceResult } from "../types";

export type CameraFacing = "front" | "back";
export type CameraQuality = "720p" | "1080p" | "4k";

/**
 * What this runtime can genuinely do. Never claim a capability a plugin does
 * not expose — the UI hides controls it cannot honour.
 */
export type CameraCapabilities = {
  supportsZoom: boolean;
  supportsFocus: boolean;
  supportsExposure: boolean;
  supportsLensSelection: boolean;
  supports4K: boolean;
  supports60fps: boolean;
  supportsStabilization: boolean;
  supportsTorch: boolean;
  /**
   * "stream": the preview is a MediaStream rendered into a <video> element.
   * "native-surface": a native camera layer sits behind the WebView and the
   * HTML must stay transparent above it.
   */
  previewMode: "stream" | "native-surface";
  /** "media-recorder" gives us live chunks; "native-file" gives a file path at stop. */
  recordingOutput: "media-recorder" | "native-file";
};

export type StabilizationMode = "off" | "standard" | "cinematic" | "auto";

export type PreviewOptions = {
  quality: CameraQuality;
  facing: CameraFacing;
  /** Capture frame rate. 30 or 60 on iPhone; a preference on the web. */
  fps?: number;
  /** 10-bit HDR (Dolby Vision) capture where the device format supports it. */
  hdr?: boolean;
  stabilization?: StabilizationMode;
};

/**
 * What THIS device's camera can actually do, read from the hardware formats.
 * Only the native plugin can answer honestly; the web reports what the track
 * capabilities expose.
 */
export type CameraDeviceCapabilities = {
  resolutions: CameraQuality[];
  /** Frame rates available at the currently chosen resolution. */
  frameRates: number[];
  hdr: boolean;
  stabilization: StabilizationMode[];
  maxZoom: number;
  /** Valid combinations reported by AVCaptureDevice.Format on this camera. */
  modes: Array<{
    quality: CameraQuality;
    width: number;
    height: number;
    fps: number;
    hdr: boolean;
    stabilization: StabilizationMode[];
  }>;
};

export type PreviewHandle = {
  /** Present only in "stream" mode. */
  stream: MediaStream | null;
  /** Actual negotiated size, when the runtime reports it. */
  width: number;
  height: number;
};

export type RecorderOptions = {
  mimeType?: string;
  videoBitsPerSecond: number;
  audioBitsPerSecond: number;
  timesliceMs: number;
  /** Native only: stable filename for the one on-disk take. */
  recordingId?: string;
};

/** A recording handle shaped so both MediaRecorder and a native file recorder fit. */
export type RecordingHandle = {
  readonly output: "media-recorder" | "native-file";
  /** Live chunks (web). Native file recording delivers nothing here. */
  onChunk: (cb: (chunk: Blob) => void) => void;
  onError: (cb: (err: unknown) => void) => void;
  requestData: () => void;
  stop: () => Promise<{ mimeType: string; filePath?: string }>;
  state: () => "inactive" | "recording" | "paused";
};

export type CameraService = PlatformService & {
  capabilities: () => CameraCapabilities;
  startPreview: (opts: PreviewOptions) => Promise<ServiceResult<PreviewHandle>>;
  stopPreview: (handle: PreviewHandle | null) => Promise<void>;
  switchCamera: (handle: PreviewHandle, facing: CameraFacing) => Promise<ServiceResult<PreviewHandle>>;
  setZoom: (handle: PreviewHandle, zoom: number) => Promise<ServiceResult<void>>;
  startRecording: (
    handle: PreviewHandle,
    opts: RecorderOptions,
  ) => Promise<ServiceResult<RecordingHandle>>;
  /** Hardware format report. null when the runtime cannot answer truthfully. */
  deviceCapabilities?: () => Promise<CameraDeviceCapabilities | null>;
};
