// Saving a recording off the phone.
//
// The whole UI here is deliberately one button. iOS only offers "Save Video",
// AirDrop, Files etc. through its own share sheet, and it only opens that sheet
// when navigator.share() is reached inside the tap that triggered it — so the
// file is prepared first (ring), and then a single Share button fires share()
// synchronously. Very large takes (multi-GB) are refused by the share sheet, so
// for those the same single button downloads straight to Files instead.

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

      const clean = (complete.mimeType || "video/mp4").split(";")[0].trim();
      const type = clean === "video/webm" ? "video/webm" : "video/mp4";
      const stamp = new Date(complete.createdAt).toISOString().replace(/[:.]/g, "-").slice(0, 19);
      const name = `${base}-${stamp}.${type === "video/mp4" ? "mp4" : "webm"}`;
      const file = new File([complete.blob], name, { type });
      const totalBytes = complete.sizeBytes || complete.blob.size;

      const nav: any = navigator;
      const tooBig = file.size > SHARE_LIMIT;
      const canShare = !tooBig && !!nav.share && (!nav.canShare || (() => { try { return nav.canShare({ files: [file] }); } catch { return false; } })());

      if (canShare) {
        patch({
          phase: "ready", file, bytes: totalBytes,
          title: "Ready to share",
          detail: `${fmtSize(totalBytes)} · Tap Share to AirDrop it, save to Photos or save to Files.`,
          actionLabel: "Share",
          runPrimary: () => {
            nav.share({ files: [file] })
              .then(() => patch({ phase: "done", title: "Share sheet opened", detail: "Pick AirDrop, Save Video, or Save to Files." }))
              .catch((e: any) => {
                if (e?.name === "AbortError") { patch({ phase: "done", title: "Share cancelled", detail: "Nothing was saved." }); return; }
                downloadFile(file);
                patch({ phase: "done", title: "Saved to Files", detail: "Sharing wasn't available, so the video was downloaded. Find it in Files → Downloads." });
              });
          },
        });
        return;
      }

      patch({
        phase: "ready", file, bytes: totalBytes,
        title: tooBig ? "Ready for Files" : "Ready to save",
        detail: tooBig
          ? `${fmtSize(totalBytes)} · This take is too large for the iPhone share sheet — it goes straight to Files.`
          : `${fmtSize(totalBytes)} · Tap Save to put it in Files → Downloads.`,
        actionLabel: "Save to Files",
        runPrimary: () => {
          downloadFile(file);
          patch({ phase: "done", title: "Saved to Files", detail: "Find it in Files → Downloads." });
        },
      });
    } catch (e: any) {
      patch({ phase: "error", title: "Couldn't save", detail: String(e?.message || e) });
    }
  })();
}
