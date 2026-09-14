import { isNative } from "../runtime";
import type { FileStoreService } from "./types";

export type * from "./types";
export { settings, hydrateSettings, getSetting, setSetting, settingsHydrationStatus, type SettingsHydrationStatus } from "./settings";

/**
 * Where large recordings live on this runtime. The web store is the existing
 * IndexedDB clip store in `src/lib/clip-store.ts`; it is already chunk-based
 * and recoverable, so it is not re-implemented here. On iOS the recordings
 * should move to @capacitor/filesystem — tracked in NATIVE_READINESS.md.
 */
export function mediaStoreKind(): FileStoreService["kind"] {
  return isNative() ? "native-filesystem" : "indexeddb";
}

export async function storageEstimate(): Promise<{ usedBytes: number; quotaBytes: number | null }> {
  try {
    const est = await navigator.storage?.estimate?.();
    return { usedBytes: est?.usage ?? 0, quotaBytes: est?.quota ?? null };
  } catch {
    return { usedBytes: 0, quotaBytes: null };
  }
}
