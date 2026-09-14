// The screen must never dim while reading or recording.
// Web: Screen Wake Lock, re-taken whenever the tab comes back.
// Native: a keep-awake plugin (see NATIVE_READINESS.md) — until it is
// installed, the WebView wake lock still applies inside the app.

import { hasPlugin, isNative } from "../runtime";

type WakeLockSentinel = { released: boolean; release: () => Promise<void> };
type WakeLockNavigator = Navigator & {
  wakeLock?: { request: (type: "screen") => Promise<WakeLockSentinel> };
};

export function keepAwakeSupported(): boolean {
  if (isNative() && hasPlugin("KeepAwake")) return true;
  return typeof navigator !== "undefined" && !!(navigator as WakeLockNavigator).wakeLock;
}

/**
 * Hold the screen awake until the returned function is called. Safe to call
 * when unsupported — it simply does nothing and reports that honestly.
 */
export function keepScreenAwake(): () => void {
  if (typeof navigator === "undefined") return () => {};
  const nav = navigator as WakeLockNavigator;
  if (!nav.wakeLock) return () => {};

  let sentinel: WakeLockSentinel | null = null;
  let released = false;

  const acquire = async () => {
    if (released || document.visibilityState !== "visible") return;
    try {
      sentinel = await nav.wakeLock!.request("screen");
    } catch {
      /* denied or already held — nothing else to do */
    }
  };
  const onVisible = () => {
    if (document.visibilityState === "visible" && (!sentinel || sentinel.released)) void acquire();
  };

  void acquire();
  document.addEventListener("visibilitychange", onVisible);

  return () => {
    released = true;
    document.removeEventListener("visibilitychange", onVisible);
    void sentinel?.release().catch(() => {});
    sentinel = null;
  };
}
