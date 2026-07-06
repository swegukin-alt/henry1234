// Tiny IndexedDB wrapper for teleprompter video clips.
// Stores raw Blobs per script. No dependencies.

const DB_NAME = "prompter.clips.v1";
const DB_VERSION = 1;
const STORE = "clips";

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
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
  return dbPromise;
}

function tx(mode: IDBTransactionMode) {
  return openDB().then((db) => db.transaction(STORE, mode).objectStore(STORE));
}

export async function saveClip(rec: ClipRecord): Promise<void> {
  const store = await tx("readwrite");
  await new Promise<void>((resolve, reject) => {
    const req = store.put(rec);
    req.onsuccess = () => resolve();
    req.onerror = () => reject(req.error);
  });
}

export async function listClips(scriptId: string): Promise<ClipRecord[]> {
  const store = await tx("readonly");
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
  const store = await tx("readwrite");
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
