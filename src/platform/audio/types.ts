import type { PlatformService, ServiceResult } from "../types";

export type MicInfo = { id: string; label: string; external: boolean };

export type AudioRoute = "built-in" | "wired" | "bluetooth" | "usb" | "unknown";

export type AudioCapabilities = {
  supportsDeviceSelection: boolean;
  supportsRouteChangeEvents: boolean;
  supportsInterruptionEvents: boolean;
  /** iOS audio-session category control (native only). */
  supportsAudioSession: boolean;
};

export type AudioService = PlatformService & {
  capabilities: () => AudioCapabilities;
  /** Best available input: an external/wireless mic wins over the built-in one. */
  pickBestInput: () => Promise<MicInfo | null>;
  /** Put the chosen mic onto an existing capture stream without interrupting video. */
  applyInput: (stream: MediaStream, mic: MicInfo) => Promise<ServiceResult<void>>;
  /** Repair a dropped microphone. Never touches a healthy track. */
  reacquire: (stream: MediaStream, preferredId?: string) => Promise<ServiceResult<void>>;
  hasLiveInput: (stream: MediaStream | null) => boolean;
  onDeviceChange: (cb: () => void) => () => void;
  /** Native only: react to AirPods/route swaps and call/Siri interruptions. */
  onInterruption: (cb: (state: "began" | "ended") => void) => () => void;
};
