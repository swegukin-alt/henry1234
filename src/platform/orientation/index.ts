// Orientation and immersive (fullscreen) mode for the reading screen.
// Web: the Screen Orientation and Fullscreen APIs where the browser has them.
// iOS app: @capacitor/screen-orientation, applied only to the teleprompter
// screen and released on the way out. screen.orientation.lock() is not used on
// native; iOS ignores it inside a WebView.

import { hasPlugin, isNative, noteImpl } from "../runtime";
import { loadModule, PLUGIN_MODULES } from "../native-plugins";

type OrientationLockType = "portrait" | "landscape" | "any";

type LockableOrientation = ScreenOrientation & {
  lock?: (o: string) => Promise<void>;
  unlock?: () => void;
};

type FullscreenElement = HTMLElement & {
  webkitRequestFullscreen?: () => Promise<void> | void;
};

type OrientationPlugin = {
  lock: (o: { orientation: string }) => Promise<void>;
  unlock: () => Promise<void>;
  orientation: () => Promise<{ type: string }>;
};

const nativePlugin = () =>
  loadModule<{ ScreenOrientation?: OrientationPlugin }>(PLUGIN_MODULES.screenOrientation).then(
    (m) => m?.ScreenOrientation ?? null,
  );

export function orientationSupport(): { canLock: boolean; canReadOrientation: boolean } {
  if (isNative()) {
    return { canLock: hasPlugin("ScreenOrientation"), canReadOrientation: true };
  }
  const so = typeof screen !== "undefined" ? (screen.orientation as LockableOrientation | undefined) : undefined;
  return { canLock: !!so?.lock, canReadOrientation: !!so };
}

export function currentOrientation(): "portrait" | "landscape" {
  if (typeof window === "undefined") return "portrait";
  const type = (screen.orientation as ScreenOrientation | undefined)?.type;
  if (type) return type.startsWith("landscape") ? "landscape" : "portrait";
  return window.innerWidth >= window.innerHeight ? "landscape" : "portrait";
}

/** Native orientation as iOS reports it, falling back to the WebView reading. */
export async function readOrientation(): Promise<"portrait" | "landscape"> {
  if (isNative()) {
    const p = await nativePlugin();
    if (p) {
      try {
        const { type } = await p.orientation();
        return type?.startsWith("landscape") ? "landscape" : "portrait";
      } catch {
        /* fall through to the WebView reading */
      }
    }
  }
  return currentOrientation();
}

export async function lockOrientation(to: OrientationLockType): Promise<boolean> {
  if (isNative()) {
    const p = await nativePlugin();
    if (!p) return false;
    noteImpl("orientation", "native (@capacitor/screen-orientation)");
    try {
      if (to === "any") await p.unlock();
      else await p.lock({ orientation: to === "landscape" ? "landscape" : "portrait" });
      return true;
    } catch {
      return false;
    }
  }
  noteImpl("orientation", "web (Screen Orientation API)");
  const so = (typeof screen !== "undefined" ? screen.orientation : undefined) as
    | LockableOrientation
    | undefined;
  if (to === "any") {
    try {
      so?.unlock?.();
      return true;
    } catch {
      return false;
    }
  }
  try {
    await so?.lock?.(to);
    return true;
  } catch {
    // Safari refuses outside fullscreen; the user rotates the phone manually.
    return false;
  }
}

/** Fullscreen reading mode. Never applied to the rest of the app. */
export async function enterImmersive(el?: HTMLElement | null): Promise<void> {
  // The app is already fullscreen on iOS; asking the WebView for fullscreen
  // there would do nothing but throw.
  if (isNative() || typeof document === "undefined") return;
  const target = (el ?? document.documentElement) as FullscreenElement;
  try {
    if (!document.fullscreenElement) {
      await (target.requestFullscreen?.() ?? target.webkitRequestFullscreen?.());
    }
  } catch {
    /* iOS Safari has no element fullscreen — the layout already fills the screen */
  }
}

export async function exitImmersive(): Promise<void> {
  if (isNative() || typeof document === "undefined") return;
  try {
    if (document.fullscreenElement) await document.exitFullscreen();
  } catch {
    /* already out */
  }
}
