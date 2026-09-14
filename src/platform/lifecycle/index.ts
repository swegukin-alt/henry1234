// App lifecycle. The recording flow must never be left guessing whether the
// camera and microphone are still alive.
// Web: visibilitychange / pagehide / freeze.
// Native: @capacitor/app state events (documented; the WebView still fires the
// browser events inside the app, so nothing is lost before the plugin lands).

export type LifecycleState = "active" | "inactive" | "background" | "resumed";

export function onLifecycleChange(cb: (state: LifecycleState) => void): () => void {
  if (typeof document === "undefined") return () => {};

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
