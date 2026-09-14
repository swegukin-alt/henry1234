// Tiny IndexedDB wrapper for teleprompter video clips.
// Stores raw Blobs per script. Also stores in-flight recording chunks so a
// crash/close/reload never loses data — chunks are appended live during
// recording and assembled either on stop or on the next app open (recovery).

const DB_NAME = "prompter.clips.v1";
const DB_VERSION = 3;
const STORE = "clips";
const META_STORE = "clipMeta";
const CHUNK_STORE = "chunks";
const SESSION_STORE = "sessions";

export type ClipMeta = {
  id: string;
  scriptId: string;
  mimeType: string;
  durationMs: number;
  sizeBytes: number;
  createdAt: number;
  width: number;
  height: number;
  // When true the video still lives as its recorded pieces in the chunk store
  // and is stitched together on demand. This makes stopping a take instant and
  // uses half the disk space of keeping a second, combined copy.
  chunked?: boolean;
};

export type ClipRecord = ClipMeta & { blob: Blob };

export type RecordingSession = {
  id: string;
  scriptId: string;
  mimeType: string;
  startedAt: number;
  width: number;
  height: number;
  nextSeq: number;
};

type ChunkRecord = { recordingId: string; seq: number; blob: Blob };

let dbPromise: Promise<IDBDatabase> | null = null;

function openDB(): Promise<IDBDatabase> {
  if (dbPromise) return dbPromise;
  dbPromise = new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, DB_VERSION);
    req.onupgradeneeded = () => {
      const db = req.result;
      if (!db.objectStoreNames.contains(STORE)) {
        const store = db.createObjectStore(STORE, { keyPath: "id" });
        store.createIndex("scriptId", "scriptId", { unique: false });
        store.createIndex("createdAt", "createdAt", { unique: false });
      }
      if (!db.objectStoreNames.contains(CHUNK_STORE)) {
        const cs = db.createObjectStore(CHUNK_STORE, { keyPath: ["recordingId", "seq"] });
        cs.createIndex("recordingId", "recordingId", { unique: false });
      }
      if (!db.objectStoreNames.contains(SESSION_STORE)) {
        db.createObjectStore(SESSION_STORE, { keyPath: "id" });
      }
      if (!db.objectStoreNames.contains(META_STORE)) {
        const meta = db.createObjectStore(META_STORE, { keyPath: "id" });
        meta.createIndex("scriptId", "scriptId", { unique: false });
        meta.createIndex("createdAt", "createdAt", { unique: false });
        const oldStore = req.transaction?.objectStore(STORE);
        const cursor = oldStore?.openCursor();
        if (cursor) cursor.onsuccess = () => {
          const row = cursor.result;
          if (!row) return;
          const { blob: _blob, ...metadata } = row.value as ClipRecord;
          meta.put(metadata);
          row.continue();
        };
      }
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
  return dbPromise;
}

function storeIn(name: string, mode: IDBTransactionMode) {
  return openDB().then((db) => db.transaction(name, mode).objectStore(name));
}

// Ask the browser to keep our data even under storage pressure.
// Silent if unsupported. Call once when video mode opens.
export async function requestPersistentStorage(): Promise<boolean> {
  try {
    if (navigator.storage && (navigator.storage as any).persist) {
      return await navigator.storage.persist();
    }
  } catch {}
  return false;
}

export async function saveClip(rec: ClipRecord): Promise<void> {
  const db = await openDB();
  await new Promise<void>((resolve, reject) => {
    const transaction = db.transaction([STORE, META_STORE], "readwrite");
    const { blob: _blob, ...metadata } = rec;
    transaction.objectStore(STORE).put(rec);
    transaction.objectStore(META_STORE).put(metadata);
    transaction.oncomplete = () => resolve();
    transaction.onerror = () => reject(transaction.error);
    transaction.onabort = () => reject(transaction.error || new Error("Could not save recording"));
  });
}

export async function getClip(id: string): Promise<ClipRecord | null> {
  const store = await storeIn(STORE, "readonly");
  return new Promise((resolve, reject) => {
    const req = store.get(id);
    req.onsuccess = () => resolve((req.result as ClipRecord | undefined) || null);
    req.onerror = () => reject(req.error);
  });
}

export async function listClips(scriptId: string): Promise<ClipRecord[]> {
  const store = await storeIn(STORE, "readonly");
  return new Promise((resolve, reject) => {
    const req = store.index("scriptId").getAll(IDBKeyRange.only(scriptId));
    req.onsuccess = () => {
      const arr = (req.result as ClipRecord[]).sort((a, b) => a.createdAt - b.createdAt);
      resolve(arr);
    };
    req.onerror = () => reject(req.error);
  });
}

export async function deleteClip(id: string): Promise<void> {
  const db = await openDB();
  await new Promise<void>((resolve, reject) => {
    const transaction = db.transaction([STORE, META_STORE], "readwrite");
    transaction.objectStore(STORE).delete(id);
    transaction.objectStore(META_STORE).delete(id);
    transaction.oncomplete = () => resolve();
    transaction.onerror = () => reject(transaction.error);
  });
}

export async function deleteAllForScript(scriptId: string): Promise<void> {
  const clips = await listClipMeta(scriptId);
  await Promise.all(clips.map((c) => deleteClip(c.id)));
}

// ============ Live recording session (crash-safe) ============

export async function createSession(s: Omit<RecordingSession, "nextSeq">): Promise<void> {
  const store = await storeIn(SESSION_STORE, "readwrite");
  await new Promise<void>((resolve, reject) => {
    const req = store.put({ ...s, nextSeq: 0 });
    req.onsuccess = () => resolve();
    req.onerror = () => reject(req.error);
  });
}

export async function updateSession(id: string, patch: Partial<RecordingSession>): Promise<void> {
  const store = await storeIn(SESSION_STORE, "readwrite");
  await new Promise<void>((resolve, reject) => {
    const getReq = store.get(id);
    getReq.onsuccess = () => {
      const cur = getReq.result as RecordingSession | undefined;
      if (!cur) return resolve();
      const putReq = store.put({ ...cur, ...patch });
      putReq.onsuccess = () => resolve();
      putReq.onerror = () => reject(putReq.error);
    };
    getReq.onerror = () => reject(getReq.error);
  });
}

// Append one MediaRecorder chunk. Runs its own transaction so a failure to
// write chunk N never poisons chunk N+1.
export async function appendChunk(recordingId: string, blob: Blob): Promise<number> {
  const db = await openDB();
  return new Promise<number>((resolve, reject) => {
    const t = db.transaction([SESSION_STORE, CHUNK_STORE], "readwrite");
    const sessions = t.objectStore(SESSION_STORE);
    const chunks = t.objectStore(CHUNK_STORE);
    const getReq = sessions.get(recordingId);
    let seq = 0;
    getReq.onsuccess = () => {
      const cur = getReq.result as RecordingSession | undefined;
      if (!cur) { t.abort(); return reject(new Error("session missing")); }
      seq = cur.nextSeq;
      chunks.put({ recordingId, seq, blob } as ChunkRecord);
      sessions.put({ ...cur, nextSeq: seq + 1 });
    };
    t.oncomplete = () => resolve(seq);
    t.onerror = () => reject(t.error);
    t.onabort = () => reject(t.error || new Error("aborted"));
  });
}

async function getSession(id: string): Promise<RecordingSession | undefined> {
  const store = await storeIn(SESSION_STORE, "readonly");
  return new Promise((resolve, reject) => {
    const req = store.get(id);
    req.onsuccess = () => resolve(req.result as RecordingSession | undefined);
    req.onerror = () => reject(req.error);
  });
}

async function getChunks(recordingId: string): Promise<Blob[]> {
  const store = await storeIn(CHUNK_STORE, "readonly");
  return new Promise((resolve, reject) => {
    const req = store.index("recordingId").getAll(IDBKeyRange.only(recordingId));
    req.onsuccess = () => {
      const arr = (req.result as ChunkRecord[]).sort((a, b) => a.seq - b.seq).map((c) => c.blob);
      resolve(arr);
    };
    req.onerror = () => reject(req.error);
  });
}

async function clearSession(recordingId: string): Promise<void> {
  const db = await openDB();
  await new Promise<void>((resolve, reject) => {
    const t = db.transaction([SESSION_STORE, CHUNK_STORE], "readwrite");
    t.objectStore(SESSION_STORE).delete(recordingId);
    const idx = t.objectStore(CHUNK_STORE).index("recordingId");
    const cursorReq = idx.openCursor(IDBKeyRange.only(recordingId));
    cursorReq.onsuccess = () => {
      const cursor = cursorReq.result;
      if (cursor) { cursor.delete(); cursor.continue(); }
    };
    t.oncomplete = () => resolve();
    t.onerror = () => reject(t.error);
    t.onabort = () => reject(t.error);
  });
}

// Assemble whatever chunks exist for `recordingId` and store as a finalized
// ClipRecord. Returns the record (or null if there were no chunks). Cleans up
// the session + chunks on success.
export async function finalizeSession(
  recordingId: string,
  extra?: { durationMs?: number }
): Promise<ClipRecord | null> {
  const session = await getSession(recordingId);
  if (!session) return null;
  const chunks = await getChunks(recordingId);
  if (chunks.length === 0) { await clearSession(recordingId); return null; }
  const blob = new Blob(chunks, { type: session.mimeType });
  const rec: ClipRecord = {
    id: recordingId,
    scriptId: session.scriptId,
    mimeType: session.mimeType,
    durationMs: extra?.durationMs ?? Math.max(0, Date.now() - session.startedAt),
    sizeBytes: blob.size,
    createdAt: session.startedAt,
    width: session.width,
    height: session.height,
    blob,
  };
  await saveClip(rec);
  await clearSession(recordingId);
  return rec;
}

// On app open: recover any sessions left in the DB from a prior crash / close.
export async function recoverOrphanSessions(): Promise<ClipRecord[]> {
  const store = await storeIn(SESSION_STORE, "readonly");
  const all = await new Promise<RecordingSession[]>((resolve, reject) => {
    const req = store.getAll();
    req.onsuccess = () => resolve(req.result as RecordingSession[]);
    req.onerror = () => reject(req.error);
  });
  const recovered: ClipRecord[] = [];
  for (const s of all) {
    try {
      const rec = await finalizeSession(s.id);
      if (rec) recovered.push(rec);
    } catch {}
  }
  return recovered;
}

// Format bytes for display
export function fmtSize(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(0)} KB`;
  if (n < 1024 * 1024 * 1024) return `${(n / 1024 / 1024).toFixed(1)} MB`;
  return `${(n / 1024 / 1024 / 1024).toFixed(2)} GB`;
}

export function fmtDuration(ms: number): string {
  const s = Math.round(ms / 1000);
  const m = Math.floor(s / 60);
  const r = s % 60;
  return `${m}:${r.toString().padStart(2, "0")}`;
}

// ============ Rescue / repair ============
// A clip can end up unplayable ("play button with a slash") for a handful of
// concrete reasons on iOS: the stored MIME string doesn't match the actual
// container, the first chunk (which carries the mp4 ftyp/moov header) never
// made it to disk, or the tail chunk is truncated. These helpers diagnose and
// rebuild the file from whatever bytes still exist.

export type RepairReport = {
  container: "mp4" | "webm" | "unknown";
  hadHeader: boolean;
  chunkCount: number;
  bytes: number;
  changedMime: boolean;
  rebuiltFromChunks: boolean;
  playable: boolean;
};

async function sniff(blob: Blob): Promise<{ container: RepairReport["container"]; hasHeader: boolean }> {
  const head = new Uint8Array(await blob.slice(0, 4096).arrayBuffer());
  if (head[0] === 0x1a && head[1] === 0x45 && head[2] === 0xdf && head[3] === 0xa3) {
    return { container: "webm", hasHeader: true };
  }
  // look for an 'ftyp' box near the start (mp4 / QuickTime)
  for (let i = 0; i < Math.min(head.length - 4, 2048); i++) {
    if (head[i] === 0x66 && head[i + 1] === 0x74 && head[i + 2] === 0x79 && head[i + 3] === 0x70) {
      return { container: "mp4", hasHeader: true };
    }
  }
  // moof-only data = fragments without a header
  for (let i = 0; i < Math.min(head.length - 4, 2048); i++) {
    if (head[i] === 0x6d && head[i + 1] === 0x6f && head[i + 2] === 0x6f && head[i + 3] === 0x66) {
      return { container: "mp4", hasHeader: false };
    }
  }
  return { container: "unknown", hasHeader: false };
}

// Can the browser actually decode this blob?
export function probePlayable(blob: Blob, timeoutMs = 6000): Promise<boolean> {
  return new Promise((resolve) => {
    const url = URL.createObjectURL(blob);
    const v = document.createElement("video");
    let done = false;
    const finish = (ok: boolean) => {
      if (done) return;
      done = true;
      v.removeAttribute("src");
      try { v.load(); } catch {}
      URL.revokeObjectURL(url);
      resolve(ok);
    };
    v.muted = true;
    (v as any).playsInline = true;
    v.preload = "metadata";
    v.onloadedmetadata = () => finish(true);
    v.onerror = () => finish(false);
    window.setTimeout(() => finish(false), timeoutMs);
    v.src = url;
  });
}

// Rebuild a clip from every byte we still have and store the fixed version.
export async function repairClip(id: string): Promise<{ clip: ClipRecord | null; report: RepairReport }> {
  const store = await storeIn(STORE, "readonly");
  const existing = await new Promise<ClipRecord | undefined>((resolve, reject) => {
    const req = store.get(id);
    req.onsuccess = () => resolve(req.result as ClipRecord | undefined);
    req.onerror = () => reject(req.error);
  });

  // Prefer raw chunks when they survived — they are the closest thing to the
  // original wire data and preserve ordering.
  const chunks = await getChunks(id).catch(() => [] as Blob[]);
  const session = await getSession(id).catch(() => undefined);

  const base = existing;
  let rebuiltFromChunks = false;
  let bytes: Blob | null = null;

  if (chunks.length > 0 && (!base || chunks.reduce((n, c) => n + c.size, 0) >= base.sizeBytes)) {
    bytes = new Blob(chunks);
    rebuiltFromChunks = true;
  } else if (base) {
    bytes = base.blob;
  }

  if (!bytes || bytes.size === 0) {
    return { clip: null, report: { container: "unknown", hadHeader: false, chunkCount: chunks.length, bytes: 0, changedMime: false, rebuiltFromChunks, playable: false } };
  }

  const { container, hasHeader } = await sniff(bytes);
  const correctMime = container === "webm" ? "video/webm" : container === "mp4" ? "video/mp4" : (base?.mimeType || session?.mimeType || "video/mp4");
  const changedMime = (base?.mimeType || "").split(";")[0] !== correctMime;

  let fixed = new Blob([bytes], { type: correctMime });
  let playable = await probePlayable(fixed);

  // Truncated tail: MediaRecorder can die mid-chunk. Dropping the last chunk
  // usually restores a decodable file (you lose at most ~1s at the end).
  if (!playable && chunks.length > 1) {
    for (const drop of [1, 2]) {
      if (chunks.length - drop <= 0) break;
      const trial = new Blob(chunks.slice(0, chunks.length - drop), { type: correctMime });
      // eslint-disable-next-line no-await-in-loop
      if (await probePlayable(trial)) { fixed = trial; playable = true; rebuiltFromChunks = true; break; }
    }
  }

  const rec: ClipRecord = {
    id,
    scriptId: base?.scriptId || session?.scriptId || "",
    mimeType: correctMime,
    durationMs: base?.durationMs || (session ? Math.max(0, Date.now() - session.startedAt) : 0),
    sizeBytes: fixed.size,
    createdAt: base?.createdAt || session?.startedAt || Date.now(),
    width: base?.width || session?.width || 0,
    height: base?.height || session?.height || 0,
    blob: fixed,
  };
  if (rec.scriptId) await saveClip(rec);

  return {
    clip: rec,
    report: { container, hadHeader: hasHeader, chunkCount: chunks.length, bytes: fixed.size, changedMime, rebuiltFromChunks, playable },
  };
}

// Everything still sitting in the database, playable or not, including
// half-finished sessions that were never turned into clips.
export async function rescueAll(scriptId: string): Promise<ClipRecord[]> {
  await recoverOrphanSessions();
  const store = await storeIn(SESSION_STORE, "readonly");
  const sessions = await new Promise<RecordingSession[]>((resolve, reject) => {
    const req = store.getAll();
    req.onsuccess = () => resolve(req.result as RecordingSession[]);
    req.onerror = () => reject(req.error);
  });
  for (const s of sessions) {
    try { await repairClip(s.id); } catch {}
  }
  return listClips(scriptId);
}

// Every saved clip across all scripts, newest first.
export async function listAllClips(): Promise<ClipMeta[]> {
  await recoverOrphanSessions();
  const store = await storeIn(META_STORE, "readonly");
  return new Promise((resolve, reject) => {
    const req = store.getAll();
    req.onsuccess = () => resolve((req.result as ClipMeta[]).sort((a, b) => (b.createdAt - a.createdAt) || b.id.localeCompare(a.id)));
    req.onerror = () => reject(req.error);
  });
}

export async function listClipMeta(scriptId: string): Promise<ClipMeta[]> {
  const store = await storeIn(META_STORE, "readonly");
  return new Promise((resolve, reject) => {
    const req = store.index("scriptId").getAll(IDBKeyRange.only(scriptId));
    req.onsuccess = () => resolve((req.result as ClipMeta[]).sort((a, b) => (b.createdAt - a.createdAt) || b.id.localeCompare(a.id)));
    req.onerror = () => reject(req.error);
  });
}

// Every byte we still have for a recording: the finalized clip AND any raw
// chunks that survived (a take can end up truncated if a chunk write failed
// near the end). Returns whichever is longer, without dropping anything.
export async function assembleBest(clip: ClipRecord): Promise<ClipRecord> {
  let chunks: Blob[] = [];
  try { chunks = await getChunks(clip.id); } catch {}
  const chunkBytes = chunks.reduce((n, c) => n + c.size, 0);
  if (chunkBytes <= (clip.blob?.size || 0)) return clip;
  const mime = (clip.mimeType || "video/mp4").split(";")[0].trim();
  const blob = new Blob(chunks, { type: mime });
  return { ...clip, blob, sizeBytes: blob.size };
}

// ============ Deep restore ============
// A take can decode short (e.g. plays 25:00 of a 32:47 recording) when the
// final fragment was cut mid-write: players stop at the last fragment they can
// parse and ignore everything after it. Walking the container's top-level box
// structure and cutting at the last COMPLETE box yields a file that decodes to
// its true length, losing at most the final partial second.

async function readU8(blob: Blob, start: number, len: number): Promise<Uint8Array> {
  return new Uint8Array(await blob.slice(start, start + len).arrayBuffer());
}

// Returns the byte offset of the end of the last complete top-level mp4 box.
async function mp4LastCompleteOffset(blob: Blob): Promise<number> {
  let pos = 0;
  let lastGood = 0;
  const size = blob.size;
  while (pos + 8 <= size) {
    const hdr = await readU8(blob, pos, 16);
    const view = new DataView(hdr.buffer, hdr.byteOffset, hdr.byteLength);
    let boxSize = view.getUint32(0);
    let headerLen = 8;
    if (boxSize === 1) {
      if (hdr.byteLength < 16) break;
      const hi = view.getUint32(8);
      const lo = view.getUint32(12);
      boxSize = hi * 2 ** 32 + lo;
      headerLen = 16;
    } else if (boxSize === 0) {
      // extends to end of file — treat as complete
      lastGood = size;
      break;
    }
    if (boxSize < headerLen) break; // malformed, stop here
    if (pos + boxSize > size) break; // truncated tail
    pos += boxSize;
    lastGood = pos;
  }
  return lastGood;
}

// Actual decodable duration in ms (handles fragmented files with no duration).
export function measureDuration(blob: Blob, timeoutMs = 20000): Promise<number> {
  return new Promise((resolve) => {
    const url = URL.createObjectURL(blob);
    const v = document.createElement("video");
    let done = false;
    const finish = (ms: number) => {
      if (done) return;
      done = true;
      v.removeAttribute("src");
      try { v.load(); } catch {}
      URL.revokeObjectURL(url);
      resolve(ms);
    };
    v.muted = true;
    (v as any).playsInline = true;
    v.preload = "metadata";
    v.onloadedmetadata = () => {
      if (Number.isFinite(v.duration) && v.duration > 0) return finish(v.duration * 1000);
      // Fragmented / unknown duration: seek far past the end and read back.
      v.onseeked = () => finish((v.duration && Number.isFinite(v.duration) ? v.duration : v.currentTime) * 1000);
      try { v.currentTime = 1e7; } catch { finish(0); }
    };
    v.onerror = () => finish(0);
    window.setTimeout(() => finish(0), timeoutMs);
    v.src = url;
  });
}

export type RestoreReport = {
  bytes: number;
  trimmedBytes: number;
  durationMs: number;
  previousDurationMs: number;
  playable: boolean;
  rebuiltFromChunks: boolean;
};

// Rebuild a clip to its full recoverable length and persist the result.
export async function deepRestore(id: string): Promise<{ clip: ClipRecord | null; report: RestoreReport }> {
  const store = await storeIn(STORE, "readonly");
  const base = await new Promise<ClipRecord | undefined>((resolve, reject) => {
    const req = store.get(id);
    req.onsuccess = () => resolve(req.result as ClipRecord | undefined);
    req.onerror = () => reject(req.error);
  });
  const chunks = await getChunks(id).catch(() => [] as Blob[]);
  const session = await getSession(id).catch(() => undefined);

  const chunkBytes = chunks.reduce((n, c) => n + c.size, 0);
  const rebuiltFromChunks = chunkBytes > (base?.blob?.size || 0);
  const raw = rebuiltFromChunks ? new Blob(chunks) : base?.blob;

  const empty: RestoreReport = {
    bytes: 0, trimmedBytes: 0, durationMs: 0, previousDurationMs: base?.durationMs || 0,
    playable: false, rebuiltFromChunks,
  };
  if (!raw || raw.size === 0) return { clip: null, report: empty };

  const { container } = await sniff(raw);
  const mime = container === "webm" ? "video/webm" : container === "mp4" ? "video/mp4"
    : (base?.mimeType || session?.mimeType || "video/mp4").split(";")[0].trim();

  let best = new Blob([raw], { type: mime });
  let bestDur = await measureDuration(best);
  let trimmedBytes = 0;

  if (container === "mp4") {
    const cut = await mp4LastCompleteOffset(raw);
    if (cut > 0 && cut < raw.size) {
      const trial = new Blob([raw.slice(0, cut)], { type: mime });
      const dur = await measureDuration(trial);
      if (dur > bestDur) { best = trial; bestDur = dur; trimmedBytes = raw.size - cut; }
    }
  }

  // Last resort for any container: shave trailing chunks until it decodes.
  if (bestDur === 0 && chunks.length > 1) {
    for (let drop = 1; drop <= Math.min(3, chunks.length - 1); drop++) {
      const trial = new Blob(chunks.slice(0, chunks.length - drop), { type: mime });
      // eslint-disable-next-line no-await-in-loop
      const dur = await measureDuration(trial);
      if (dur > 0) { best = trial; bestDur = dur; trimmedBytes = raw.size - trial.size; break; }
    }
  }

  const rec: ClipRecord = {
    id,
    scriptId: base?.scriptId || session?.scriptId || "",
    mimeType: mime,
    durationMs: bestDur > 0 ? bestDur : (base?.durationMs || 0),
    sizeBytes: best.size,
    createdAt: base?.createdAt || session?.startedAt || Date.now(),
    width: base?.width || session?.width || 0,
    height: base?.height || session?.height || 0,
    blob: best,
  };
  if (rec.scriptId) await saveClip(rec);

  return {
    clip: rec,
    report: {
      bytes: best.size,
      trimmedBytes,
      durationMs: bestDur,
      previousDurationMs: base?.durationMs || 0,
      playable: bestDur > 0,
      rebuiltFromChunks,
    },
  };
}
