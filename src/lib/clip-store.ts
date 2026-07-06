// Tiny IndexedDB wrapper for teleprompter video clips.
// Stores raw Blobs per script. Also stores in-flight recording chunks so a
// crash/close/reload never loses data — chunks are appended live during
// recording and assembled either on stop or on the next app open (recovery).

const DB_NAME = "prompter.clips.v1";
const DB_VERSION = 2;
const STORE = "clips";
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
  const store = await storeIn(STORE, "readwrite");
  await new Promise<void>((resolve, reject) => {
    const req = store.put(rec);
    req.onsuccess = () => resolve();
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
  const store = await storeIn(STORE, "readwrite");
  await new Promise<void>((resolve, reject) => {
    const req = store.delete(id);
    req.onsuccess = () => resolve();
    req.onerror = () => reject(req.error);
  });
}

export async function deleteAllForScript(scriptId: string): Promise<void> {
  const clips = await listClips(scriptId);
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
