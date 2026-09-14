// Optional feedback for physical actions. Never required: iPhone Safari has no
// vibration API at all, and the app must behave identically without it.
// iOS app: @capacitor/haptics (Taptic Engine).

import { hasPlugin, isNative, noteImpl } from "../runtime";
import { loadModule, PLUGIN_MODULES } from "../native-plugins";

export type HapticEvent = "record-start" | "record-stop" | "remote-connected" | "error";

const PATTERNS: Record<HapticEvent, number | number[]> = {
  "record-start": 20,
  "record-stop": [15, 40, 15],
  "remote-connected": 10,
  error: [40, 60, 40],
};

type HapticsPlugin = {
  impact: (o: { style: string }) => Promise<void>;
  notification: (o: { type: string }) => Promise<void>;
};

const NATIVE: Record<HapticEvent, { kind: "impact" | "notification"; value: string }> = {
  "record-start": { kind: "impact", value: "MEDIUM" },
  "record-stop": { kind: "impact", value: "LIGHT" },
  "remote-connected": { kind: "impact", value: "LIGHT" },
  error: { kind: "notification", value: "ERROR" },
};

export const hapticsSupported = (): boolean =>
  isNative()
    ? hasPlugin("Haptics")
    : typeof navigator !== "undefined" && typeof navigator.vibrate === "function";

export function haptic(event: HapticEvent): void {
  if (isNative()) {
    noteImpl("haptics", "native (@capacitor/haptics)");
    void loadModule<{ Haptics?: HapticsPlugin }>(PLUGIN_MODULES.haptics).then((mod) => {
      const H = mod?.Haptics;
      if (!H) return;
      const spec = NATIVE[event];
      const call =
        spec.kind === "impact" ? H.impact({ style: spec.value }) : H.notification({ type: spec.value });
      void call.catch(() => {});
    });
    return;
  }
  try {
    navigator.vibrate?.(PATTERNS[event]);
  } catch {
    /* unsupported — silently fine */
  }
}
