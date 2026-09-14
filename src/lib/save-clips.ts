// Saving a recording off the phone.
//
// Long recordings are stored as a sequence of self-contained parts. Saving a
// take walks that queue one part at a time: each part is a normal-size video,
// so iPhone's share sheet accepts it. Parts that are still large go through the
// browser download manager (Files > Downloads) instead.
//
// The stored playable Blob is reused unchanged in every path — never rebuilt,
// never duplicated in memory.

import type { ClipMeta, ClipRecord } from "./clip-store";
import { fmtSize, getClip } from "./clip-store";

export type SaveJob = {
  phase: "working" | "ready" | "done" | "error";
  title: string;
  detail: string;
  startedAt: number;
  file: File | null;
  bytes: number;
  download: (f: File) => void;
  openInPlayer: (f: File) => void;
  actionLabel?: string;
  runPrimary?: () => void;
  // Progress across the whole take
  partIndex: number;   // 0-based index of the part being saved
  partCount: number;
  savedBytes: number;
  totalBytes: number;
};

// iPhone Web Share commonly refuses large local attachments before its menu
// opens. Downloads do not pass through that attachment handoff.
const IPHONE_SHARE_SAFE_BYTES = 256 * 1024 * 1024;
const activeDownloadUrls = new Set<string>();

function downloadFile(f: File) {
  const url = URL.createObjectURL(f);
  // Keep the URL alive. Safari's download manager may continue reading a long
  // video after this page has been backgrounded; timed revocation can truncate
  // an otherwise healthy recording.
  activeDownloadUrls.add(url);
  const a = document.createElement("a");
  a.href = url;
  a.download = f.name;
  a.rel = "noopener";
  document.body.appendChild(a);
  a.click();
  a.remove();
}

function openInPlayer(f: File) {
  const url = URL.createObjectURL(f);
  const w = window.open(url, "_blank");
  if (!w) location.href = url;
  setTimeout(() => URL.revokeObjectURL(url), 10 * 60 * 1000);
}

// Preserve the container the recorder actually produced. Giving iOS an mp4
// filename around WebM bytes makes navigator.share reject the payload before
// the native sheet appears.
async function toFile(rec: ClipRecord, base: string, partIndex: number, partCount: number): Promise<File> {
  const head = new Uint8Array(await rec.blob.slice(0, 64).arrayBuffer());
  const isWebM = head[0] === 0x1a && head[1] === 0x45 && head[2] === 0xdf && head[3] === 0xa3;
  const hasFtyp = head.some((byte, index) =>
    byte === 0x66 && head[index + 1] === 0x74 && head[index + 2] === 0x79 && head[index + 3] === 0x70
  );
  const declared = (rec.mimeType || "").split(";")[0].trim();
  const type = isWebM ? "video/webm" : hasFtyp ? "video/mp4" : declared === "video/webm" ? "video/webm" : "video/mp4";
  const stamp = new Date(rec.createdAt).toISOString().replace(/[:.]/g, "-").slice(0, 19);
  const suffix = partCount > 1 ? `-part${String(partIndex + 1).padStart(2, "0")}` : "";
  const name = `${base}-${stamp}${suffix}.${type === "video/mp4" ? "mp4" : "webm"}`;
  return new File([rec.blob], name, { type, lastModified: rec.createdAt });
}

export function startSave(
  clip: ClipMeta | ClipRecord | Array<ClipMeta | ClipRecord>,
  baseName: string,
  onJob: (update: (prev: SaveJob | null) => SaveJob | null) => void,
) {
  const parts = Array.isArray(clip) ? clip.slice() : [clip];
  const set = (j: SaveJob | null) => onJob(() => j);
  const patch = (p: Partial<SaveJob>) => onJob((prev) => (prev ? { ...prev, ...p } : prev));

  const base = (baseName || "Take").replace(/[^\p{L}\p{N} _-]/gu, "").trim() || "Take";
  const started = Date.now();
  const partCount = parts.length;
  const totalBytes = parts.reduce((n, p) => n + (p.sizeBytes || 0), 0);
  let savedBytes = 0;

  set({
    phase: "working",
    title: partCount > 1 ? "Preparing part 1…" : "Preparing video…",
    detail: partCount > 1 ? `${partCount} parts · ${fmtSize(totalBytes)} total` : "Getting the file ready",
    startedAt: started,
    file: null,
    bytes: 0,
    download: downloadFile,
    openInPlayer,
    partIndex: 0,
    partCount,
    savedBytes: 0,
    totalBytes,
  });

  const runPart = async (index: number) => {
    if (index >= partCount) {
      patch({
        phase: "done",
        title: partCount > 1 ? "All parts saved" : "Saved",
        detail: `${partCount > 1 ? `${partCount} parts · ` : ""}${fmtSize(totalBytes)} handed to your iPhone. Keep the app open until any downloads finish.`,
        savedBytes: totalBytes,
        partIndex: partCount,
      });
      return;
    }

    const meta = parts[index];
    const label = partCount > 1 ? `Part ${index + 1} of ${partCount}` : "Video";
    patch({
      phase: "working",
      title: partCount > 1 ? `Preparing part ${index + 1}…` : "Preparing video…",
      detail: `${fmtSize(savedBytes)} of ${fmtSize(totalBytes)} saved so far`,
      partIndex: index,
      savedBytes,
    });

    const stored = "blob" in meta && (meta as ClipRecord).blob ? (meta as ClipRecord) : await getClip(meta.id);
    if (!stored?.blob?.size) {
      patch({
        phase: "error",
        title: "Nothing to save",
        detail: `${label} has no video data left in storage. Try Repair or Recover first.`,
      });
      return;
    }

    const file = await toFile(stored, base, index, partCount);
    const partBytes = stored.blob.size;
    const nav: any = navigator;
    let sharing = false;

    const advance = () => {
      savedBytes += partBytes;
      void runPart(index + 1);
    };

    const saveToFiles = () => {
      downloadFile(file);
      patch({
        phase: "working",
        title: partCount > 1 ? `Saving part ${index + 1}…` : "Copying to your Files app",
        detail: `${fmtSize(partBytes)} · Stays on your iPhone, nothing is uploaded. Find it in Files > Downloads.`,
      });
      window.setTimeout(advance, 1200);
    };

    const share = () => {
      // Two shares at once makes iOS reject the second one instantly.
      if (sharing) return;
      sharing = true;

      let result: Promise<void>;
      const shareStartedAt = performance.now();
      // The share call must happen inside the tap, with no await before it.
      try {
        if (typeof nav.share !== "function") throw new Error("The iPhone share menu is unavailable in this browser.");
        // Do not use canShare() as a gate: iOS can report false for a valid
        // recording even though share() still opens the native menu.
        result = nav.share({ files: [file] });
      } catch (e: any) {
        sharing = false;
        patch({
          phase: "ready", file, bytes: partBytes,
          title: "Share sheet didn't open",
          detail: `${label} · ${fmtSize(partBytes)} · ${String(e?.message || "iPhone rejected the video.")}`,
          actionLabel: "Save to Files", runPrimary: saveToFiles,
        });
        return;
      }

      patch({ phase: "working", title: "Opening share sheet…", detail: `${label} · ${fmtSize(partBytes)}` });

      result
        .then(() => { sharing = false; advance(); })
        .catch((error: any) => {
          sharing = false;
          const cancelled = error?.name === "AbortError" && performance.now() - shareStartedAt > 1200;
          if (!cancelled) {
            patch({
              phase: "ready", file, bytes: partBytes,
              title: "Save the full video",
              detail: `${label} · ${fmtSize(partBytes)} · iPhone refused the share attachment. Save the same playable video directly to Files instead.`,
              actionLabel: "Save to Files", runPrimary: saveToFiles,
            });
            return;
          }
          patch({
            phase: "ready", file, bytes: partBytes,
            title: "Share closed",
            detail: `${label} · nothing was saved. Tap to open the menu again.`,
            actionLabel: partCount > 1 ? `Share part ${index + 1}` : "Share",
            runPrimary: share,
          });
        });
    };

    const big = partBytes > IPHONE_SHARE_SAFE_BYTES;
    patch({
      phase: "ready", file, bytes: partBytes,
      partIndex: index, savedBytes,
      title: big ? "Ready to save" : "Ready to share",
      detail: big
        ? `${label} · ${fmtSize(partBytes)} · Too large for the iPhone share menu. Tap below to copy it into Files (Downloads). It stays on the phone.`
        : `${label} · ${fmtSize(partBytes)} · Tap to AirDrop it, save to Photos or save to Files.`,
      actionLabel: big
        ? (partCount > 1 ? `Save part ${index + 1} to Files` : "Save to Files")
        : (partCount > 1 ? `Share part ${index + 1}` : "Share"),
      runPrimary: big ? saveToFiles : share,
    });
  };

  void runPart(0).catch((e: any) => {
    patch({ phase: "error", title: "Couldn't save", detail: String(e?.message || e) });
  });
}
