// Orientation and immersive (fullscreen) mode for the reading screen.
// Web: the Screen Orientation and Fullscreen APIs where the browser has them.
// Native: @capacitor/screen-orientation + @capacitor/status-bar, applied only
// to the teleprompter screen and restored on the way out.

import { hasPlugin, isNative } from "../runtime";

type OrientationLockType = "portrait" | "landscape" | "any";

type LockableOrientation = ScreenOrientation & {
  lock?: (o: string) => Promise<void>;
  unlock?: () => void;
};

type FullscreenElement = HTMLElement & {
  webkitRequestFullscreen?: () => Promise<void> | void;
};

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

export async function lockOrientation(to: OrientationLockType): Promise<boolean> {
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
  try {
    if (document.fullscreenElement) await document.exitFullscreen();
  } catch {
    /* already out */
  }
}
