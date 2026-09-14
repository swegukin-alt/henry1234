import { pickImpl } from "../runtime";
import { webAudio } from "./web";
import type { AudioService, MicInfo } from "./types";

export type * from "./types";

let resolved: Promise<AudioService> | null = null;

export function audioService(): Promise<AudioService> {
  resolved ??= pickImpl(webAudio, async () => (await import("./native")).nativeAudio);
  return resolved;
}

export const pickBestMicrophone = async (): Promise<MicInfo | null> =>
  (await audioService()).pickBestInput();
export const applyMicrophone = async (stream: MediaStream, mic: MicInfo) =>
  (await audioService()).applyInput(stream, mic);
export const requestMicrophone = async (stream: MediaStream, preferredId?: string) =>
  (await audioService()).reacquire(stream, preferredId);
export const hasLiveMicrophone = async (stream: MediaStream | null) =>
  (await audioService()).hasLiveInput(stream);
