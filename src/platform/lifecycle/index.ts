// App lifecycle. The recording flow must never be left guessing whether the
// camera and microphone are still alive.
// Web: visibilitychange / pagehide / freeze.
// iOS app: @capacitor/app state events, which are the only reliable signal when
// the phone locks or a call arrives — the WebView does not always fire
// visibilitychange for those.

import { isNative, noteImpl } from "../runtime";
import { loadModule, PLUGIN_MODULES } from "../native-plugins";

export type LifecycleState = "active" | "inactive" | "background" | "resumed";

type AppPlugin = {
  addListener: (
    event: "appStateChange" | "pause" | "resume",
    cb: (data: { isActive?: boolean }) => void,
  ) => Promise<{ remove: () => void }>;
};

function nativeLifecycle(cb: (state: LifecycleState) => void): () => void {
  const subs: Array<{ remove: () => void }> = [];
  let gone = false;
  noteImpl("lifecycle", "native (@capacitor/app)");
  void loadModule<{ App?: AppPlugin }>(PLUGIN_MODULES.app).then(async (mod) => {
    const App = mod?.App;
    if (!App || gone) return;
    subs.push(
      await App.addListener("appStateChange", ({ isActive }) =>
        cb(isActive ? "resumed" : "background"),
      ),
    );
    subs.push(await App.addListener("pause", () => cb("background")));
    subs.push(await App.addListener("resume", () => cb("resumed")));
    if (gone) subs.forEach((s) => s.remove());
  });
  return () => {
    gone = true;
    subs.forEach((s) => s.remove());
  };
}

export function onLifecycleChange(cb: (state: LifecycleState) => void): () => void {
  if (isNative()) return nativeLifecycle(cb);
  if (typeof document === "undefined") return () => {};
  noteImpl("lifecycle", "web (visibilitychange)");

  const onVisibility = () =>
    cb(document.visibilityState === "visible" ? "resumed" : "background");
  const onHide = () => cb("background");
  const onShow = () => cb("resumed");
  const onBlur = () => cb("inactive");

  document.addEventListener("visibilitychange", onVisibility);
  window.addEventListener("pagehide", onHide);
  window.addEventListener("pageshow", onShow);
  window.addEventListener("blur", onBlur);

  return () => {
    document.removeEventListener("visibilitychange", onVisibility);
    window.removeEventListener("pagehide", onHide);
    window.removeEventListener("pageshow", onShow);
    window.removeEventListener("blur", onBlur);
  };
}

export function isOnline(): boolean {
  return typeof navigator === "undefined" ? true : navigator.onLine !== false;
}

/** Network changes, so a lost connection is never mistaken for a camera fault. */
export function onNetworkChange(cb: (online: boolean) => void): () => void {
  if (typeof window === "undefined") return () => {};
  const up = () => cb(true);
  const down = () => cb(false);
  window.addEventListener("online", up);
  window.addEventListener("offline", down);
  return () => {
    window.removeEventListener("online", up);
    window.removeEventListener("offline", down);
  };
}
