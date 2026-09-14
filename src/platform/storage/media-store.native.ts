// iOS media store: every take is a real file in the app's own storage.
//
// Layout inside Directory.Data:
//   recordings/<id>.mp4      the video itself, appended chunk by chunk
//   recordings/index.json    small metadata index (finished takes + live sessions)
//
// Chunks are appended as they arrive, so a crash, a phone call or a forced
// quit leaves a real, playable file behind — recovery just re-reads the index.
// Nothing here ever runs in the browser: the module is only imported when a
// Capacitor native runtime is detected, and the plugin specifier stays dynamic
// so the website bundle never resolves it.

import { convertFileSrc, hasPlugin } from "../runtime";
import type { ClipMeta, ClipRecord, MediaStore, NewSession } from "./media-store";
import type { RepairReport, RestoreReport } from "@/lib/clip-store";

import { loadModule, PLUGIN_MODULES } from "../native-plugins";
const DIR = "recordings";
const INDEX_PATH = `${DIR}/index.json`;

type Directory = string;

type FilesystemPlugin = {
  mkdir: (o: { path: string; directory: Directory; recursive: boolean }) => Promise<void>;
  readFile: (o: { path: string; directory: Directory; encoding?: string }) => Promise<{ data: string | Blob }>;
  writeFile: (o: {
    path: string;
    directory: Directory;
    data: string;
    encoding?: string;
    recursive?: boolean;
  }) => Promise<{ uri: string }>;
  appendFile: (o: { path: string; directory: Directory; data: string; encoding?: string }) => Promise<void>;
  deleteFile: (o: { path: string; directory: Directory }) => Promise<void>;
  stat: (o: { path: string; directory?: Directory }) => Promise<{ size: number; uri: string }>;
  getUri: (o: { path: string; directory: Directory }) => Promise<{ uri: string }>;
  rename: (o: { from: string; to: string; directory?: Directory; toDirectory?: Directory }) => Promise<void>;
  copy: (o: { from: string; to: string; directory?: Directory; toDirectory?: Directory }) => Promise<void>;
};

type FsModule = { Filesystem?: FilesystemPlugin; Directory?: Record<string, string> };

type IndexEntry = ClipMeta & { file: string; open?: boolean };
type IndexFile = { clips: IndexEntry[] };

function filenameFor(id: string, mimeType: string): string {
  const ext = /webm/i.test(mimeType) ? "webm" : "mp4";
  return `${DIR}/${id}.${ext}`;
}

async function blobToBase64(blob: Blob): Promise<string> {
  const buf = new Uint8Array(await blob.arrayBuffer());
  let binary = "";
  const CHUNK = 0x8000; // stay well inside the argument limit for long takes
  for (let i = 0; i < buf.length; i += CHUNK) {
    binary += String.fromCharCode(...buf.subarray(i, i + CHUNK));
  }
  return btoa(binary);
}

export async function createNativeMediaStore(): Promise<MediaStore | null> {
  if (!hasPlugin("Filesystem")) return null;
  const mod = await loadModule<FsModule>(PLUGIN_MODULES.filesystem);
  if (!mod) return null;
  const Filesystem = mod.Filesystem;
  const DATA: Directory = mod.Directory?.Data ?? "DATA";
  if (!Filesystem) return null;

  try {
    await Filesystem.mkdir({ path: DIR, directory: DATA, recursive: true });
  } catch {
    /* already there */
  }

  let index: IndexFile | null = null;
  let writeQueue: Promise<void> = Promise.resolve();

  async function readIndex(): Promise<IndexFile> {
    if (index) return index;
    try {
      const res = await Filesystem!.readFile({ path: INDEX_PATH, directory: DATA, encoding: "utf8" });
      const text = typeof res.data === "string" ? res.data : await res.data.text();
      const parsed = JSON.parse(text) as IndexFile;
      index = { clips: Array.isArray(parsed.clips) ? parsed.clips : [] };
    } catch {
      index = { clips: [] };
    }
    return index;
  }

  function saveIndex(): Promise<void> {
    const snapshot = JSON.stringify(index ?? { clips: [] });
    writeQueue = writeQueue
      .catch(() => {})
      .then(() =>
        Filesystem!
          .writeFile({ path: INDEX_PATH, directory: DATA, data: snapshot, encoding: "utf8", recursive: true })
          .then(() => undefined),
      );
    return writeQueue;
  }

  async function entry(id: string): Promise<IndexEntry | undefined> {
    return (await readIndex()).clips.find((c) => c.id === id);
  }

  async function metaOf(id: string): Promise<ClipMeta | null> {
    const e = await entry(id);
    if (!e) return null;
    const { file: _file, open: _open, ...meta } = e;
    return meta;
  }

  async function readBlob(e: IndexEntry): Promise<Blob | null> {
    try {
      const res = await Filesystem!.readFile({ path: e.file, directory: DATA });
      if (res.data instanceof Blob) return res.data;
      const binary = atob(res.data);
      const bytes = new Uint8Array(binary.length);
      for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
      return new Blob([bytes], { type: e.mimeType.split(";")[0].trim() });
    } catch {
      return null;
    }
  }

  async function currentSize(e: IndexEntry): Promise<number> {
    try {
      const s = await Filesystem!.stat({ path: e.file, directory: DATA });
      return s.size || e.sizeBytes || 0;
    } catch {
      return e.sizeBytes || 0;
    }
  }

  async function removeEntry(id: string): Promise<void> {
    const e = await entry(id);
    if (!e) return;
    try {
      await Filesystem!.deleteFile({ path: e.file, directory: DATA });
    } catch {
      /* already gone */
    }
    index!.clips = index!.clips.filter((c) => c.id !== id);
    await saveIndex();
  }

  const noRepair = async (id: string) => {
    // A real file needs no stitching: report the truth rather than pretending
    // to rebuild something.
    const meta = await metaOf(id);
    const e = await entry(id);
    const clip = meta && e ? { ...meta, blob: (await readBlob(e)) ?? new Blob() } : null;
    return clip;
  };

  const store: MediaStore = {
    kind: "native-filesystem",

    async createSession(s: NewSession) {
      const idx = await readIndex();
      const file = filenameFor(s.id, s.mimeType);
      // Start the file empty so the very first append has something to grow.
      await Filesystem.writeFile({ path: file, directory: DATA, data: "", recursive: true });
      idx.clips = [
        {
          id: s.id,
          scriptId: s.scriptId,
          mimeType: s.mimeType,
          durationMs: 0,
          sizeBytes: 0,
          createdAt: s.startedAt,
          width: s.width,
          height: s.height,
          file,
          open: true,
        },
        ...idx.clips.filter((c) => c.id !== s.id),
      ];
      await saveIndex();
    },

    async appendChunk(recordingId, blob) {
      const e = await entry(recordingId);
      if (!e) throw new Error("session missing");
      const data = await blobToBase64(blob);
      await Filesystem.appendFile({ path: e.file, directory: DATA, data });
      e.sizeBytes += blob.size;
      return e.sizeBytes;
    },

    async finalizeSession(recordingId, extra) {
      const e = await entry(recordingId);
      if (!e) return null;
      e.open = false;
      e.sizeBytes = await currentSize(e);
      e.durationMs = extra?.durationMs ?? Math.max(0, Date.now() - e.createdAt);
      await saveIndex();
      if (e.sizeBytes === 0) {
        await removeEntry(recordingId);
        return null;
      }
      const meta = (await metaOf(recordingId))!;
      // The list only needs metadata; the blob is read on demand so a
      // multi-gigabyte take never has to sit in memory.
      return { ...meta, blob: new Blob([], { type: e.mimeType }) };
    },

    async recoverOrphanSessions() {
      const idx = await readIndex();
      const out: ClipRecord[] = [];
      for (const e of idx.clips.filter((c) => c.open)) {
        e.open = false;
        e.sizeBytes = await currentSize(e);
        if (e.sizeBytes === 0) continue;
        if (!e.durationMs) e.durationMs = 0;
        const { file: _f, open: _o, ...meta } = e;
        out.push({ ...meta, blob: new Blob([], { type: e.mimeType }) });
      }
      // Drop empty leftovers, keep everything that has footage.
      const empty = idx.clips.filter((c) => c.sizeBytes === 0).map((c) => c.id);
      for (const id of empty) await removeEntry(id);
      await saveIndex();
      return out;
    },

    async listClipMeta(scriptId) {
      const idx = await readIndex();
      return idx.clips
        .filter((c) => c.scriptId === scriptId && !c.open)
        .map(({ file: _f, open: _o, ...m }) => m)
        .sort((a, b) => b.createdAt - a.createdAt || b.id.localeCompare(a.id));
    },

    async listAllClips() {
      const idx = await readIndex();
      return idx.clips
        .filter((c) => !c.open)
        .map(({ file: _f, open: _o, ...m }) => m)
        .sort((a, b) => b.createdAt - a.createdAt || b.id.localeCompare(a.id));
    },

    async getClip(id) {
      const e = await entry(id);
      if (!e) return null;
      const blob = await readBlob(e);
      if (!blob) return null;
      const { file: _f, open: _o, ...meta } = e;
      return { ...meta, blob, sizeBytes: blob.size };
    },

    async clipSource(meta) {
      const e = await entry(meta.id);
      if (!e) return null;
      const { uri } = await Filesystem.getUri({ path: e.file, directory: DATA });
      // Streamed straight off disk by the WebView — no blob URL, no copy.
      return { src: convertFileSrc(uri), revoke: () => {}, path: uri };
    },

    deleteClip: removeEntry,

    async deleteAllForScript(scriptId) {
      const idx = await readIndex();
      for (const c of idx.clips.filter((x) => x.scriptId === scriptId)) await removeEntry(c.id);
    },

    async requestPersistentStorage() {
      return true; // app-local files are already durable on iOS
    },

    async storageUsage() {
      const idx = await readIndex();
      let clipBytes = 0;
      for (const c of idx.clips) clipBytes += await currentSize(c);
      return { clipBytes, usage: clipBytes, quota: 0 };
    },

    async clearAllStorage() {
      const idx = await readIndex();
      for (const c of [...idx.clips]) await removeEntry(c.id);
      index = { clips: [] };
      await saveIndex();
    },

    async purgeOrphanChunks() {
      // No separate pieces exist on a filesystem store; only empty leftovers.
      const idx = await readIndex();
      const dead = [];
      for (const c of idx.clips) if ((await currentSize(c)) === 0) dead.push(c.id);
      for (const id of dead) await removeEntry(id);
      return dead.length;
    },

    async repairClip(id) {
      const clip = await noRepair(id);
      const bytes = clip?.blob.size ?? 0;
      const report: RepairReport = {
        container: /webm/i.test(clip?.mimeType ?? "") ? "webm" : "mp4",
        hadHeader: bytes > 0,
        chunkCount: bytes > 0 ? 1 : 0,
        bytes,
        changedMime: false,
        rebuiltFromChunks: false,
        playable: bytes > 0,
      };
      return { clip, report };
    },

    async deepRestore(id) {
      const clip = await noRepair(id);
      const bytes = clip?.blob.size ?? 0;
      const report: RestoreReport = {
        bytes,
        trimmedBytes: 0,
        durationMs: clip?.durationMs ?? 0,
        previousDurationMs: clip?.durationMs ?? 0,
        playable: bytes > 0,
        rebuiltFromChunks: false,
      };
      return { clip, report };
    },

    async rescueAll(scriptId) {
      const metas = await store.listClipMeta(scriptId);
      return metas.map((m) => ({ ...m, blob: new Blob([], { type: m.mimeType }) }));
    },

    async filePath(id) {
      const e = await entry(id);
      if (!e) return null;
      const { uri } = await Filesystem.getUri({ path: e.file, directory: DATA });
      return uri;
    },

    // The native camera writes the whole take itself, so adopting it is a move
    // on disk: no chunks, no base64, nothing through JavaScript memory.
    async importRecording(meta, sourceUri) {
      const idx = await readIndex();
      const file = filenameFor(meta.id, meta.mimeType);
      try {
        await Filesystem.rename({ from: sourceUri, to: file, toDirectory: DATA });
      } catch {
        // Across volumes iOS refuses a move; a copy is the correct fallback and
        // the original stays put until the copy succeeded.
        await Filesystem.copy({ from: sourceUri, to: file, toDirectory: DATA });
        try {
          await Filesystem.deleteFile({ path: sourceUri, directory: undefined as unknown as Directory });
        } catch {
          /* the temporary file is cleaned up by iOS */
        }
      }
      let size = meta.sizeBytes ?? 0;
      try {
        size = (await Filesystem.stat({ path: file, directory: DATA })).size || size;
      } catch {
        /* keep the reported size */
      }
      if (!size) throw new Error("The recording file is empty.");
      const record: IndexEntry = {
        id: meta.id,
        scriptId: meta.scriptId,
        mimeType: meta.mimeType,
        durationMs: meta.durationMs,
        sizeBytes: size,
        createdAt: meta.startedAt,
        width: meta.width,
        height: meta.height,
        file,
      };
      idx.clips = [record, ...idx.clips.filter((c) => c.id !== meta.id)];
      await saveIndex();
      const { file: _f, open: _o, ...out } = record;
      return out;
    },
  };

  return store;
}
