import { isNative, noteImpl, pickStrict } from "../runtime";
import { webCamera } from "./web";
import type { CameraFacing, CameraService, PreviewHandle, PreviewOptions, RecorderOptions } from "./types";

export type * from "./types";
export { pickRecorderMime } from "./web";

let resolved: Promise<CameraService> | null = null;

/**
 * The camera for this runtime. Inside the iPhone app this is ALWAYS the native
 * service — if its plugin is missing, its calls return a visible error instead
 * of quietly reopening getUserMedia.
 */
export function cameraService(): Promise<CameraService> {
  resolved ??= pickStrict(webCamera, async () => (await import("./native")).nativeCamera).then((svc) => {
    noteImpl("camera", isNative() ? "native" : "web (getUserMedia)");
    noteImpl("video-recorder", svc.capabilities().recordingOutput === "native-file" ? "native file" : "MediaRecorder");
    return svc;
  });
  return resolved;
}

export const cameraCapabilities = async () => (await cameraService()).capabilities();
export const startCamera = async (opts: PreviewOptions) => (await cameraService()).startPreview(opts);
export const stopCamera = async (handle: PreviewHandle | null) =>
  (await cameraService()).stopPreview(handle);
export const switchCamera = async (handle: PreviewHandle, facing: CameraFacing) =>
  (await cameraService()).switchCamera(handle, facing);
export const setZoom = async (handle: PreviewHandle, zoom: number) =>
  (await cameraService()).setZoom(handle, zoom);
export const cameraDeviceCapabilities = async () => {
  const svc = await cameraService();
  return svc.deviceCapabilities ? svc.deviceCapabilities() : null;
};
export const startRecording = async (handle: PreviewHandle, opts: RecorderOptions) =>
  (await cameraService()).startRecording(handle, opts);
