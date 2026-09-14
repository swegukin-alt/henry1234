// Runtime detection.
//
// The website must never depend on Capacitor being installed, so this file
// never imports @capacitor/core. Capacitor injects a global on the native
// WebView; that global is the only thing we read. When the native packages are
// installed later, nothing here needs to change.

export type PlatformName = "web" | "ios" | "android";

type CapacitorGlobal = {
  isNativePlatform?: () => boolean;
  getPlatform?: () => string;
  isPluginAvailable?: (name: string) => boolean;
  convertFileSrc?: (url: string) => string;
};

/**
 * Turn a native file:// URI into something the WebView can load directly
 * (streamed off disk, never copied into memory). Returns the input unchanged
 * on the web, where there are no native file URIs.
 */
export function convertFileSrc(uri: string): string {
  try {
    return capacitor()?.convertFileSrc?.(uri) ?? uri;
  } catch {
    return uri;
  }
}

function capacitor(): CapacitorGlobal | null {
  if (typeof window === "undefined") return null;
  const g = (window as unknown as { Capacitor?: CapacitorGlobal }).Capacitor;
  return g && typeof g === "object" ? g : null;
}

export function isNative(): boolean {
  try {
    return capacitor()?.isNativePlatform?.() === true;
  } catch {
    return false;
  }
}

export function getPlatform(): PlatformName {
  try {
    const p = capacitor()?.getPlatform?.();
    if (p === "ios" || p === "android") return p;
  } catch {
    /* fall through to web */
  }
  return "web";
}

export const isIOSNative = () => isNative() && getPlatform() === "ios";

/** True only when the named Capacitor plugin is actually registered natively. */
export function hasPlugin(name: string): boolean {
  try {
    return capacitor()?.isPluginAvailable?.(name) === true;
  } catch {
    return false;
  }
}

/**
 * Resolve a service implementation: native when we are on a native runtime and
 * the native module reports itself available, otherwise the web one. A native
 * implementation that cannot do the job must say so — never fake success.
 *
 * Only for services where the browser version is a legitimate answer inside the
 * app (files, script import). Camera, recording, microphone and video storage
 * use `pickStrict` instead.
 */
export async function pickImpl<T extends { available: () => boolean | Promise<boolean> }>(
  web: T,
  loadNative: () => Promise<T | null>,
): Promise<T> {
  if (!isNative()) return web;
  try {
    const native = await loadNative();
    if (native && (await native.available())) return native;
  } catch {
    /* native path unusable — fall back to the browser implementation */
  }
  return web;
}

/**
 * Same resolution, but with no silent browser fallback on a native runtime.
 * Inside the iPhone app the native implementation is always used, even when its
 * plugin is missing — in that case its own methods return a visible error.
 * The camera, the recording microphone and video capture must never quietly run
 * on getUserMedia/MediaRecorder inside the app.
 */
export async function pickStrict<T>(web: T, loadNative: () => Promise<T>): Promise<T> {
  if (!isNative()) return web;
  return loadNative();
}

/** Records which implementation each critical service actually resolved to. */
const activeImpl = new Map<string, string>();

export function noteImpl(service: string, impl: string): void {
  activeImpl.set(service, impl);
}

export function activeImplementations(): Record<string, string> {
  return Object.fromEntries(activeImpl);
}

export type RuntimeInfo = {
  platform: PlatformName;
  native: boolean;
  userAgent: string;
  standalone: boolean;
};

export function describeRuntime(): RuntimeInfo {
  const nav = typeof navigator === "undefined" ? null : navigator;
  return {
    platform: getPlatform(),
    native: isNative(),
    userAgent: nav?.userAgent ?? "",
    standalone:
      typeof window !== "undefined" &&
      (window.matchMedia?.("(display-mode: standalone)").matches === true ||
        (nav as unknown as { standalone?: boolean })?.standalone === true),
  };
}
