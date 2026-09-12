import { useEffect, useState } from "react";
import { createPortal } from "react-dom";
import type { SaveJob } from "@/lib/save-clips";

// Full-screen feedback while a clip is handed to iOS. Saving a long take can
// take many seconds with no OS-level signal, so there is always a live ring,
// elapsed time and an escape hatch. Rendered into <body> so no transformed or
// overflow-hidden parent can hide it.
export function SaveOverlay({
  job, onClose, onFallback,
}: {
  job: SaveJob;
  onClose: () => void;
  onFallback: () => void;
}) {
  const [now, setNow] = useState(() => Date.now());

  useEffect(() => {
    if (job.phase !== "working") return;
    const id = window.setInterval(() => setNow(Date.now()), 200);
    return () => window.clearInterval(id);
  }, [job.phase]);

  useEffect(() => {
    if (job.phase !== "done") return;
    const id = window.setTimeout(onClose, 4500);
    return () => window.clearTimeout(id);
  }, [job.phase, onClose]);

  if (typeof document === "undefined") return null;

  const secs = Math.max(0, Math.round((now - job.startedAt) / 1000));
  const working = job.phase === "working";
  const error = job.phase === "error";

  return createPortal(
    <div
      className="fixed inset-0 z-[2147483000] grid place-items-center bg-black/90 px-6 backdrop-blur-sm"
      onClick={(e) => e.stopPropagation()}
      onTouchStart={(e) => e.stopPropagation()}
      role="dialog"
      aria-live="polite"
    >
      <div className="flex w-full max-w-sm flex-col items-center gap-4 text-center">
        <div className="relative h-20 w-20">
          <svg viewBox="0 0 48 48" className={working ? "h-20 w-20 animate-spin" : "h-20 w-20"}>
            <circle cx="24" cy="24" r="20" fill="none" stroke="currentColor" strokeWidth="4" className="text-white/15" />
            <circle
              cx="24" cy="24" r="20" fill="none" strokeWidth="4" strokeLinecap="round"
              stroke="currentColor"
              className={error ? "text-red-400" : "text-amber-400"}
              strokeDasharray={working ? "38 126" : "126"}
            />
          </svg>
          {!working && (
            <div className={`absolute inset-0 grid place-items-center text-2xl font-black ${error ? "text-red-400" : "text-amber-400"}`}>
              {error ? "!" : "✓"}
            </div>
          )}
        </div>

        <div className="text-lg font-black text-white">{job.title}</div>
        <div className="text-sm leading-snug text-neutral-300">{job.detail}</div>
        {working && (
          <div className="text-xs text-neutral-400">{secs}s · long takes need a moment — keep this screen open</div>
        )}

        <div className="mt-2 flex flex-wrap items-center justify-center gap-2">
          {working && secs >= 4 && job.file && (
            <button onClick={onFallback} className="rounded-full border border-white/20 px-4 py-2 text-sm text-neutral-200 active:scale-95">
              Save as a file instead
            </button>
          )}
          <button onClick={onClose} className="rounded-full bg-white/10 px-5 py-2 text-sm text-neutral-200 active:scale-95">
            {working ? "Cancel" : "Done"}
          </button>
        </div>
      </div>
    </div>,
    document.body,
  );
}
