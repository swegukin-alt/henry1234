// Small settings: scroll speed, font size, mirror mode, last camera, quality,
// reading position. Web uses localStorage (unchanged); native will use
// @capacitor/preferences. Reads stay synchronous through an in-memory cache so
// no existing render path has to become async.

import { isNative } from "../runtime";
import type { SettingsService } from "./types";

const cache = new Map<string, unknown>();
let hydrated = false;

type PreferencesPlugin = {
  keys: () => Promise<{ keys: string[] }>;
  get: (o: { key: string }) => Promise<{ value: string | null }>;
  set: (o: { key: string; value: string }) => Promise<void>;
  remove: (o: { key: string }) => Promise<void>;
};

// Bundled at build time; only fetched when the native path actually runs.
import { loadModule, PLUGIN_MODULES } from "../native-plugins";

async function nativePrefs(): Promise<PreferencesPlugin | null> {
  if (!isNative()) return null;
  try {
    const mod = await loadModule<{ Preferences?: PreferencesPlugin }>(PLUGIN_MODULES.preferences);
    return mod?.Preferences ?? null;
  } catch {
    return null;
  }
}

export const settings: SettingsService = {
  name: "settings",
  available: () => typeof window !== "undefined",

  async hydrate() {
    if (hydrated || typeof window === "undefined") return;
    const prefs = await nativePrefs();
    if (prefs) {
      try {
        const { keys } = await prefs.keys();
        for (const key of keys) {
          const { value } = await prefs.get({ key });
          if (value != null) cache.set(key, JSON.parse(value));
        }
        hydrated = true;
        return;
      } catch {
        /* fall through to the browser store */
      }
    }
    hydrated = true; // localStorage reads are already synchronous
  },

  get<T>(key: string, fallback: T): T {
    if (cache.has(key)) return cache.get(key) as T;
    if (typeof window === "undefined") return fallback;
    try {
      const raw = localStorage.getItem(key);
      if (raw == null) return fallback;
      const parsed = JSON.parse(raw) as T;
      cache.set(key, parsed);
      return parsed;
    } catch {
      return fallback;
    }
  },

  set<T>(key: string, value: T) {
    cache.set(key, value);
    if (typeof window === "undefined") return;
    const json = JSON.stringify(value);
    try {
      localStorage.setItem(key, json);
    } catch {
      /* private mode / full quota — the in-memory value still holds for this session */
    }
    void nativePrefs().then((p) => p?.set({ key, value: json }).catch(() => {}));
  },

  remove(key: string) {
    cache.delete(key);
    try {
      localStorage.removeItem(key);
    } catch {
      /* nothing stored */
    }
    void nativePrefs().then((p) => p?.remove({ key }).catch(() => {}));
  },
};

export const hydrateSettings = () => settings.hydrate();
export const getSetting = <T>(key: string, fallback: T): T => settings.get(key, fallback);
export const setSetting = <T>(key: string, value: T): void => settings.set(key, value);
