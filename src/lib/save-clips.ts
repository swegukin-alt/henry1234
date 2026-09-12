// Saving a recording to the iPhone camera roll.
//
// iOS only offers "Save Video" in the share sheet for a real .mp4 with a clean
// MIME type, one file at a time, and only when share() is reached inside the
// tap that triggered it — so: no awaits before the call, no codec parameters,
// no multi-file batches. Everything here is synchronous up to share().
//
// Very long takes (multi-GB) are a special case: iOS silently refuses to put
// them in the share sheet. For those we go straight to a file download and
// also offer opening the video in Safari's own player, where the built-in
// share button can save it to Photos.
//
// The caller always gets a job object immediately, even on failure, so the UI
// can show a live ring instead of appearing dead.

import type { ClipMeta, ClipRecord } from "./clip-store";
import { assembleBest, fmtSize, getClip } from "./clip-store";

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
};

// Beyond this, iOS Safari's share sheet reliably fails or never appears.
const SHARE_LIMIT = 1_200_000_000; // ~1.2 GB

function downloadFile(f: File) {
  const url = URL.createObjectURL(f);
  const a = document.createElement("a");
  a.href = url;
  a.download = f.name;
  a.rel = "noopener";
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 10 * 60 * 1000);
}

function openInPlayer(f: File) {
  const url = URL.createObjectURL(f);
  const w = window.open(url, "_blank");
  if (!w) location.href = url;
  setTimeout(() => URL.revokeObjectURL(url), 10 * 60 * 1000);
}

export function startSave(
  clip: ClipMeta | ClipRecord,
  baseName: string,
  onJob: (update: (prev: SaveJob | null) => SaveJob | null) => void,
) {
  const set = (j: SaveJob | null) => onJob(() => j);
  const patch = (p: Partial<SaveJob>) => onJob((prev) => (prev ? { ...prev, ...p } : prev));

  const base = (baseName || "Take").replace(/[^\p{L}\p{N} _-]/gu, "").trim() || "Take";
  const started = Date.now();

  // Show the ring before anything can throw.
  set({
    phase: "working",
    title: "Preparing video…",
    detail: "Getting the file ready",
    startedAt: started,
    file: null,
    bytes: 0,
    download: downloadFile,
    openInPlayer,
  });

  void (async () => {
  try {
    const stored = "blob" in clip ? clip : await getClip(clip.id);
    if (!stored?.blob?.size) {
      patch({ phase: "error", title: "Nothing to save", detail: "This take has no video data left in storage. Try Repair or Recover first." });
      return;
    }

    // A take can end up shorter than it should be if a write failed near the
    // end. Rebuild from every surviving byte before saving.
    patch({ detail: "Collecting every second of this take…" });
    let complete: ClipRecord;
    try { complete = await assembleBest(stored); } catch { complete = stored; }

    const toFile = (c: ClipRecord) => {
      const clean = (c.mimeType || "video/mp4").split(";")[0].trim();
      const type = clean === "video/webm" ? "video/webm" : "video/mp4";
      const stamp = new Date(c.createdAt).toISOString().replace(/[:.]/g, "-").slice(0, 19);
      const name = `${base}-${stamp}.${type === "video/mp4" ? "mp4" : "webm"}`;
      return new File([c.blob], name, { type });
    };

    const first = toFile(complete);
    const totalBytes = complete.sizeBytes || complete.blob.size;

    patch({ file: first, bytes: totalBytes, detail: `${fmtSize(totalBytes)} · handing it to your iPhone` });

    const nav: any = navigator;
    const tooBigToShare = first.size > SHARE_LIMIT;
    const canShare = !tooBigToShare && !!nav.share && (!nav.canShare || (() => { try { return nav.canShare({ files: [first] }); } catch { return false; } })());

    if (tooBigToShare) {
      patch({
        phase: "ready", file: first, bytes: totalBytes,
        title: "Ready for Files",
        detail: `${fmtSize(totalBytes)} · This long take is too large for the iPhone save menu. Tap Save to Files below.`,
        actionLabel: "Save to Files",
        runPrimary: () => downloadFile(first),
      });
      return;
    }

    if (canShare) {
      patch({
        phase: "ready", file: first, bytes: totalBytes,
        title: "Ready to save",
        detail: `${fmtSize(totalBytes)} · Tap Open save menu, then choose Save Video.`,
        actionLabel: "Open save menu",
        runPrimary: () => {
          nav.share({ files: [first] })
            .then(() => patch({ phase: "done", title: "Save menu opened", detail: 'Choose "Save Video" to put this recording in Photos.' }))
            .catch((e: any) => {
              if (e?.name === "AbortError") return;
              patch({ phase: "error", title: "Could not open the save menu", detail: "Tap Save to Files instead." });
            });
        },
      });
      return;
    }

    patch({
      phase: "ready", file: first, bytes: totalBytes,
      title: "Ready for Files", detail: `${fmtSize(totalBytes)} · Tap Save to Files below.`,
      actionLabel: "Save to Files", runPrimary: () => downloadFile(first),
    });
  } catch (e: any) {
    patch({ phase: "error", title: "Couldn't save", detail: String(e?.message || e) });
  }
  })();
}
