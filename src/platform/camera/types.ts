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

export type PreviewOptions = {
  quality: CameraQuality;
  facing: CameraFacing;
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
};
