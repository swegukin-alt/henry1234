// Shared vocabulary for every platform service.

export type PermissionName = "camera" | "microphone" | "photos" | "bluetooth" | "speech";

/** Mirrors the states iOS actually reports, plus the browser's "prompt". */
export type PermissionState =
  | "not-requested"
  | "granted"
  | "denied"
  | "restricted"
  | "unavailable";

export type ServiceResult<T = void> =
  | { ok: true; value: T }
  | { ok: false; reason: string; code?: string };

export const ok = <T>(value: T): ServiceResult<T> => ({ ok: true, value });
export const fail = <T = never>(reason: string, code?: string): ServiceResult<T> => ({
  ok: false,
  reason,
  code,
});

/** Every service reports honestly whether it can do anything on this runtime. */
export type PlatformService = {
  readonly name: string;
  available: () => boolean | Promise<boolean>;
};
