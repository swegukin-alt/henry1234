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

/** Hard ceiling on native storage during startup — the UI never waits longer. */
const HYDRATE_TIMEOUT_MS = 1500;

export type SettingsHydrationStatus = {
  state: "pending" | "native" | "timeout" | "error" | "web" | "unavailable";
  keysLoaded: number;
  ms: number;
  detail?: string;
};

let status: SettingsHydrationStatus = { state: "pending", keysLoaded: 0, ms: 0 };

/** What actually happened during startup hydration — shown on /diagnostics. */
export const settingsHydrationStatus = (): SettingsHydrationStatus => status;

const TIMED_OUT = Symbol("timeout");

function withTimeout<T>(p: Promise<T>, ms: number): Promise<T | typeof TIMED_OUT> {
  return Promise.race([p, new Promise<typeof TIMED_OUT>((r) => setTimeout(() => r(TIMED_OUT), ms))]);
}

export const settings: SettingsService = {
  name: "settings",
  available: () => typeof window !== "undefined",

  /**
   * Never rejects and never hangs: whatever native storage does, this settles
   * within HYDRATE_TIMEOUT_MS so the app can always finish booting. A slow or
   * broken Preferences plugin degrades to the local cache/defaults.
   */
  async hydrate() {
    if (hydrated || typeof window === "undefined") return;
    const started = Date.now();
    const finish = (s: SettingsHydrationStatus["state"], keysLoaded: number, detail?: string) => {
      hydrated = true;
      status = { state: s, keysLoaded, ms: Date.now() - started, detail };
      if (s === "timeout" || s === "error") {
        console.warn(`[settings] native storage ${s}: ${detail ?? ""} — using local settings`);
      }
    };

    if (!isNative()) {
      finish("web", 0); // localStorage reads are already synchronous
      return;
    }

    try {
      const outcome = await withTimeout(
        (async () => {
          const prefs = await nativePrefs();
          if (!prefs) return { kind: "unavailable" as const };
          const { keys } = await prefs.keys();
          let loaded = 0;
          for (const key of keys) {
            const { value } = await prefs.get({ key });
            if (value != null) {
              try {
                cache.set(key, JSON.parse(value));
                loaded++;
              } catch {
                /* a corrupt value is ignored, the default is used instead */
              }
            }
          }
          return { kind: "native" as const, loaded };
        })(),
        HYDRATE_TIMEOUT_MS,
      );

      if (outcome === TIMED_OUT) finish("timeout", 0, `no answer in ${HYDRATE_TIMEOUT_MS} ms`);
      else if (outcome.kind === "unavailable") finish("unavailable", 0, "Preferences plugin not registered");
      else finish("native", outcome.loaded);
    } catch (err) {
      finish("error", 0, (err as { message?: string })?.message || String(err));
    }
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
