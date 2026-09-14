// Optional feedback for physical actions. Never required: iPhone Safari has no
// vibration API at all, and the app must behave identically without it.

import { hasPlugin, isNative } from "../runtime";

export type HapticEvent = "record-start" | "record-stop" | "remote-connected" | "error";

const PATTERNS: Record<HapticEvent, number | number[]> = {
  "record-start": 20,
  "record-stop": [15, 40, 15],
  "remote-connected": 10,
  error: [40, 60, 40],
};

export const hapticsSupported = (): boolean =>
  (isNative() && hasPlugin("Haptics")) ||
  (typeof navigator !== "undefined" && typeof navigator.vibrate === "function");

export function haptic(event: HapticEvent): void {
  try {
    navigator.vibrate?.(PATTERNS[event]);
  } catch {
    /* unsupported — silently fine */
  }
}
