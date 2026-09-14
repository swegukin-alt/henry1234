// The screen must never dim while reading or recording.
// Web: Screen Wake Lock, re-taken whenever the tab comes back.
// iOS app: @capacitor-community/keep-awake (a real UIApplication idle-timer
// disable). navigator.wakeLock is not used on native.

import { hasPlugin, isNative, noteImpl } from "../runtime";
import { loadModule, PLUGIN_MODULES } from "../native-plugins";

type WakeLockSentinel = { released: boolean; release: () => Promise<void> };
type WakeLockNavigator = Navigator & {
  wakeLock?: { request: (type: "screen") => Promise<WakeLockSentinel> };
};

type KeepAwakePlugin = { keepAwake: () => Promise<void>; allowSleep: () => Promise<void> };

export function keepAwakeSupported(): boolean {
  if (isNative()) return hasPlugin("KeepAwake");
  return typeof navigator !== "undefined" && !!(navigator as WakeLockNavigator).wakeLock;
}

function nativeKeepAwake(): () => void {
  let released = false;
  noteImpl("keep-awake", "native (@capacitor-community/keep-awake)");
  void loadModule<{ KeepAwake?: KeepAwakePlugin }>(PLUGIN_MODULES.keepAwake).then((mod) => {
    if (!mod?.KeepAwake || released) return;
    void mod.KeepAwake.keepAwake().catch(() => {});
  });
  return () => {
    released = true;
    void loadModule<{ KeepAwake?: KeepAwakePlugin }>(PLUGIN_MODULES.keepAwake).then((mod) =>
      mod?.KeepAwake?.allowSleep().catch(() => {}),
    );
  };
}

/**
 * Hold the screen awake until the returned function is called. Safe to call
 * when unsupported — it simply does nothing and reports that honestly.
 */
export function keepScreenAwake(): () => void {
  if (isNative()) return nativeKeepAwake();
  if (typeof navigator === "undefined") return () => {};
  const nav = navigator as WakeLockNavigator;
  if (!nav.wakeLock) return () => {};
  noteImpl("keep-awake", "web (Screen Wake Lock)");

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
