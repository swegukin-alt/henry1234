import { pickImpl } from "../runtime";
import { webCamera } from "./web";
import type {
  CameraCapabilities,
  CameraFacing,
  CameraService,
  PreviewHandle,
  PreviewOptions,
  RecorderOptions,
} from "./types";

export type * from "./types";
export { pickRecorderMime } from "./web";

let resolved: Promise<CameraService> | null = null;

export function cameraService(): Promise<CameraService> {
  resolved ??= pickImpl(webCamera, async () => (await import("./native")).nativeCamera);
  return resolved;
}

export const startCamera = async (opts: PreviewOptions) => (await cameraService()).startPreview(opts);
export const stopCamera = async (handle: PreviewHandle | null) =>
  (await cameraService()).stopPreview(handle);
export const switchCamera = async (handle: PreviewHandle, facing: CameraFacing) =>
  (await cameraService()).switchCamera(handle, facing);
export const setZoom = async (handle: PreviewHandle, zoom: number) =>
  (await cameraService()).setZoom(handle, zoom);
export const startRecording = async (handle: PreviewHandle, opts: RecorderOptions) =>
  (await cameraService()).startRecording(handle, opts);
export const cameraCapabilities = async (): Promise<CameraCapabilities> =>
  (await cameraService()).capabilities();
