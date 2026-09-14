import type { PlatformService, ServiceResult } from "../types";

/** Small key/value settings only — never media, never anything large. */
export type SettingsService = PlatformService & {
  /** Load everything into memory once so reads can stay synchronous. */
  hydrate: () => Promise<void>;
  get: <T>(key: string, fallback: T) => T;
  set: <T>(key: string, value: T) => void;
  remove: (key: string) => void;
};

export type StoredFile = {
  id: string;
  /** Web: an object URL or blob handle. Native: a file:// path in app storage. */
  location: string;
  sizeBytes: number;
  mimeType: string;
};

/** Large media. Browser database on web, app filesystem on iOS. */
export type FileStoreService = PlatformService & {
  kind: "indexeddb" | "native-filesystem";
  /** Append one recorded chunk durably; an interrupted save must stay recoverable. */
  appendChunk: (recordingId: string, seq: number, chunk: Blob) => Promise<ServiceResult<void>>;
  read: (id: string) => Promise<Blob | null>;
  remove: (id: string) => Promise<void>;
  usage: () => Promise<{ usedBytes: number; quotaBytes: number | null }>;
};
