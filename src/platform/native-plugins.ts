// Lazy loader for Capacitor plugin modules.
//
// Every specifier is a variable with `@vite-ignore`, so the website bundle
// never resolves any of these packages: the browser build must keep working
// with Capacitor absent entirely. Modules are cached after the first load.

const cache = new Map<string, unknown>();

export const PLUGIN_MODULES = {
  cameraPreview: "@capacitor-community/camera-preview",
  filesystem: "@capacitor/filesystem",
  share: "@capacitor/share",
  preferences: "@capacitor/preferences",
  media: "@capacitor-community/media",
  app: "@capacitor/app",
  haptics: "@capacitor/haptics",
  keepAwake: "@capacitor-community/keep-awake",
  screenOrientation: "@capacitor/screen-orientation",
  core: "@capacitor/core",
} as const;

export async function loadModule<T>(specifier: string): Promise<T | null> {
  if (cache.has(specifier)) return cache.get(specifier) as T;
  try {
    const mod = (await import(/* @vite-ignore */ specifier)) as T;
    cache.set(specifier, mod);
    return mod;
  } catch {
    return null;
  }
}

/**
 * The custom Swift/AVFoundation plugin (see `ios-plugin/TeleprompterCapture`).
 * It is reached through Capacitor's plugin registry rather than an npm package,
 * so the app works whether or not it has been added to the Xcode project.
 */
export async function customCapturePlugin<T = Record<string, unknown>>(): Promise<T | null> {
  const core = await loadModule<{
    registerPlugin?: (name: string) => T;
    Capacitor?: { isPluginAvailable?: (n: string) => boolean };
  }>(PLUGIN_MODULES.core);
  if (!core?.registerPlugin) return null;
  if (core.Capacitor?.isPluginAvailable?.("TeleprompterCapture") !== true) return null;
  return core.registerPlugin("TeleprompterCapture");
}
