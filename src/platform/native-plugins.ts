// Loader for the Capacitor plugin modules.
//
// Every specifier below is a LITERAL dynamic import, so Vite resolves and
// bundles each package at build time. Bare npm specifiers cannot be resolved
// by a WebView at runtime, which is why `/* @vite-ignore */` must never be
// used for these packages.
//
// The imports stay dynamic (never top-level) so the website only ever
// downloads these chunks if native code paths actually run, which they never
// do in a browser.

export type PluginKey =
  | "cameraPreview"
  | "filesystem"
  | "share"
  | "preferences"
  | "media"
  | "app"
  | "haptics"
  | "keepAwake"
  | "screenOrientation"
  | "core";

/** Kept for call sites that pass `PLUGIN_MODULES.x` into `loadModule`. */
export const PLUGIN_MODULES = {
  cameraPreview: "cameraPreview",
  filesystem: "filesystem",
  share: "share",
  preferences: "preferences",
  media: "media",
  app: "app",
  haptics: "haptics",
  keepAwake: "keepAwake",
  screenOrientation: "screenOrientation",
  core: "core",
} as const satisfies Record<PluginKey, PluginKey>;

const LOADERS: Record<PluginKey, () => Promise<unknown>> = {
  cameraPreview: () => import("@capacitor-community/camera-preview"),
  filesystem: () => import("@capacitor/filesystem"),
  share: () => import("@capacitor/share"),
  preferences: () => import("@capacitor/preferences"),
  media: () => import("@capacitor-community/media"),
  app: () => import("@capacitor/app"),
  haptics: () => import("@capacitor/haptics"),
  keepAwake: () => import("@capacitor-community/keep-awake"),
  screenOrientation: () => import("@capacitor/screen-orientation"),
  core: () => import("@capacitor/core"),
};

const cache = new Map<PluginKey, unknown>();

export async function loadModule<T>(key: string): Promise<T | null> {
  const loader = LOADERS[key as PluginKey];
  if (!loader) return null;
  if (cache.has(key as PluginKey)) return cache.get(key as PluginKey) as T;
  try {
    const mod = (await loader()) as T;
    cache.set(key as PluginKey, mod);
    return mod;
  } catch {
    return null;
  }
}

type CoreModule = {
  registerPlugin?: <T>(name: string) => T;
  Capacitor?: {
    isNativePlatform?: () => boolean;
    getPlatform?: () => string;
    isPluginAvailable?: (name: string) => boolean;
  };
};

/** The real bundled @capacitor/core module (null on the website). */
export async function capacitorCore(): Promise<CoreModule | null> {
  return loadModule<CoreModule>(PLUGIN_MODULES.core);
}

/** Asks the bundled core — not a global guess — whether a plugin is registered. */
export async function isPluginRegistered(name: string): Promise<boolean> {
  const core = await capacitorCore();
  try {
    return core?.Capacitor?.isPluginAvailable?.(name) === true;
  } catch {
    return false;
  }
}

/**
 * The custom Swift/AVFoundation plugin (see `ios-plugin/TeleprompterCapture`).
 * Reached through Capacitor's plugin registry rather than an npm package, so
 * the app works whether or not it has been added to the Xcode project.
 */
export async function customCapturePlugin<T = Record<string, unknown>>(): Promise<T | null> {
  const core = await capacitorCore();
  if (!core?.registerPlugin) return null;
  if (core.Capacitor?.isNativePlatform?.() !== true) return null;
  if (core.Capacitor?.isPluginAvailable?.("TeleprompterCapture") !== true) return null;
  return core.registerPlugin<T>("TeleprompterCapture");
}
