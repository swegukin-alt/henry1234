// Where recorded takes live.
//
// Web: the existing chunk-based IndexedDB store in `src/lib/clip-store.ts`,
// untouched — same behaviour, same recovery, same instant stop.
// iOS native: a real file per take in the app's own filesystem
// (`src/platform/storage/media-store.native.ts`), so multi-gigabyte recordings
// never sit inside WebKit storage.
//
// Components call the plain functions at the bottom of this file and never
// branch on platform themselves.

import { isNative } from "../runtime";
import * as webStore from "@/lib/clip-store";
import type { ClipMeta, ClipRecord, RepairReport, RestoreReport } from "@/lib/clip-store";

export type { ClipMeta, ClipRecord } from "@/lib/clip-store";

export type NewSession = {
  id: string;
  scriptId: string;
  mimeType: string;
  startedAt: number;
  width: number;
  height: number;
};

/** A playable source for a stored take, plus its cleanup. */
export type ClipSource = { src: string; revoke: () => void; path?: string };

export type MediaStore = {
  kind: "indexeddb" | "native-filesystem";

  // live recording
  createSession: (s: NewSession) => Promise<void>;
  appendChunk: (recordingId: string, blob: Blob) => Promise<number>;
  finalizeSession: (recordingId: string, extra?: { durationMs?: number }) => Promise<ClipRecord | null>;
  recoverOrphanSessions: () => Promise<ClipRecord[]>;

  // library
  listClipMeta: (scriptId: string) => Promise<ClipMeta[]>;
  listAllClips: () => Promise<ClipMeta[]>;
  getClip: (id: string) => Promise<ClipRecord | null>;
  clipSource: (meta: ClipMeta) => Promise<ClipSource | null>;
  deleteClip: (id: string) => Promise<void>;
  deleteAllForScript: (scriptId: string) => Promise<void>;

  // housekeeping
  requestPersistentStorage: () => Promise<boolean>;
  storageUsage: () => Promise<{ clipBytes: number; usage: number; quota: number }>;
  clearAllStorage: () => Promise<void>;
  purgeOrphanChunks: () => Promise<number>;

  // recovery (IndexedDB-specific; on a real filesystem the file is the file)
  repairClip: (id: string) => Promise<{ clip: ClipRecord | null; report: RepairReport }>;
  deepRestore: (id: string) => Promise<{ clip: ClipRecord | null; report: RestoreReport }>;
  rescueAll: (scriptId: string) => Promise<ClipRecord[]>;

  /** Native only: the on-disk file URI, used for the iOS share sheet and Photos. */
  filePath?: (id: string) => Promise<string | null>;

  /**
   * Native only: adopt a file iOS just recorded (the native camera writes the
   * whole take itself) into the take library, without copying it through
   * JavaScript memory.
   */
  importRecording?: (
    meta: NewSession & { durationMs: number; sizeBytes?: number },
    sourceUri: string,
  ) => Promise<ClipMeta | null>;
};

export const webMediaStore: MediaStore = {
  kind: "indexeddb",
  createSession: (s) => webStore.createSession(s),
  appendChunk: webStore.appendChunk,
  finalizeSession: webStore.finalizeSession,
  recoverOrphanSessions: webStore.recoverOrphanSessions,
  listClipMeta: webStore.listClipMeta,
  listAllClips: webStore.listAllClips,
  getClip: webStore.getClip,
  async clipSource(meta) {
    const clip = await webStore.getClip(meta.id);
    if (!clip) return null;
    const src = URL.createObjectURL(clip.blob);
    return { src, revoke: () => URL.revokeObjectURL(src) };
  },
  deleteClip: webStore.deleteClip,
  deleteAllForScript: webStore.deleteAllForScript,
  requestPersistentStorage: webStore.requestPersistentStorage,
  storageUsage: webStore.storageUsage,
  clearAllStorage: webStore.clearAllStorage,
  purgeOrphanChunks: webStore.purgeOrphanChunks,
  repairClip: webStore.repairClip,
  deepRestore: webStore.deepRestore,
  rescueAll: webStore.rescueAll,
};

let resolved: Promise<MediaStore> | null = null;

/** Why the native store could not be used, if it could not. */
let nativeStoreError = "";

export function mediaStoreError(): string {
  return nativeStoreError;
}

/**
 * Resolve the store for this runtime. Inside the iPhone app there is NO silent
 * browser fallback: video belongs in real files on disk, so a native store that
 * refuses to start reports the reason and the failure stays visible.
 */
export function mediaStore(): Promise<MediaStore> {
  resolved ??= (async () => {
    if (!isNative()) return webMediaStore;
    try {
      const { createNativeMediaStore } = await import("./media-store.native");
      const native = await createNativeMediaStore();
      if (native) {
        nativeStoreError = "";
        return native;
      }
      nativeStoreError = "The Filesystem plugin is missing from this build.";
    } catch (e) {
      nativeStoreError =
        (e as { message?: string })?.message || "The app's own storage could not be opened.";
    }
    resolved = null; // let a later attempt succeed once the plugin is there
    throw new Error(`Native video storage is unavailable: ${nativeStoreError}`);
  })();
  return resolved;
}

/**
 * For read-only calls: never throws, so a broken native store shows an empty
 * library plus a visible error instead of crashing the screen. Writes keep
 * using `mediaStore()` so a failed save is always reported.
 */
async function readStore(): Promise<MediaStore> {
  try {
    return await mediaStore();
  } catch {
    return webMediaStore;
  }
}

// ---- the flat API the app uses ------------------------------------------

export const createSession = async (s: NewSession) => (await mediaStore()).createSession(s);
export const appendChunk = async (id: string, blob: Blob) => (await mediaStore()).appendChunk(id, blob);
export const finalizeSession = async (id: string, extra?: { durationMs?: number }) =>
  (await mediaStore()).finalizeSession(id, extra);
export const recoverOrphanSessions = async () => (await readStore()).recoverOrphanSessions();

export const listClipMeta = async (scriptId: string) => (await readStore()).listClipMeta(scriptId);
export const listAllClips = async () => (await readStore()).listAllClips();
export const getClip = async (id: string) => (await readStore()).getClip(id);
export const clipSource = async (meta: ClipMeta) => (await readStore()).clipSource(meta);
export const deleteClip = async (id: string) => (await mediaStore()).deleteClip(id);
export const deleteAllForScript = async (scriptId: string) =>
  (await mediaStore()).deleteAllForScript(scriptId);

export const requestPersistentStorage = async () => (await readStore()).requestPersistentStorage();
export const storageUsage = async () => (await readStore()).storageUsage();
export const clearAllStorage = async () => (await mediaStore()).clearAllStorage();
export const purgeOrphanChunks = async () => (await readStore()).purgeOrphanChunks();

export const repairClip = async (id: string) => (await mediaStore()).repairClip(id);
export const deepRestore = async (id: string) => (await mediaStore()).deepRestore(id);
export const rescueAll = async (scriptId: string) => (await mediaStore()).rescueAll(scriptId);

/** Native file URI for a take, or null on the web (there is no file there). */
export const clipFilePath = async (id: string) => {
  const store = await readStore();
  return store.filePath ? store.filePath(id) : null;
};

/** Adopt a natively recorded file as a take. Native only. */
export const importRecording = async (
  meta: NewSession & { durationMs: number; sizeBytes?: number },
  sourceUri: string,
) => {
  const store = await mediaStore();
  if (!store.importRecording) return null;
  return store.importRecording(meta, sourceUri);
};

export { fmtSize, fmtDuration, assembleBest, measureDuration, probePlayable } from "@/lib/clip-store";
