// Saving a recording off the phone.
//
// The whole UI here is deliberately one button. Normal takes use Apple's share
// sheet. Long takes that exceed iPhone Web Share's attachment capacity use the
// browser download manager instead, which saves them to Files > Downloads.
// The stored playable Blob is reused unchanged in both paths.

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

      // This is the same Blob that the in-app player uses. Do not load all raw
      // chunks or rebuild it here: that can temporarily duplicate a multi-GB
      // recording and make iOS kill the share handoff under memory pressure.
      const complete: ClipRecord = stored;

      // Preserve the container the recorder actually produced. Giving iOS an
      // MP4 filename around WebM bytes makes navigator.share reject the payload
      // before the native sheet appears.
      const head = new Uint8Array(await complete.blob.slice(0, 64).arrayBuffer());
      const isWebM = head[0] === 0x1a && head[1] === 0x45 && head[2] === 0xdf && head[3] === 0xa3;
      const hasFtyp = head.some((byte, index) =>
        byte === 0x66 && head[index + 1] === 0x74 && head[index + 2] === 0x79 && head[index + 3] === 0x70
      );
      const declared = (complete.mimeType || "").split(";")[0].trim();
      const type = isWebM ? "video/webm" : hasFtyp ? "video/mp4" : declared === "video/webm" ? "video/webm" : "video/mp4";
      const stamp = new Date(complete.createdAt).toISOString().replace(/[:.]/g, "-").slice(0, 19);
      const name = `${base}-${stamp}.${type === "video/mp4" ? "mp4" : "webm"}`;
      const file = new File([complete.blob], name, {
        type,
        lastModified: complete.createdAt,
      });
      const totalBytes = complete.blob.size;

      const nav: any = navigator;
      let sharing = false;

      const saveToFiles = () => {
        downloadFile(file);
        patch({
          phase: "done",
          title: "Saving to Files",
          detail: `${fmtSize(totalBytes)} · Open the Files app, then Downloads. Keep this app open until iPhone finishes.`,
        });
      };

      const share = () => {
        // Two shares at once makes iOS reject the second one instantly.
        if (sharing) return;
        sharing = true;

        let result: Promise<void>;
        const shareStartedAt = performance.now();
        // The share call must happen inside the tap, with no await before it.
        // Files-only is the smallest valid payload and avoids an iOS Safari
        // failure where optional title data can make a large video hostile.
        try {
          if (typeof nav.share !== "function") throw new Error("The iPhone share menu is unavailable in this browser.");
          // Do not use canShare() as a gate. iOS can report false for a large
          // valid recording even though share() can still open the native menu.
          result = nav.share({ files: [file] });
        }
        catch (e: any) {
          sharing = false;
          patch({
            phase: "ready", file, bytes: totalBytes,
            title: "Share sheet didn't open",
            detail: `${fmtSize(totalBytes)} · ${String(e?.message || "iPhone rejected the video.")}`,
            actionLabel: "Share", runPrimary: share,
          });
          return;
        }

        patch({ phase: "working", title: "Opening share sheet…", detail: "This can take a few seconds for a long take." });

        result
          .then(() => {
            sharing = false;
            patch({ phase: "done", title: "Shared", detail: "Pick AirDrop, Save Video, or Save to Files to finish." });
          })
          .catch((error: any) => {
            sharing = false;
            const cancelled = error?.name === "AbortError" && performance.now() - shareStartedAt > 1200;
            if (!cancelled) {
              patch({
                phase: "ready", file, bytes: totalBytes,
                title: "Save the full video",
                detail: `${fmtSize(totalBytes)} · iPhone refused the share attachment. Save the same playable video directly to Files instead.`,
                actionLabel: "Save to Files", runPrimary: saveToFiles,
              });
              return;
            }
            patch({
              phase: "ready", file, bytes: totalBytes,
              title: "Share closed",
              detail: `${fmtSize(totalBytes)} · Nothing was saved. Tap Share to open the menu again.`,
              actionLabel: "Share", runPrimary: share,
            });
          });
      };

      if (totalBytes > IPHONE_SHARE_SAFE_BYTES) {
        patch({
          phase: "ready", file, bytes: totalBytes,
          title: "Ready to save",
          detail: `${fmtSize(totalBytes)} · This long take will save directly to Files > Downloads.`,
          actionLabel: "Save to Files",
          runPrimary: saveToFiles,
        });
        return;
      }

      patch({
        phase: "ready", file, bytes: totalBytes,
        title: "Ready to share",
        detail: `${fmtSize(totalBytes)} · Tap Share to AirDrop it, save to Photos or save to Files.`,
        actionLabel: "Share",
        runPrimary: share,
      });

    } catch (e: any) {
      patch({ phase: "error", title: "Couldn't save", detail: String(e?.message || e) });
    }
  })();
}
