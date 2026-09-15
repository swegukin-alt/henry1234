// The one place the app talks to the device.
//
// Components call plain functions here; this layer decides whether the browser
// or a native iOS implementation performs the work. No Capacitor import ever
// enters the website bundle: native modules are loaded lazily and only when a
// Capacitor runtime is actually detected.

export * from "./runtime";
export * from "./types";

export { cameraService, startCamera, stopCamera, switchCamera, setZoom, startRecording, cameraCapabilities, cameraDeviceCapabilities } from "./camera";
export type { CameraCapabilities, CameraDeviceCapabilities, CameraService, PreviewHandle, RecordingHandle, StabilizationMode, CameraQuality } from "./camera";

export { audioService, pickBestMicrophone, applyMicrophone, requestMicrophone, hasLiveMicrophone } from "./audio";
export type { AudioService, MicInfo } from "./audio";

export { speechCapabilities } from "./speech";
export type { SpeechCapabilities } from "./speech";

export { settings, hydrateSettings, getSetting, setSetting, settingsHydrationStatus, type SettingsHydrationStatus, mediaStoreKind, storageEstimate } from "./storage";

export { mediaLibraryCapabilities, saveToPhotos } from "./media-library";
export { shareCapabilities, shareFilePath } from "./share";
export { filePickCapabilities, pickTextFile, downloadText } from "./files";

export { remoteService, connectRemote, DEFAULT_KEY_MAPPING } from "./remote";
export type { RemoteAction, RemoteEvent, RemoteMapping } from "./remote";

export { keepScreenAwake, keepAwakeSupported } from "./keep-awake";
export {
  lockOrientation,
  currentOrientation,
  orientationSupport,
  enterImmersive,
  exitImmersive,
} from "./orientation";
export { onLifecycleChange, onNetworkChange, isOnline } from "./lifecycle";
export type { LifecycleState } from "./lifecycle";
export { haptic, hapticsSupported } from "./haptics";
export { permissionService, checkPermission, requestPermission, openAppSettings } from "./permissions";
export { readOrientation } from "./orientation";
