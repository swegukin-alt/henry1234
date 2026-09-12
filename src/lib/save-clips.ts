// Saving a recording to the iPhone camera roll.
//
// iOS only offers "Save Video" in the share sheet for a real .mp4 with a clean
// MIME type, one file at a time, and only when share() is reached inside the
// tap that triggered it — so: no awaits before the call, no codec parameters,
// no multi-file batches. Everything here is synchronous up to share().
//
// The caller always gets a job object immediately, even on failure, so the UI
// can show a live ring instead of appearing dead.

import type { ClipRecord } from "./clip-store";
import { fmtSize } from "./clip-store";

export type SaveJob = {
  phase: "working" | "done" | "error";
  title: string;
  detail: string;
  startedAt: number;
  file: File | null;
  download: (f: File) => void;
};

function downloadFile(f: File) {
  const url = URL.createObjectURL(f);
  const a = document.createElement("a");
  a.href = url;
  a.download = f.name;
  a.rel = "noopener";
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 60000);
}

export function startSave(
  clips: ClipRecord[],
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
    download: downloadFile,
  });

  try {
    const arr = clips.filter((c) => c && c.blob && c.blob.size > 0);
    if (!arr.length) {
      patch({ phase: "error", title: "Nothing to save", detail: "This take has no video data left in storage. Try Repair or Recover first." });
      return;
    }

    const toFile = (c: ClipRecord, i: number) => {
      const clean = (c.mimeType || "video/mp4").split(";")[0].trim();
      const type = clean === "video/webm" ? "video/webm" : "video/mp4";
      const name = `${base}${arr.length > 1 ? `-${i + 1}` : ""}.${type === "video/mp4" ? "mp4" : "webm"}`;
      return new File([c.blob], name, { type });
    };

    const first = toFile(arr[0], 0);
    const rest = arr.slice(1);
    const totalBytes = arr.reduce((n, c) => n + (c.sizeBytes || c.blob.size || 0), 0);

    patch({ file: first, detail: `${fmtSize(totalBytes)} · handing it to your iPhone` });

    const nav: any = navigator;
    const canShare = !!nav.share && (!nav.canShare || (() => { try { return nav.canShare({ files: [first] }); } catch { return false; } })());

    if (canShare) {
      nav.share({ files: [first] })
        .then(() => {
          rest.forEach((c, i) => downloadFile(toFile(c, i + 1)));
          patch({ phase: "done", title: "Sent to your iPhone", detail: 'Pick "Save Video" to put it in your camera roll.' });
        })
        .catch((e: any) => {
          if (e?.name === "AbortError") { set(null); return; }
          downloadFile(first);
          rest.forEach((c, i) => downloadFile(toFile(c, i + 1)));
          patch({ phase: "done", title: "Saved as a file", detail: "The iPhone sheet refused it, so it downloaded instead. Look in Files → Downloads." });
        });
      return;
    }

    downloadFile(first);
    rest.forEach((c, i) => downloadFile(toFile(c, i + 1)));
    patch({ phase: "done", title: "Downloaded", detail: "Saving straight to Photos isn't available here, so the file downloaded instead." });
  } catch (e: any) {
    patch({ phase: "error", title: "Couldn't save", detail: String(e?.message || e) });
  }
}
