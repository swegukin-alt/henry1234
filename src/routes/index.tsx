import { createFileRoute } from "@tanstack/react-router";
import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { ChevronLeft, FlipVertical2, Play, Pause, SlidersHorizontal, Type, MoreHorizontal, Video, Circle, Square, Film, Download, Trash2, X, Mic, AudioLines, AlignJustify, Timer } from "lucide-react";
import { listClipMeta, deleteClip, deleteAllForScript, fmtSize, fmtDuration, createSession, appendChunk, finalizeSession, recoverOrphanSessions, requestPersistentStorage, repairClip, rescueAll, listAllClips, deepRestore, getClip, storageUsage, clearAllStorage, purgeOrphanChunks, type ClipMeta, type ClipRecord } from "@/lib/clip-store";
import { startSave, type SaveJob } from "@/lib/save-clips";
import { SaveOverlay } from "@/components/SaveOverlay";
import { tokenize, wordListFromTokens, detectLang, type Token } from "@/lib/chunk-script";
import { useVoiceFollow, isVoiceFollowSupported } from "@/lib/voice-follow-v2";


export const Route = createFileRoute("/")({
  head: () => ({
    meta: [
      { title: "Let's kick some ass" },
      { name: "description", content: "A clean, easy-to-read teleprompter with mirror mode, live progress, and Korean support." },
      { name: "theme-color", content: "#0a0a0a" },
      { name: "apple-mobile-web-app-capable", content: "yes" },
      { name: "apple-mobile-web-app-status-bar-style", content: "black-translucent" },
      { property: "og:title", content: "Let's kick some ass" },
      { property: "og:description", content: "A clean teleprompter that runs in your browser." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: Index,
});

type Script = { id: string; title: string; body: string; updatedAt: number };
type Settings = {
  fontSize: number;
  speed: number; // px per second
  mirrorH: boolean;
  mirrorV: boolean;
  bg: string; // 'black' | 'white' | 'sepia'
  countdown: number; // seconds
  width: number; // max width % 50-100
  // Reading assist
  voiceFollow: boolean; // soft highlight follows your voice (mic)
  chunking: boolean;    // break script into breath-groups at natural pauses
  pauses: boolean;      // briefly slow scroll at commas / sentence ends
  readingHighlight: boolean; // highlight word at the eye-line (no mic, zero-latency)
};

const STORAGE_SCRIPTS = "prompter.scripts.v1";
const STORAGE_ACTIVE = "prompter.active.v1";
const STORAGE_SETTINGS = "prompter.settings.v1";

const DEFAULT_SETTINGS: Settings = {
  fontSize: 72,
  speed: 70,

  mirrorH: false,
  mirrorV: false,
  bg: "black",
  countdown: 3,
  width: 82,
  voiceFollow: false,
  chunking: true,
  pauses: true,
  readingHighlight: true,
};


const SAMPLE = `여러분, 안녕하세요. 오늘 이 자리에 함께해 주셔서 감사합니다.

Welcome. This is your teleprompter. Paste a script, tap Play, and the words will scroll smoothly.

화면 하단에 남은 분량이 퍼센트로 표시됩니다. Adjust speed and font size from the controls. Tap the screen to pause.`;

// Turn a raw storage failure into something true and useful. A write can fail
// for reasons that have nothing to do with a full phone (Safari reclaiming
// space, private browsing, the database being closed), so never claim "full"
// unless the browser actually said so.
function describeStorageError(err: unknown): string {
  const name = (err as any)?.name || "";
  const msg = String((err as any)?.message || "");
  if (name === "QuotaExceededError" || /quota/i.test(msg)) {
    return "This browser hit its own storage limit for the app. Free space by deleting older takes in All videos, then keep recording.";
  }
  if (name === "InvalidStateError" || /closed|database/i.test(msg)) {
    return "The recording store hiccuped. Recording continues — stop and check the take when you can.";
  }
  return "A piece of this take could not be written. Recording continues, but stop soon and check it.";
}

function uid() {
  return Math.random().toString(36).slice(2, 10);
}

// Unified landscape entry — same call from both Play and Video buttons.
// Must run synchronously inside the user gesture for iOS to honor fullscreen.
function enterLandscape() {
  if (typeof document === "undefined") return;
  const el: any = document.documentElement;
  const req = el.requestFullscreen || el.webkitRequestFullscreen || el.webkitEnterFullscreen;
  try { req?.call(el)?.catch?.(() => {}); } catch {}
  try { (screen as any).orientation?.lock?.("landscape")?.catch?.(() => {}); } catch {}
}

function load<T>(key: string, fallback: T): T {
  if (typeof window === "undefined") return fallback;
  try {
    const raw = localStorage.getItem(key);
    return raw ? (JSON.parse(raw) as T) : fallback;
  } catch {
    return fallback;
  }
}

function save<T>(key: string, value: T) {
  if (typeof window === "undefined") return;
  try {
    localStorage.setItem(key, JSON.stringify(value));
  } catch {}
}

function Index() {
  const [scripts, setScripts] = useState<Script[]>([]);
  const [activeId, setActiveId] = useState<string | null>(null);
  const [settings, setSettings] = useState<Settings>(DEFAULT_SETTINGS);
  const [mode, setMode] = useState<"library" | "edit" | "play" | "video">("library");
  const [hydrated, setHydrated] = useState(false);

  useEffect(() => {
    const loaded = load<Script[]>(STORAGE_SCRIPTS, []);
    if (loaded.length === 0) {
      const first: Script = { id: uid(), title: "Sample script", body: SAMPLE, updatedAt: Date.now() };
      setScripts([first]);
      setActiveId(first.id);
      save(STORAGE_SCRIPTS, [first]);
      save(STORAGE_ACTIVE, first.id);
    } else {
      setScripts(loaded);
      setActiveId(load<string | null>(STORAGE_ACTIVE, loaded[0].id));
    }
    setSettings({ ...DEFAULT_SETTINGS, ...load<Partial<Settings>>(STORAGE_SETTINGS, {}) });
    setHydrated(true);
  }, []);

  useEffect(() => { if (hydrated) save(STORAGE_SCRIPTS, scripts); }, [scripts, hydrated]);
  useEffect(() => { if (hydrated && activeId) save(STORAGE_ACTIVE, activeId); }, [activeId, hydrated]);
  useEffect(() => { if (hydrated) save(STORAGE_SETTINGS, settings); }, [settings, hydrated]);

  const active = useMemo(() => scripts.find((s) => s.id === activeId) ?? null, [scripts, activeId]);

  const updateActive = (patch: Partial<Script>) => {
    setScripts((arr) => arr.map((s) => (s.id === activeId ? { ...s, ...patch, updatedAt: Date.now() } : s)));
  };
  const createScript = () => {
    const s: Script = { id: uid(), title: "Untitled script", body: "", updatedAt: Date.now() };
    setScripts((a) => [s, ...a]);
    setActiveId(s.id);
    setMode("edit");
  };
  const [allVideosOpen, setAllVideosOpen] = useState(false);
  const [allClips, setAllClips] = useState<ClipMeta[]>([]);
  const [librarySave, setLibrarySave] = useState<SaveJob | null>(null);
  const refreshAllClips = useCallback(async () => {
    try { setAllClips(await listAllClips()); } catch { setAllClips([]); }
  }, []);
  useEffect(() => { if (allVideosOpen) void refreshAllClips(); }, [allVideosOpen, refreshAllClips]);

  const deleteScript = (id: string) => {
    setScripts((a) => a.filter((s) => s.id !== id));
    if (activeId === id) setActiveId(null);
  };

  if (!hydrated) return <div className="min-h-screen bg-[#0a0a0a]" />;

  if ((mode === "play" || mode === "video") && active) {
    return (
      <Prompter
        script={active}
        settings={settings}
        videoMode={mode === "video"}
        onExit={() => setMode("edit")}
        onSettings={setSettings}
      />
    );
  }

  return (
    <Shell>
      {mode === "library" || !active ? (
        <Library
          scripts={scripts}
          activeId={activeId}
          onSelect={(id) => { setActiveId(id); setMode("edit"); }}
          onCreate={createScript}
          onDelete={deleteScript}
          onAllVideos={() => setAllVideosOpen(true)}
        />
      ) : (
        <Editor
          script={active}
          settings={settings}
          onChange={updateActive}
          onSettings={setSettings}
          onBack={() => setMode("library")}
          onPlay={() => { enterLandscape(); setMode("play"); }}
          onVideo={() => { enterLandscape(); setMode("video"); }}
        />
      )}

      {allVideosOpen && (
        <ClipsSheet
          clips={allClips}
          scriptTitles={Object.fromEntries(scripts.map((s) => [s.id, s.title || "Untitled script"]))}
          onClose={() => setAllVideosOpen(false)}
          onDelete={async (id) => { await deleteClip(id); setAllClips((cs) => cs.filter((c) => c.id !== id)); }}
          onDeleteAll={async () => { for (const c of allClips) await deleteClip(c.id); setAllClips([]); }}
          onExport={(clip) => startSave(clip, scripts.find((s) => s.id === clip.scriptId)?.title || "Take", setLibrarySave)}
          onReplace={(clip) => setAllClips((cs) => (cs.some((c) => c.id === clip.id) ? cs.map((c) => c.id === clip.id ? clip : c) : [clip, ...cs]).sort((a, b) => (b.createdAt - a.createdAt) || b.id.localeCompare(a.id)))}
          onRescue={async () => { for (const s of scripts) { try { await rescueAll(s.id); } catch {} } await refreshAllClips(); }}
        />
      )}

      {librarySave && (
        <SaveOverlay
          job={librarySave}
          onClose={() => setLibrarySave(null)}
          onFallback={() => { if (librarySave.file) librarySave.download(librarySave.file); }}
        />
      )}
    </Shell>
  );
}

function Shell({ children }: { children: React.ReactNode }) {
  return (
    <div className="min-h-screen bg-[#0a0a0a] text-neutral-100" style={{ fontFamily: "var(--font-sans)" }}>
      <div className="mx-auto max-w-2xl px-4 pb-24 pt-[max(env(safe-area-inset-top),1rem)]">
        {children}
      </div>
    </div>
  );
}

function Library({
  scripts, activeId, onSelect, onCreate, onDelete, onAllVideos,
}: {
  scripts: Script[]; activeId: string | null;
  onSelect: (id: string) => void; onCreate: () => void; onDelete: (id: string) => void;
  onAllVideos: () => void;
}) {
  return (
    <div>
      <header className="pt-6 pb-5">
        <h1 className="text-[26px] sm:text-3xl font-black tracking-tight leading-[1.15] bg-gradient-to-br from-amber-300 to-amber-500 bg-clip-text text-transparent">
          Let's kick some ass
        </h1>
        <p className="text-[13px] text-neutral-400 mt-2 leading-snug">
          Never give up. Remember where you came from.
        </p>
        <button
          onClick={onCreate}
          className="mt-5 w-full rounded-2xl bg-amber-400 px-4 py-3.5 text-base font-bold text-black active:scale-[0.98] transition shadow-lg shadow-amber-400/20"
        >
          Let's go
        </button>
        <button
          onClick={onAllVideos}
          className="mt-2.5 w-full inline-flex items-center justify-center gap-2 rounded-2xl border border-white/12 bg-white/[0.04] px-4 py-3 text-sm font-bold text-neutral-200 active:scale-[0.98] transition"
        >
          <Film className="h-4 w-4 text-amber-300" /> All videos
        </button>
      </header>

      <ul className="mt-2 space-y-2">
        {scripts.map((s) => (
          <li key={s.id} className={`rounded-2xl border ${activeId === s.id ? "border-amber-400/50" : "border-white/10"} bg-white/[0.03]`}>
            <div className="flex items-stretch">
              <button onClick={() => onSelect(s.id)} className="flex-1 text-left px-4 py-3">
                <div className="font-semibold truncate">{s.title || "Untitled"}</div>
                <div className="text-xs text-neutral-400 mt-0.5 line-clamp-1">
                  {s.body.trim().slice(0, 80) || "Empty script"}
                </div>
              </button>
              <button
                onClick={() => {
                  if (confirm(`Delete "${s.title}"?`)) onDelete(s.id);
                }}
                className="px-4 text-neutral-500 hover:text-red-400 text-sm"
                aria-label="Delete"
              >
                ✕
              </button>
            </div>
          </li>
        ))}
        {scripts.length === 0 && (
          <li className="rounded-2xl border border-dashed border-white/10 px-4 py-10 text-center text-neutral-400">
            No scripts yet. Tap <span className="text-amber-400 font-bold">Let's go</span> to start.
          </li>
        )}
      </ul>
    </div>
  );
}

function Editor({
  script, settings, onChange, onSettings, onBack, onPlay, onVideo,
}: {
  script: Script;
  settings: Settings;
  onChange: (patch: Partial<Script>) => void;
  onSettings: (s: Settings) => void;
  onBack: () => void;
  onPlay: () => void;
  onVideo: () => void;
}) {
  const disabled = !script.body.trim();
  return (
    <div>
      <header className="flex items-center justify-between py-3 gap-2">
        <button onClick={onBack} className="text-sm text-neutral-400 hover:text-white">‹ Scripts</button>
        <div className="flex items-center gap-2">
          <button
            onClick={onVideo}
            disabled={disabled}
            className="rounded-full border border-amber-400/60 bg-amber-400/10 px-4 py-2 text-sm font-bold text-amber-300 disabled:opacity-40 active:scale-95 transition inline-flex items-center gap-1.5"
          >
            <Video className="h-4 w-4" /> Video
          </button>
          <button
            onClick={onPlay}
            disabled={disabled}
            className="rounded-full bg-amber-400 px-5 py-2 text-sm font-bold text-black disabled:opacity-40 active:scale-95 transition"
          >
            ▶ Play
          </button>
        </div>
      </header>


      <input
        value={script.title}
        onChange={(e) => onChange({ title: e.target.value })}
        placeholder="Script title"
        className="w-full bg-transparent text-2xl font-bold outline-none placeholder:text-neutral-600 py-2"
      />

      <textarea
        value={script.body}
        onChange={(e) => onChange({ body: e.target.value })}
        placeholder="Paste or type your script here… 한글도 지원합니다."
        className="mt-2 min-h-[40vh] w-full resize-y rounded-2xl border border-white/10 bg-white/[0.03] p-4 text-base leading-relaxed outline-none focus:border-amber-400/50"
      />

      <SettingsPanel settings={settings} onChange={onSettings} />
    </div>
  );
}

function SettingsPanel({ settings, onChange }: { settings: Settings; onChange: (s: Settings) => void }) {
  const set = (patch: Partial<Settings>) => onChange({ ...settings, ...patch });
  return (
    <section className="mt-6 rounded-2xl border border-white/10 bg-white/[0.03] p-4">
      <h2 className="text-sm font-bold uppercase tracking-widest text-neutral-400">Settings</h2>
      <div className="mt-4 space-y-4">
        <Slider label="Font size" value={settings.fontSize} min={24} max={140} step={1} suffix="px"
          onChange={(v) => set({ fontSize: v })} />
        <Slider label="Scroll speed" value={settings.speed} min={10} max={250} step={1} suffix="px/s"
          onChange={(v) => set({ speed: v })} />
        <Slider label="Text width" value={settings.width} min={50} max={100} step={1} suffix="%"
          onChange={(v) => set({ width: v })} />
        <div className="flex flex-wrap gap-2 pt-1">
          <Toggle on={settings.mirrorH} onClick={() => set({ mirrorH: !settings.mirrorH })}>Mirror ↔</Toggle>
          <Toggle on={settings.mirrorV} onClick={() => set({ mirrorV: !settings.mirrorV })}>Mirror ↕</Toggle>
        </div>
        <div className="pt-3">
          <div className="mb-2 text-xs font-semibold uppercase tracking-widest text-neutral-500">Reading assist</div>
          <div className="flex flex-wrap gap-2">
            <Toggle on={settings.chunking ?? true} onClick={() => set({ chunking: !(settings.chunking ?? true) })}>
              <AlignJustify className="mr-1 inline h-3.5 w-3.5" /> Chunk phrases
            </Toggle>
            <Toggle on={settings.pauses ?? true} onClick={() => set({ pauses: !(settings.pauses ?? true) })}>
              <Timer className="mr-1 inline h-3.5 w-3.5" /> Slow at punctuation
            </Toggle>
            <Toggle on={settings.readingHighlight ?? true} onClick={() => set({ readingHighlight: !(settings.readingHighlight ?? true) })}>
              <AudioLines className="mr-1 inline h-3.5 w-3.5" /> Reading highlight
            </Toggle>
            <Toggle on={settings.voiceFollow ?? false} onClick={() => set({ voiceFollow: !(settings.voiceFollow ?? false) })}>
              <AudioLines className="mr-1 inline h-3.5 w-3.5" /> Voice-follow
            </Toggle>
          </div>
          <p className="mt-2 text-[11px] text-neutral-500">
            Chunk phrases breaks sentences at natural breath points. Slow at punctuation eases scroll at commas &amp; periods. Voice-follow softly highlights the word you&apos;re saying (needs mic).
          </p>
        </div>

        <div className="flex gap-2 pt-1">
          {(["black", "white", "sepia"] as const).map((b) => (
            <button
              key={b}
              onClick={() => set({ bg: b })}
              className={`flex-1 rounded-xl px-3 py-2 text-sm font-semibold border transition ${
                settings.bg === b ? "border-amber-400 text-amber-300" : "border-white/10 text-neutral-300"
              }`}
            >
              {b === "black" ? "Dark" : b === "white" ? "Light" : "Sepia"}
            </button>
          ))}
        </div>
        <div className="pt-2">
          <button
            onClick={() => {
              if (confirm("Reset all teleprompter settings to defaults?")) onChange({ ...DEFAULT_SETTINGS });
            }}
            className="w-full rounded-xl border border-white/10 bg-white/[0.02] px-3 py-2 text-sm font-semibold text-neutral-300 transition hover:border-amber-400/50 hover:text-amber-300"
          >
            Reset to defaults
          </button>
        </div>
      </div>
    </section>
  );
}

function Slider({
  label, value, min, max, step, suffix, onChange,
}: { label: string; value: number; min: number; max: number; step: number; suffix?: string; onChange: (v: number) => void }) {
  return (
    <label className="block">
      <div className="flex justify-between text-sm">
        <span className="text-neutral-300">{label}</span>
        <span className="font-mono text-amber-300">{value}{suffix}</span>
      </div>
      <input
        type="range" min={min} max={max} step={step} value={value}
        onChange={(e) => onChange(Number(e.target.value))}
        className="slider-fluid mt-2 w-full accent-amber-400"
      />
    </label>
  );
}

function Toggle({ on, onClick, children }: { on: boolean; onClick: () => void; children: React.ReactNode }) {
  return (
    <button
      onClick={onClick}
      className={`rounded-full px-4 py-2 text-sm font-semibold border transition ${
        on ? "border-amber-400 bg-amber-400/10 text-amber-300" : "border-white/10 text-neutral-300"
      }`}
    >
      {children}
    </button>
  );
}

function Prompter({
  script, settings, onExit, onSettings, videoMode = false,
}: { script: Script; settings: Settings; onExit: () => void; onSettings: (s: Settings) => void; videoMode?: boolean }) {
  const scrollRef = useRef<HTMLDivElement>(null);
  const rafRef = useRef<number | null>(null);
  const lastTsRef = useRef<number>(0);
  const lastFrameWallRef = useRef<number>(0);
  const playingRef = useRef(false);
  const [playing, setPlaying] = useState(false);
  const [progress, setProgress] = useState(0); // 0..1 (low-frequency mirror of progressRef)
  const progressRef = useRef(0);
  const progressBarRef = useRef<HTMLDivElement | null>(null);
  const remainingRef = useRef<HTMLDivElement | null>(null);
  const lastProgressSyncRef = useRef(0);
  const [isPortrait, setIsPortrait] = useState(false);
  const [speed, setSpeed] = useState(settings.speed);
  const [fontSize, setFontSize] = useState(settings.fontSize);
  // Beam-splitter teleprompter rig: horizontal flip so text reads correctly
  // through the angled glass.
  // Mirror flip is disabled in video mode — the script should always read naturally on camera.
  const [mirrorV, setMirrorV] = useState(videoMode ? false : settings.mirrorV);
  const [panel, setPanel] = useState<null | "settings" | "size" | "more" | "assist">(null);
  const [controlsVisible, setControlsVisible] = useState(true);
  const scrollDirectionRef = useRef<1 | -1>(1); // 1 = increasing scrollTop, -1 = decreasing
  // ==== Reading-assist features ====
  const [voiceFollow, setVoiceFollow] = useState<boolean>(settings.voiceFollow ?? false);
  const [chunking, setChunking] = useState<boolean>(settings.chunking ?? true);
  const [pauses, setPauses] = useState<boolean>(settings.pauses ?? true);
  const [readingHighlight, setReadingHighlight] = useState<boolean>(settings.readingHighlight ?? true);
  const speedRef = useRef(speed);
  const fontSizeRef = useRef(fontSize);
  const mirrorVRef = useRef(mirrorV);
  const voiceFollowRef = useRef(voiceFollow);
  const pausesRef = useRef(pauses);
  const activeReadIdxRef = useRef<number>(-1);
  const vfSupported = useMemo(() => isVoiceFollowSupported(), []);
  const tokens = useMemo<Token[]>(() => tokenize(script.body, chunking), [script.body, chunking]);
  const words = useMemo(() => wordListFromTokens(tokens), [tokens]);
  const lang = useMemo(() => detectLang(script.body), [script.body]);
  // Share the camera stream's mic with voice-follow in video mode. Opening a
  // second mic session on iOS silences the audio track that is being recorded.
  const streamRef = useRef<MediaStream | null>(null);
  const getSharedMicStream = useCallback(() => streamRef.current, []);
  const { anchorWordIndex, status: vfStatus } = useVoiceFollow({
    enabled: voiceFollow && vfSupported,
    words,
    lang,
    visibleWordIndexRef: activeReadIdxRef,
    getExternalStream: getSharedMicStream,
  });
  const wordRefsRef = useRef<Array<HTMLSpanElement | null>>([]);
  const prevAnchorRef = useRef<number>(-1);
  // Voice-paced mode: the prompt auto-scrolls at the user's base speed and
  // the mic listens to speed it up or slow it down instead of jumping to
  // specific words. `voicePaceMultRef` is the current live multiplier,
  // eased toward `voicePaceTargetRef` for a smooth "gliding" feel.
  const voicePaceMultRef = useRef(1);
  const voicePaceTargetRef = useRef(1);
  const anchorWordIndexRef = useRef(-1);
  useEffect(() => { anchorWordIndexRef.current = anchorWordIndex; }, [anchorWordIndex]);
  const pauseAnchorsRef = useRef<Array<{ y: number; kind: "strong" | "soft" }>>([]);
  // Y-position of each word (top edge, in scrollTop coords). Sorted ascending by index (also monotonic in y).
  const wordYsRef = useRef<Float32Array>(new Float32Array(0));
  const textInnerRef = useRef<HTMLDivElement | null>(null);

  // Render tokens as spans so we can attach refs for highlight + pause anchors.
  // Rebuilt only when tokens change; refs are re-collected inline.
  const scriptNodes = useMemo(() => {
    wordRefsRef.current = [];
    return tokens.map((t, i) => {
      if (t.kind === "break") return <span key={`b${i}`} style={{ display: "block", height: "0.55em" }} aria-hidden />;
      if (t.kind === "space") return t.text;
      const idx = t.wordIndex;
      return (
        <span
          key={`w${idx}`}
          ref={(el) => { wordRefsRef.current[idx] = el; }}
          data-pause={t.pauseAfter ?? undefined}
        >{t.text}</span>
      );
    });
  }, [tokens]);




  // Video-mode state
  const videoElRef = useRef<HTMLVideoElement>(null);
  const [camError, setCamError] = useState<string | null>(null);
  const [camReady, setCamReady] = useState(false);
  // Mic state: label of the currently-active audio input + whether it's external.
  const [activeMicLabel, setActiveMicLabel] = useState<string>("");
  const [micIsExternal, setMicIsExternal] = useState(false);
  const [micLive, setMicLive] = useState(false);
  const currentMicIdRef = useRef<string>("");

  const recorderRef = useRef<MediaRecorder | null>(null);
  const recordingIdRef = useRef<string | null>(null);
  const appendQueueRef = useRef<Promise<unknown>>(Promise.resolve());
  // Chunk writes that failed (usually storage pressure). A silent failure is
  // how a 31-minute take ends up 25 minutes long, so it is surfaced live.
  const writeFailRef = useRef(0);
  const [writeWarn, setWriteWarn] = useState(false);
  // Plain-language reason for the warning; a failed write is not always a full disk.
  const [writeWarnMsg, setWriteWarnMsg] = useState<string>("");
  // Live counters so stopping a take can show real "saving to phone" progress
  // instead of a blank screen while the last chunks are still being written.
  const queuedRef = useRef(0);
  const writtenRef = useRef(0);
  const [finalizing, setFinalizing] = useState<{ done: number; total: number; phase: "writing" | "assembling" | "error" } | null>(null);
  const recordStartRef = useRef<number>(0);
  const [recording, setRecording] = useState(false);
  const recordingRef = useRef(false);
  const [elapsedMs, setElapsedMs] = useState(0);
  const [clips, setClips] = useState<ClipMeta[]>([]);
  const [clipsOpen, setClipsOpen] = useState(false);
  const [saveJob, setSaveJob] = useState<SaveJob | null>(null);

  type Quality = "720p" | "1080p" | "4k";
  const [quality, setQuality] = useState<Quality>(() => {
    if (typeof window === "undefined") return "1080p";
    return (localStorage.getItem("prompter.quality") as Quality) || "1080p";
  });
  useEffect(() => { try { localStorage.setItem("prompter.quality", quality); } catch {} }, [quality]);

  // Update scroll direction when mirrorV changes
  useEffect(() => {
    scrollDirectionRef.current = mirrorV ? -1 : 1;
    mirrorVRef.current = mirrorV;
  }, [mirrorV]);

  useEffect(() => { speedRef.current = speed; }, [speed]);
  useEffect(() => { fontSizeRef.current = fontSize; }, [fontSize]);
  useEffect(() => { voiceFollowRef.current = voiceFollow; }, [voiceFollow]);
  useEffect(() => { pausesRef.current = pauses; }, [pauses]);

  // Persist live edits back to settings
  useEffect(() => {
    onSettings({ ...settings, speed, fontSize, mirrorV, voiceFollow, chunking, pauses, readingHighlight });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [speed, fontSize, mirrorV, voiceFollow, chunking, pauses, readingHighlight]);


  // In video mode, use transparent background so the camera shows through.
  const bgClass = videoMode
    ? "bg-black text-neutral-50"
    : settings.bg === "white" ? "bg-white text-neutral-900"
    : settings.bg === "sepia" ? "bg-[#f5ecd7] text-[#2a1f0f]"
    : "bg-black text-neutral-50";

  // ==== Video mode: camera acquisition ====
  // Regexes for detecting external USB / wireless mics vs the iPhone built-in.
  // iOS Safari exposes labels like "DJI MIC 2 (Bluetooth)", "USB Audio Device",
  // "iPhone Microphone", etc. after mic permission is granted.
  const EXTERNAL_MIC_RE = /usb|dji|rode|røde|shure|sennheiser|zoom |comica|hollyland|godox|saramonic|maono|movo|boya|blue snowball|blue yeti|wireless|lavalier|lav mic|external|mic 2|mic pro|airpods|beats|bose|sony|jbl|bluetooth/i;
  const BUILTIN_MIC_RE = /built.?in|iphone|internal|default/i;

  const pickBestAudioInput = async (): Promise<{ id: string; label: string; external: boolean } | null> => {
    try {
      const devices = await navigator.mediaDevices.enumerateDevices();
      const inputs = devices.filter((d) => d.kind === "audioinput" && d.deviceId);
      if (inputs.length === 0) return null;
      // 1) explicit external hint in the label
      const ext = inputs.find((d) => d.label && EXTERNAL_MIC_RE.test(d.label));
      if (ext) return { id: ext.deviceId, label: ext.label, external: true };
      // 2) any non-default non-builtin labeled device when multiple exist
      const other = inputs.find(
        (d) => d.deviceId !== "default" && d.label && !BUILTIN_MIC_RE.test(d.label)
      );
      if (other && inputs.length > 1) return { id: other.deviceId, label: other.label, external: true };
      // 3) fallback to built-in
      const builtin = inputs.find((d) => BUILTIN_MIC_RE.test(d.label)) || inputs[0];
      return { id: builtin.deviceId, label: builtin.label || "Built-in mic", external: false };
    } catch {
      return null;
    }
  };

  // Replace the audio track on the live stream with the preferred mic.
  // External mics get raw audio (no processing) for max fidelity; built-in
  // gets echo/noise/gain processing on. Only runs when NOT recording so
  // MediaRecorder sync is never disturbed mid-clip.
  const refineAudioTrack = async (): Promise<void> => {
    const stream = streamRef.current;
    if (!stream || recordingRef.current) return;
    const pick = await pickBestAudioInput();
    if (!pick) return;
    const currentTrack = stream.getAudioTracks()[0];
    const currentId = currentTrack?.getSettings?.().deviceId as string | undefined;
    if (currentId === pick.id && currentMicIdRef.current === pick.id) {
      setActiveMicLabel(pick.label);
      setMicIsExternal(pick.external);
      return;
    }
    const swap = async (constraints: MediaTrackConstraints): Promise<boolean> => {
      const newAudio = await navigator.mediaDevices.getUserMedia({ audio: constraints });
      const newTrack = newAudio.getAudioTracks()[0];
      if (!newTrack) return false;
      // Swap tracks atomically on the same stream so the video element and
      // any future MediaRecorder see a single continuous stream.
      if (currentTrack) {
        stream.removeTrack(currentTrack);
        try { currentTrack.stop(); } catch {}
      }
      newTrack.enabled = true;
      stream.addTrack(newTrack);
      currentMicIdRef.current = pick.id;
      setActiveMicLabel(pick.label);
      setMicIsExternal(pick.external);
      setMicLive(true);
      return true;
    };
    // Preferences only — an unsatisfiable audio requirement must never cost us
    // the microphone entirely.
    const preferred: MediaTrackConstraints = {
      deviceId: { exact: pick.id },
      echoCancellation: !pick.external,
      noiseSuppression: !pick.external,
      autoGainControl: !pick.external,
      sampleRate: { ideal: 48000 },
      channelCount: { ideal: 2 },
    } as any;
    try {
      await swap(preferred);
    } catch {
      try { await swap({ deviceId: { exact: pick.id } } as any); }
      catch {
        // Keep whatever audio track we have if the swap fails.
      }
    }
  };

  // Put a live microphone back on the camera stream. Safe to call any time:
  // it never touches a healthy track and never stops the video.
  const reacquireMic = useCallback(async (): Promise<boolean> => {
    const stream = streamRef.current;
    if (!stream) return false;
    if (stream.getAudioTracks().some((t) => t.readyState === "live")) return true;
    try {
      const fresh = await navigator.mediaDevices.getUserMedia({
        audio: currentMicIdRef.current
          ? ({ deviceId: { exact: currentMicIdRef.current } } as any)
          : true,
      });
      const t = fresh.getAudioTracks()[0];
      if (!t) return false;
      stream.getAudioTracks().forEach((old) => { try { stream.removeTrack(old); } catch {} });
      t.enabled = true;
      stream.addTrack(t);
      setMicLive(true);
      setCamError(null);
      return true;
    } catch {
      // Fall back to the default device if the remembered one vanished.
      if (currentMicIdRef.current) {
        currentMicIdRef.current = "";
        return reacquireMic();
      }
      return false;
    }
  }, []);

  // Mic watchdog: while the camera is open, keep checking that a live audio
  // track is attached and repair it before the user ever presses record.
  useEffect(() => {
    if (!videoMode) return;
    const check = () => {
      const stream = streamRef.current;
      if (!stream) return;
      const live = stream.getAudioTracks().some((t) => t.readyState === "live");
      setMicLive(live);
      if (!live && !recordingRef.current) void reacquireMic();
    };
    check();
    const id = window.setInterval(check, 2000);
    return () => window.clearInterval(id);
  }, [videoMode, reacquireMic]);




  useEffect(() => {
    if (!videoMode) return;
    let cancelled = false;
    const getConstraints = (q: Quality): MediaStreamConstraints => {
      const dims = q === "4k" ? { width: 3840, height: 2160 }
                : q === "1080p" ? { width: 1920, height: 1080 }
                : { width: 1280, height: 720 };
      const videoConstraints: any = {
        // Every value is a preference, never a requirement: one unsatisfiable
        // requirement makes the whole camera fail to open.
        facingMode: { ideal: "user" },
        width: { ideal: dims.width },
        height: { ideal: dims.height },
        frameRate: { ideal: 60 },
      };

      return {
        video: videoConstraints as MediaTrackConstraints,
        audio: {
          echoCancellation: true,
          noiseSuppression: true,
          autoGainControl: true,
          sampleRate: { ideal: 48000 },
          channelCount: { ideal: 2 },
        } as MediaTrackConstraints,
      };
    };
    const start = async () => {
      try {
        // Try requested quality, then lower tiers, then a bare request. The
        // camera must always open: a picky constraint is never a reason to
        // leave the user with a dead record button.
        let stream: MediaStream | null = null;
        const tiers: Quality[] = quality === "4k" ? ["4k", "1080p", "720p"]
                                : quality === "1080p" ? ["1080p", "720p"]
                                : ["720p"];
        const attempts: MediaStreamConstraints[] = [
          ...tiers.map(getConstraints),
          { video: { facingMode: { ideal: "user" } }, audio: true },
          { video: true, audio: true },
        ];
        let lastErr: unknown = null;
        for (const constraints of attempts) {
          try { stream = await navigator.mediaDevices.getUserMedia(constraints); break; }
          catch (e) { lastErr = e; }
        }
        if (!stream) throw lastErr || new Error("Camera unavailable.");
        if (cancelled) { stream.getTracks().forEach(t => t.stop()); return; }
        // Lock the camera at 1x zoom after acquisition as a safety net; some
        // browsers ignore zoom in getUserMedia but honor it via applyConstraints.
        stream.getVideoTracks().forEach(track => {
          try { track.applyConstraints({ advanced: [{ zoom: 1 }] } as any)?.catch?.(() => {}); } catch {}
        });
        streamRef.current = stream;
        if (videoElRef.current) {
          videoElRef.current.srcObject = stream;
          try { await videoElRef.current.play(); } catch {}
        }
        // The camera is usable the moment a live video track exists. Audio is
        // handled separately: a mic problem must never leave the record button
        // permanently disabled.
        const liveVideo = stream.getVideoTracks().some((t) => t.readyState === "live");
        if (!liveVideo) throw new Error("The camera didn't start. Close other apps using the camera and reopen Video mode.");
        setCamReady(true);
        setCamError(null);

        // Now that mic permission is granted, labels are visible — pick the
        // best available input (external USB / wireless mic if present).
        await refineAudioTrack();
        if (cancelled) return;
        const liveAudio = stream.getAudioTracks().some((audioTrack) => audioTrack.readyState === "live");
        setMicLive(liveAudio);
        if (!liveAudio) {
          const ok = await reacquireMic();
          if (!ok) setCamError("No microphone detected. Reconnect it — recording needs sound.");
        }


        // iOS drops out of fullscreen when the camera-permission prompt appears
        // on first grant. Re-request landscape now that the prompt is gone so
        // video mode behaves identically to text mode.
        if (!document.fullscreenElement && !(document as any).webkitFullscreenElement) {
          enterLandscape();
        } else {
          try { (screen as any).orientation?.lock?.("landscape")?.catch?.(() => {}); } catch {}
        }
      } catch (e: any) {
        setCamError(e?.message || "Camera unavailable. Check Settings → Safari → Camera.");
      }
    };
    start();
    // Re-pick mic whenever devices change (plug/unplug DJI Mic 2, AirPods, etc.).
    const onDeviceChange = () => { refineAudioTrack(); };
    try { navigator.mediaDevices.addEventListener("devicechange", onDeviceChange); } catch {}
    return () => {
      cancelled = true;
      try { navigator.mediaDevices.removeEventListener("devicechange", onDeviceChange); } catch {}
      if (recorderRef.current && recorderRef.current.state !== "inactive") {
        try { recorderRef.current.stop(); } catch {}
      }
      streamRef.current?.getTracks().forEach((t) => t.stop());
      streamRef.current = null;
      setCamReady(false);
      setActiveMicLabel("");
      setMicIsExternal(false);
      currentMicIdRef.current = "";
    };
    // Re-acquire on quality change
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [videoMode, quality]);


  // Load existing clips, recover any orphan session from a prior crash / close,
  // and ask for persistent storage so recordings survive eviction.
  useEffect(() => {
    if (!videoMode) return;
    let cancelled = false;
    (async () => {
      try { await requestPersistentStorage(); } catch {}
      try { await recoverOrphanSessions(); } catch {}
      if (cancelled) return;
      try { const list = await listClipMeta(script.id); if (!cancelled) setClips(list); } catch {}
    })();
    return () => { cancelled = true; };
  }, [videoMode, script.id]);

  // Real headroom, straight from the browser. Shown alongside any storage
  // warning so the message is never a guess.
  const [freeSpaceLabel, setFreeSpaceLabel] = useState("");
  useEffect(() => {
    if (!videoMode) return;
    let stop = false;
    const read = async () => {
      try {
        const est = await navigator.storage?.estimate?.();
        if (stop || !est || !est.quota) return;
        const free = Math.max(0, (est.quota || 0) - (est.usage || 0));
        setFreeSpaceLabel(`${fmtSize(free)} left for the app`);
      } catch {}
    };
    void read();
    const id = window.setInterval(read, 20000);
    return () => { stop = true; window.clearInterval(id); };
  }, [videoMode]);



  // Restore reader state per script in video mode (scrollTop only; other prefs already persist globally)
  const readerStateKey = `prompter.readerState.${script.id}`;
  useEffect(() => {
    if (!videoMode) return;
    const el = scrollRef.current;
    if (!el) return;
    try {
      const raw = localStorage.getItem(readerStateKey);
      if (raw) {
        const s = JSON.parse(raw) as { scrollTop?: number };
        if (typeof s.scrollTop === "number") {
          // Wait one frame so layout is measured
          requestAnimationFrame(() => { if (scrollRef.current) scrollRef.current.scrollTop = s.scrollTop!; setProgress(computeProgress()); });
        }
      }
    } catch {}
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [videoMode, script.id]);

  // Persist scroll position (debounced) in video mode
  const saveStateTimer = useRef<number | null>(null);
  const scheduleSaveState = useCallback(() => {
    if (!videoMode) return;
    if (saveStateTimer.current) window.clearTimeout(saveStateTimer.current);
    saveStateTimer.current = window.setTimeout(() => {
      const el = scrollRef.current;
      if (!el) return;
      try { localStorage.setItem(readerStateKey, JSON.stringify({ scrollTop: el.scrollTop, updatedAt: Date.now() })); } catch {}
    }, 250);
  }, [videoMode, readerStateKey]);

  // Recording timer tick
  useEffect(() => {
    if (!recording) return;
    const id = window.setInterval(() => setElapsedMs(Date.now() - recordStartRef.current), 200);
    return () => window.clearInterval(id);
  }, [recording]);

  const pickMime = (): string => {
    const candidates = [
      "video/mp4;codecs=h264,mp4a.40.2",
      "video/mp4",
      "video/webm;codecs=h264,opus",
      "video/webm;codecs=vp9,opus",
      "video/webm",
    ];
    for (const m of candidates) {
      if (typeof MediaRecorder !== "undefined" && MediaRecorder.isTypeSupported(m)) return m;
    }
    return "";
  };

  const startRecording = useCallback(() => {
    const stream = streamRef.current;
    if (!stream) { setCamError("The camera isn't ready yet. Give it a second and press record again."); return; }
    if (recording || recordingRef.current) return;

    // MIC FIRST: a take without sound is worthless, so a live microphone is a
    // hard requirement. The check is synchronous (an await here would cost the
    // iOS user-gesture and the recorder would silently refuse to start); if the
    // mic is missing we refuse to roll, repair it in the background, and tell
    // the user to press record again.
    let hasAudio = false;
    try {
      stream.getAudioTracks().forEach((t) => { t.enabled = true; });
      hasAudio = stream.getAudioTracks().some((t) => t.readyState === "live" && !t.muted);
      if (!hasAudio) hasAudio = stream.getAudioTracks().some((t) => t.readyState === "live");
    } catch {}
    if (!hasAudio) {
      setCamError("No live microphone — reconnecting it now. Press record again in a second.");
      void reacquireMic();
      return;
    }


    const mimeType = pickMime();
    // Match iPhone-native quality tiers. iOS records 1080p60 at ~10-12 Mbps
    // and 4K30 at ~40-50 Mbps; we mirror those numbers so recordings look
    // as good as the native Camera app.
    const bps = quality === "4k" ? 45_000_000 : quality === "1080p" ? 14_000_000 : 6_000_000;
    const audioBps = 192_000;
    let rec: MediaRecorder;
    try {
      rec = new MediaRecorder(stream, mimeType
        ? { mimeType, videoBitsPerSecond: bps, audioBitsPerSecond: audioBps }
        : { videoBitsPerSecond: bps, audioBitsPerSecond: audioBps });
    } catch {
      try { rec = new MediaRecorder(stream); }
      catch {
        setCamError("This browser can't record video. Open the app in Safari and try again.");
        return;
      }
    }

    const recordingId = Math.random().toString(36).slice(2, 12);
    const track = stream.getVideoTracks()[0];
    const s = track?.getSettings?.() || {};
    const finalMime = rec.mimeType || mimeType || "video/mp4";
    const startedAt = Date.now();

    // Creating the durable session happens in the background; chunk writes
    // queue behind it, so no footage can be written before it exists.
    const sessionReady = createSession({
      id: recordingId,
      scriptId: script.id,
      mimeType: finalMime,
      startedAt,
      width: (s.width as number) || 0,
      height: (s.height as number) || 0,
    }).catch((err) => { setWriteWarn(true); setWriteWarnMsg(describeStorageError(err)); });

    recordingIdRef.current = recordingId;
    appendQueueRef.current = sessionReady;
    writeFailRef.current = 0;
    queuedRef.current = 0;
    writtenRef.current = 0;
    setWriteWarn(false);
    setWriteWarnMsg("");
    setFinalizing(null);

    // Serialize durable writes. Do not retain a second full recording in RAM:
    // long high-quality takes otherwise exceed iPhone Safari's memory limit.
    // Each write is retried with growing backoff: a transient storage hiccup
    // (Safari briefly refusing writes while it reclaims space) must never
    // silently drop a second of footage.
    const writeChunk = async (blob: Blob) => {
      let lastErr: unknown = null;
      for (let attempt = 0; attempt < 6; attempt++) {
        try {
          await appendChunk(recordingId, blob);
          writtenRef.current += 1;
          if (writeFailRef.current === 0) { setWriteWarn(false); setWriteWarnMsg(""); }
          return;
        } catch (err) {
          lastErr = err;
          await new Promise((r) => setTimeout(r, 200 * (attempt + 1)));
        }
      }
      writtenRef.current += 1;
      writeFailRef.current += 1;
      // One retried-and-recovered hiccup is normal on iOS; only surface a
      // warning if footage is actually repeatedly failing to store.
      if (writeFailRef.current >= 2) {
        setWriteWarn(true);
        setWriteWarnMsg(describeStorageError(lastErr));
      }
    };


    rec.ondataavailable = (e) => {
      if (!e.data || e.data.size === 0) return;
      const blob = e.data;
      queuedRef.current += 1;
      appendQueueRef.current = appendQueueRef.current
        .catch(() => {})
        .then(() => writeChunk(blob));
    };

    let finalized = false;
    const finishRecording = () => {
      if (finalized) return;
      finalized = true;
      recordingRef.current = false;
      recorderRef.current = null;
      recordingIdRef.current = null;
      setRecording(false);
      setPlaying(false);
      setControlsVisible(true);
      // Saving is normally instant. Only show the progress panel if the last
      // pieces genuinely take a moment, so a quick stop looks like it always did.
      let done = false;
      let tick = 0;
      const reveal = window.setTimeout(() => {
        if (done) return;
        setFinalizing({ done: writtenRef.current, total: Math.max(queuedRef.current, 1), phase: "writing" });
        tick = window.setInterval(() => {
          setFinalizing((f) => (f && f.phase === "writing"
            ? { ...f, done: writtenRef.current, total: Math.max(queuedRef.current, 1) }
            : f));
        }, 120);
      }, 900);
      const clearTimers = () => { done = true; window.clearTimeout(reveal); if (tick) window.clearInterval(tick); };
      appendQueueRef.current
        .catch(() => {})
        .then(() => {
          if (tick) window.clearInterval(tick);
          setFinalizing((f) => (f ? { done: queuedRef.current, total: Math.max(queuedRef.current, 1), phase: "assembling" } : null));
          return finalizeSession(recordingId, { durationMs: Date.now() - recordStartRef.current });
        })
        .then((clip) => {
          clearTimers();
          if (clip) setClips((cs) => [clip, ...cs.filter((c) => c.id !== clip.id)]);
          setFinalizing(null);
        })
        .catch(() => {
          clearTimers();
          setWriteWarn(true);
          setFinalizing({ done: writtenRef.current, total: Math.max(queuedRef.current, 1), phase: "error" });
        });
    };

    rec.onerror = finishRecording;

    rec.onstop = finishRecording;

    recordStartRef.current = Date.now();
    setElapsedMs(0);
    // 1s timeslice = big enough to keep write overhead low, small enough
    // that at most ~1s of footage is ever unflushed if the process dies.
    recordingRef.current = true;
    try {
      rec.start(1000);
    } catch {
      try { rec.start(); }
      catch {
        recordingRef.current = false;
        recordingIdRef.current = null;
        setCamError("Recording couldn't start. Close other apps using the camera, then try again.");
        return;
      }
    }
    recorderRef.current = rec;
    setRecording(true);
    setCamError(null);
    // Start the script rolling in sync with the recording
    setPlaying(true);
    setControlsVisible(false);
    setPanel(null);
  }, [quality, recording, script.id, reacquireMic]);

  const stopRecording = useCallback(() => {
    const rec = recorderRef.current;
    if (!rec) return;
    try { if (rec.state === "recording") rec.requestData(); } catch {}
    try { if (rec.state !== "inactive") rec.stop(); } catch {}
    recorderRef.current = null;
    setRecording(false);
    // Stop the script when recording stops
    setPlaying(false);
    setControlsVisible(true);
    // Persist scroll position IMMEDIATELY so it survives an app close / reload.
    // The debounced scheduleSaveState may not fire before the page unloads.
    const el = scrollRef.current;
    if (el) {
      try { localStorage.setItem(readerStateKey, JSON.stringify({ scrollTop: el.scrollTop, updatedAt: Date.now() })); } catch {}
    }
  }, [readerStateKey]);

  // Stop recording cleanly if user backgrounds the app, and flush scroll position
  useEffect(() => {
    if (!videoMode) return;
    const flush = () => {
      const el = scrollRef.current;
      if (!el) return;
      try { localStorage.setItem(readerStateKey, JSON.stringify({ scrollTop: el.scrollTop, updatedAt: Date.now() })); } catch {}
    };
    const onVis = () => {
      if (document.visibilityState === "hidden") {
        flush();
        if (recording) stopRecording();
      }
    };
    const onPageHide = () => flush();
    document.addEventListener("visibilitychange", onVis);
    window.addEventListener("pagehide", onPageHide);
    return () => {
      document.removeEventListener("visibilitychange", onVis);
      window.removeEventListener("pagehide", onPageHide);
    };
  }, [videoMode, recording, stopRecording, readerStateKey]);

  // Save straight to the iPhone camera roll. iOS only offers "Save Video" in
  // the share sheet for a real .mp4 with a clean MIME type, one file at a
  // time, and only when share() is reached inside the tap that triggered it —
  // so no awaits before the call, no codec parameters, no multi-file batches.
  const exportClip = useCallback((clip: ClipMeta) => {
    startSave(clip, script.title, setSaveJob);
  }, [script.title]);



  // Re-measuring is expensive, so size changes only trigger it once the user
  // stops moving the slider.
  const [measureTick, setMeasureTick] = useState(0);
  useEffect(() => {
    const id = window.setTimeout(() => setMeasureTick((t) => t + 1), 160);
    return () => window.clearTimeout(id);
  }, [fontSize, settings.width]);

  // Recompute pause-anchor Y positions when layout may have shifted.
  useLayoutEffect(() => {
    const sc = scrollRef.current;
    const inner = textInnerRef.current;
    if (!sc || !inner) return;
    let raf = 0;
    const compute = () => {
      const anchors: Array<{ y: number; kind: "strong" | "soft" }> = [];
      const ys = new Float32Array(wordRefsRef.current.length);
      for (let i = 0; i < wordRefsRef.current.length; i++) {
        const el = wordRefsRef.current[i];
        if (!el) { ys[i] = Number.POSITIVE_INFINITY; continue; }
        // offsetTop is not affected by the beam-splitter transform. Using
        // getBoundingClientRect here made the array run backward in mirror
        // mode, which broke the binary search and voice cursor completely.
        ys[i] = el.offsetTop + inner.offsetTop;
      }
      wordYsRef.current = ys;
      for (const t of tokens) {
        if (t.kind !== "word" || !t.pauseAfter) continue;
        const el = wordRefsRef.current[t.wordIndex];
        if (!el) continue;
        // Keep pause positions in the same logical, transform-independent
        // coordinate system as word tracking. Viewport rectangles change when
        // the beam-splitter flip is active and can leave the scroll loop stuck
        // slowing at the wrong punctuation mark.
        anchors.push({ y: wordYsRef.current[t.wordIndex] + el.offsetHeight, kind: t.pauseAfter });
      }
      anchors.sort((a, b) => a.y - b.y);
      pauseAnchorsRef.current = anchors;
    };
    // Wait one frame so fonts / wrapping settle before measuring.
    raf = requestAnimationFrame(compute);
    // Measuring every word is an O(words) layout pass. While a size slider is
    // being dragged the container resizes continuously, so settle first and
    // measure once the movement stops — this is what removed the drag stutter.
    let settle = 0;
    const ro = new ResizeObserver(() => {
      window.clearTimeout(settle);
      settle = window.setTimeout(() => {
        cancelAnimationFrame(raf);
        raf = requestAnimationFrame(compute);
      }, 140);
    });
    ro.observe(inner);
    return () => { cancelAnimationFrame(raf); window.clearTimeout(settle); ro.disconnect(); };
  }, [tokens, measureTick, mirrorV]);

  // Track the word at the eye-line on every scroll. Voice recognition uses this
  // position even when the optional visual reading highlight is switched off.
  useEffect(() => {
    const sc = scrollRef.current;
    if (!sc) return;
    if (!readingHighlight) {
      const prev = activeReadIdxRef.current;
      if (prev >= 0) wordRefsRef.current[prev]?.classList.remove("reading-word");
    }
    let raf = 0;
    const update = () => {
      raf = 0;
      const ys = wordYsRef.current;
      if (!ys.length) return;
      // Eye-line: about 40% down the viewport (matches punctuation-pause line).
      const maxScroll = Math.max(0, sc.scrollHeight - sc.clientHeight);
      const logicalScrollTop = mirrorV ? maxScroll - sc.scrollTop : sc.scrollTop;
      const eyeY = logicalScrollTop + sc.clientHeight * 0.4;
      // Binary search: last word with y <= eyeY.
      let lo = 0, hi = ys.length - 1, idx = 0;
      while (lo <= hi) {
        const m = (lo + hi) >> 1;
        if (ys[m] <= eyeY) { idx = m; lo = m + 1; } else hi = m - 1;
      }
      const prev = activeReadIdxRef.current;
      if (idx === prev) return;
      if (readingHighlight && prev >= 0) {
        const pe = wordRefsRef.current[prev];
        if (pe) pe.classList.remove("reading-word");
      }
      if (readingHighlight) wordRefsRef.current[idx]?.classList.add("reading-word");
      activeReadIdxRef.current = idx;
    };
    const schedule = () => { if (!raf) raf = requestAnimationFrame(update); };
    sc.addEventListener("scroll", schedule, { passive: true });
    schedule(); // initial paint
    return () => {
      sc.removeEventListener("scroll", schedule);
      if (raf) cancelAnimationFrame(raf);
      const prev = activeReadIdxRef.current;
      if (prev >= 0) wordRefsRef.current[prev]?.classList.remove("reading-word");
      activeReadIdxRef.current = -1;
    };
  }, [readingHighlight, tokens, fontSize, settings.width, mirrorV]);


  // Voice-paced: highlight the spoken word and let the tick loop use it to
  // stretch/compress the base scroll speed. No jumping to positions — the
  // prompt keeps its glide, just faster or slower to match your voice.
  useEffect(() => {
    if (!voiceFollow) {
      const prev = prevAnchorRef.current;
      if (prev >= 0) wordRefsRef.current[prev]?.classList.remove("vf-anchor");
      prevAnchorRef.current = -1;
      voicePaceTargetRef.current = 1;
      return;
    }
    const prev = prevAnchorRef.current;
    if (prev >= 0 && prev !== anchorWordIndex) {
      const p = wordRefsRef.current[prev];
      if (p) p.classList.remove("vf-anchor");
    }
    if (anchorWordIndex >= 0) {
      const el = wordRefsRef.current[anchorWordIndex];
      if (el) el.classList.add("vf-anchor");
    }
    prevAnchorRef.current = anchorWordIndex;
  }, [anchorWordIndex, voiceFollow]);

  const computeProgress = useCallback(() => {
    const el = scrollRef.current;
    if (!el) return 0;
    const max = el.scrollHeight - el.clientHeight;
    if (max <= 0) return 1;
    const raw = el.scrollTop / max;
    // When mirrored we start at the bottom and scroll toward top,
    // so invert the raw ratio so progress still goes 0 -> 1.
    const p = mirrorVRef.current ? 1 - raw : raw;
    return Math.min(1, Math.max(0, p));
  }, []);

  // Write progress to the two elements that show it, bypassing React. State is
  // only synced a couple of times a second so anything else that reads
  // `progress` stays correct without paying for 60 re-renders a second.
  const paintProgress = useCallback((p: number) => {
    progressRef.current = p;
    const bar = progressBarRef.current;
    if (bar) bar.style.width = `${(p * 100).toFixed(2)}%`;
    const badge = remainingRef.current;
    if (badge) {
      const txt = `${Math.round((1 - p) * 100)}% left`;
      if (badge.textContent !== txt) badge.textContent = txt;
    }
    const now = performance.now();
    if (now - lastProgressSyncRef.current > 400) {
      lastProgressSyncRef.current = now;
      setProgress(p);
    }
  }, []);

  const tick = useCallback((ts: number) => {
    const el = scrollRef.current;
    if (!el) return;
    lastFrameWallRef.current = performance.now();
    if (!lastTsRef.current) lastTsRef.current = ts;
    // Clamp long frames so returning from an iOS interruption never jumps.
    const dt = Math.min((ts - lastTsRef.current) / 1000, 0.05);
    lastTsRef.current = ts;
    const dir = scrollDirectionRef.current;
    const currentMirrorV = mirrorVRef.current;
    const currentVoiceFollow = voiceFollowRef.current;
    // Punctuation assist only eases the base speed; it can never stop it.
    let mult = 1;
    if (pausesRef.current) {
      const anchors = pauseAnchorsRef.current;
      if (anchors.length) {
        const maxScroll = Math.max(0, el.scrollHeight - el.clientHeight);
        const logicalScrollTop = currentMirrorV ? maxScroll - el.scrollTop : el.scrollTop;
        const readY = logicalScrollTop + el.clientHeight * 0.4;
        // Binary-search last anchor with y <= readY.
        let lo = 0, hi = anchors.length - 1, idx = -1;
        while (lo <= hi) {
          const m = (lo + hi) >> 1;
          if (anchors[m].y <= readY) { idx = m; lo = m + 1; } else hi = m - 1;
        }
        if (idx >= 0) {
            const decay = Math.max(40, fontSizeRef.current * 1.4);
          const dist = readY - anchors[idx].y;
          if (dist >= 0 && dist < decay) {
            const t01 = dist / decay; // 0 = at punctuation → 1 = fully past
            const base = anchors[idx].kind === "strong" ? 0.68 : 0.82;
            mult = base + (1 - base) * t01;
          }
        }
      }
    }

    // Voice-paced multiplier: compare where the speaker is (highlighted
    // word) to where the prompt is (eye-line). Ahead → speed up. Behind
    // → slow down. Eased smoothly so speed changes glide.
    if (currentVoiceFollow) {
      const idx = anchorWordIndexRef.current;
      const wordYs = wordYsRef.current;
      let target = 1;
      if (idx >= 0 && idx < wordYs.length && Number.isFinite(wordYs[idx])) {
        const inner = textInnerRef.current;
        const wordY = wordYs[idx] + (inner?.offsetTop ?? 0);
        const H = el.clientHeight;
        const maxScroll = Math.max(0, el.scrollHeight - H);
        const logicalScrollTop = currentMirrorV ? maxScroll - el.scrollTop : el.scrollTop;
        // Eye-line at ~34% down leaves the upcoming sentence in focus.
        const eyeLineY = logicalScrollTop + H * 0.34;
        // Positive lead = speaker is ahead of the prompt (below the eye-line).
        const leadPx = wordY - eyeLineY;
        // Normalise by viewport height so the response feels the same on
        // phone landscape and tablet portrait. Gain of 3.0 gives full
        // speed-up (~3x) when the speaker is a full viewport ahead.
        const norm = leadPx / H;
        target = Math.max(0.2, Math.min(3.2, 1 + norm * 3.0));
        // Small dead-zone so ordinary reading noise doesn't wobble speed.
        if (Math.abs(norm) < 0.05) target = 1;
      }
      voicePaceTargetRef.current = target;
    } else {
      voicePaceTargetRef.current = 1;
    }
    // ~330 ms glide toward the target multiplier — noticeable enough to
    // keep pace, gentle enough to never feel like a lurch.
    const paceAlpha = Math.min(1, dt * 3.0);
    voicePaceMultRef.current += (voicePaceTargetRef.current - voicePaceMultRef.current) * paceAlpha;
    if (Math.abs(voicePaceMultRef.current - 1) < 0.005) voicePaceMultRef.current = 1;

    const frameAdvance = playingRef.current
      ? dir * speedRef.current * mult * voicePaceMultRef.current * dt
      : 0;
    el.scrollTop += frameAdvance;
    const p = computeProgress();
    // Paint the progress bar and the "% left" badge straight to the DOM.
    // Putting this in React state re-rendered the whole reader 60x a second,
    // which is what made scrolling feel heavy on the phone.
    paintProgress(p);
    if (p >= 1) { setPlaying(false); return; }
    if (playingRef.current) {
      rafRef.current = requestAnimationFrame(tick);
    } else {
      rafRef.current = null;
    }
  }, [computeProgress]);




  useEffect(() => {
    playingRef.current = playing;
    if (playing) {
      lastTsRef.current = 0;
      lastFrameWallRef.current = performance.now();
      rafRef.current = requestAnimationFrame(tick);
    } else if (rafRef.current) {
      cancelAnimationFrame(rafRef.current);
      rafRef.current = null;
    }
    return () => {
      if (rafRef.current !== null) cancelAnimationFrame(rafRef.current);
      rafRef.current = null;
    };
  }, [playing, tick]);

  // iOS can occasionally drop a pending animation frame after a system UI,
  // permission prompt, or brief app interruption. Recover the loop without
  // changing the reader's position or play/pause state.
  useEffect(() => {
    const resumeIfStalled = () => {
      if (!playingRef.current || document.visibilityState !== "visible") return;
      const now = performance.now();
      if (now - lastFrameWallRef.current < 900) return;
      if (rafRef.current !== null) cancelAnimationFrame(rafRef.current);
      lastTsRef.current = 0;
      lastFrameWallRef.current = now;
      rafRef.current = requestAnimationFrame(tick);
    };
    const onVisible = () => {
      if (document.visibilityState === "visible") {
        lastFrameWallRef.current = 0;
        resumeIfStalled();
      }
    };
    // Only poll while actually rolling; an idle screen needs no timer.
    const watchdog = playing ? window.setInterval(resumeIfStalled, 500) : 0;
    document.addEventListener("visibilitychange", onVisible);
    window.addEventListener("pageshow", resumeIfStalled);
    return () => {
      window.clearInterval(watchdog);
      document.removeEventListener("visibilitychange", onVisible);
      window.removeEventListener("pageshow", resumeIfStalled);
    };
  }, [tick, playing]);

  const togglePlay = () => {
    setPlaying((p) => {
      const next = !p;
      if (next) { setControlsVisible(false); setPanel(null); }
      else { setControlsVisible(true); }
      return next;
    });
  };
  const reset = () => {
    setPlaying(false);
    const el = scrollRef.current;
    if (el) {
      const max = el.scrollHeight - el.clientHeight;
      el.scrollTop = mirrorV && max > 0 ? max : 0;
    }
    setProgress(0);
  };
  // Smooth nudge that does NOT stop playback. While playing, the rAF tick
  // mutates scrollTop every frame, so a CSS smooth-scroll target would be
  // overwritten immediately — we apply the offset directly instead.
  const nudge = useCallback((dir: 1 | -1) => {
    const el = scrollRef.current;
    if (!el) return;
    const step = dir * Math.max(60, el.clientHeight * 0.18);
    // When mirrored, scroll direction is reversed, so invert the nudge.
    const effectiveStep = mirrorV ? -step : step;
    if (playing) {
      el.scrollTop += effectiveStep;
    } else {
      try { el.scrollBy({ top: effectiveStep, behavior: "smooth" }); }
      catch { el.scrollTop += effectiveStep; }
    }
    setProgress(computeProgress());
  }, [computeProgress, playing, mirrorV]);

  // Bluetooth remote (Desview RM-S1/S2 etc.) keyboard mapping
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const tag = (e.target as HTMLElement)?.tagName;
      if (tag === "INPUT" || tag === "TEXTAREA") return;
      const k = e.key, code = e.code;

      // Escape / Home / font size.
      // While recording, the remote must NEVER be able to stop or exit —
      // Escape would tear down video mode and abort the recording as a side effect.
      if (k === "Escape" || code === "Escape") {
        e.preventDefault();
        if (recordingRef.current) return; // swallow — remote is text-only during recording
        onExit();
        return;
      }
      if (k === "0" || k === "Home") { e.preventDefault(); reset(); return; }
      if (k === "]") { e.preventDefault(); setFontSize((s) => Math.min(140, s + 2)); return; }
      if (k === "[") { e.preventDefault(); setFontSize((s) => Math.max(24, s - 2)); return; }

      // Up / Down — scroll position. NEVER toggles play. Keeps rolling.
      if (k === "ArrowUp" || k === "PageUp" || code === "PageUp" ||
          k === "AudioVolumeUp" || k === "VolumeUp") {
        e.preventDefault(); nudge(-1); return;
      }
      if (k === "ArrowDown" || k === "PageDown" || code === "PageDown" ||
          k === "AudioVolumeDown" || k === "VolumeDown") {
        e.preventDefault(); nudge(1); return;
      }

      // Left / Right — adjust speed.
      if (k === "ArrowLeft" || k === "-" || k === "_") {
        e.preventDefault(); setSpeed((s) => Math.max(10, s - 5)); return;
      }
      if (k === "ArrowRight" || k === "+" || k === "=") {
        e.preventDefault(); setSpeed((s) => Math.min(250, s + 5)); return;
      }

      // Play / pause — space, enter, media keys, k/p, tab, dot, F5
      const playKeys = [
        " ", "Spacebar", "Enter", "MediaPlayPause", "MediaPlay", "MediaPause",
        "k", "K", "p", "P", ".", "Tab", "F5",
      ];
      if (playKeys.includes(k) || playKeys.includes(code)) {
        e.preventDefault();
        togglePlay();
      }
    };
    window.addEventListener("keydown", onKey, { capture: true });
    return () => window.removeEventListener("keydown", onKey, { capture: true } as any);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [nudge, onExit]);

  // Wake lock
  useEffect(() => {
    let wakeLock: any = null;
    const req = async () => { try { wakeLock = await (navigator as any).wakeLock?.request("screen"); } catch {} };
    req();
    const onVis = () => { if (document.visibilityState === "visible") req(); };
    document.addEventListener("visibilitychange", onVis);
    return () => { document.removeEventListener("visibilitychange", onVis); try { wakeLock?.release(); } catch {} };
  }, []);

  // On first mount, position scroll based on initial mirror state.
  const didInitScrollRef = useRef(false);
  useEffect(() => {
    if (didInitScrollRef.current) return;
    const el = scrollRef.current;
    if (!el) return;
    const max = el.scrollHeight - el.clientHeight;
    el.scrollTop = mirrorV && max > 0 ? max : 0;
    setProgress(0);
    didInitScrollRef.current = true;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Toggle mirror while preserving the user's place in the script.
  // Flipping the text upside-down also reverses scroll direction, so we
  // mirror scrollTop (max - current) so the same line stays on screen.
  const toggleMirror = useCallback(() => {
    const el = scrollRef.current;
    if (el) {
      const max = el.scrollHeight - el.clientHeight;
      if (max > 0) el.scrollTop = max - el.scrollTop;
    }
    setMirrorV((v) => !v);
    setProgress((p) => p); // keep progress; computeProgress will resync on next scroll/tick
  }, []);

  const onScroll = () => { if (!playing) setProgress(computeProgress()); scheduleSaveState(); };
  const remaining = Math.round((1 - progress) * 100);

  // Portrait detection for hint only (no auto-rotate)
  useEffect(() => {
    const mq = window.matchMedia("(orientation: portrait)");
    const update = () => setIsPortrait(mq.matches);
    update();
    mq.addEventListener?.("change", update);
    return () => { mq.removeEventListener?.("change", update); };
  }, []);

  const iconBtn = "grid h-10 w-10 sm:h-11 sm:w-11 shrink-0 place-items-center rounded-full text-neutral-300 active:scale-90 transition";

  return (
    <div className={`${bgClass} fixed inset-0 overflow-hidden select-none`} style={{ fontFamily: "var(--font-prompter)" }}>
      {/* Camera preview — behind everything in video mode. Mirrored for natural feel; recorded stream is NOT mirrored. */}
      {videoMode && (
        <>
          <video
            ref={videoElRef}
            className="absolute inset-0 h-full w-full object-cover"
            style={{ transform: "scaleX(-1) translateZ(0)", willChange: "transform" }}
            autoPlay
            muted
            playsInline
          />
          {/* Dark scrim so the script stays readable over the video */}
          <div className="pointer-events-none absolute inset-0 bg-black/45" />
          {camError && (
            <div className="absolute inset-0 z-40 grid place-items-center bg-black/80 p-6 text-center text-sm text-neutral-200">
              <div>
                <div className="mb-2 font-bold text-amber-300">Camera unavailable</div>
                <div className="mb-3 text-neutral-300">{camError}</div>
                <button onClick={onExit} className="rounded-full bg-amber-400 px-4 py-2 text-sm font-bold text-black">Back</button>
              </div>
            </div>
          )}
        </>
      )}

      {/* Scrolling text — finger tap pauses and reveals controls */}
      <div
        ref={scrollRef}
        onScroll={onScroll}
        onClick={() => { togglePlay(); }}
        className="absolute inset-0 overflow-y-auto overscroll-contain"
        style={{ WebkitOverflowScrolling: "touch", contain: "layout paint", willChange: playing ? "scroll-position" : undefined }}
      >
        <div className="mx-auto" style={{ width: `${settings.width}%` }}>
          <div style={{ height: "20vh" }} />
          <div
            ref={textInnerRef}
            className="whitespace-pre-wrap"
            style={{
              fontSize: `${fontSize}px`,
              fontWeight: 500,
              lineHeight: 1.5,
              letterSpacing: "-0.015em",
              wordBreak: "keep-all",
              overflowWrap: "break-word",
              WebkitHyphens: "none",
              hyphens: "none",
              lineBreak: "strict",
              textWrap: "pretty",
              fontFeatureSettings: '"kern" 1, "palt" 1',
              textRendering: "optimizeLegibility",
              WebkitFontSmoothing: "antialiased",
              transform: mirrorV ? "scaleY(-1)" : undefined,
            } as React.CSSProperties}
          >
            {scriptNodes}
          </div>


          <div style={{ height: "80vh" }} />
        </div>
      </div>

      {/* Portrait nudge — only hint, no rotation hack */}
      {isPortrait && (
        <div className="pointer-events-none absolute inset-x-0 top-4 z-30 flex justify-center">
          <div className="rounded-full bg-black/70 px-3 py-1 text-xs text-amber-300 backdrop-blur-sm">
            Rotate your phone sideways
          </div>
        </div>
      )}

      {/* Popovers */}
      {panel === "settings" && (
        <Popover onClose={() => setPanel(null)}>
          <PopRow label="Speed" value={`${speed}`}>
            <input type="range" min={10} max={250} step={1} value={speed} onChange={(e) => setSpeed(Number(e.target.value))} className="slider-fluid w-full accent-amber-400" />
          </PopRow>
          <PopRow label="Width" value={`${settings.width}%`}>
            <input type="range" min={50} max={100} step={1} value={settings.width} onChange={(e) => onSettings({ ...settings, width: Number(e.target.value) })} className="slider-fluid w-full accent-amber-400" />
          </PopRow>
          <div className="flex gap-2 pt-1">
            {(["black", "white", "sepia"] as const).map((b) => (
              <button key={b} onClick={() => onSettings({ ...settings, bg: b })}
                className={`flex-1 rounded-lg px-3 py-2 text-xs font-semibold border ${settings.bg === b ? "border-amber-400 text-amber-300" : "border-white/15 text-neutral-300"}`}>
                {b === "black" ? "Dark" : b === "white" ? "Light" : "Sepia"}
              </button>
            ))}
          </div>
        </Popover>
      )}
      {panel === "size" && (
        <Popover onClose={() => setPanel(null)}>
          <PopRow label="Font size" value={`${fontSize}px`}>
            <input type="range" min={24} max={140} step={1} value={fontSize} onChange={(e) => setFontSize(Number(e.target.value))} className="slider-fluid w-full accent-amber-400" />
          </PopRow>
        </Popover>
      )}
      {panel === "more" && (
        <Popover onClose={() => setPanel(null)}>
          <div className={videoMode ? "grid grid-cols-1 gap-2" : "grid grid-cols-2 gap-2"}>
            <button onClick={() => { reset(); setPanel(null); }} className="rounded-lg border border-white/15 px-3 py-2 text-sm">↺ Reset</button>
            {!videoMode && (
              <button onClick={toggleMirror} className={`rounded-lg border px-3 py-2 text-sm ${mirrorV ? "border-amber-400 text-amber-300" : "border-white/15"}`}>Flip ↕ (beam-splitter rig)</button>
            )}
          </div>
          {videoMode && (
            <div className="mt-3">
              <div className="mb-1 text-xs text-neutral-300">Recording quality</div>
              <div className="flex gap-2">
                {(["720p", "1080p", "4k"] as const).map((q) => (
                  <button key={q} disabled={recording} onClick={() => setQuality(q)}
                    className={`flex-1 rounded-lg border px-3 py-2 text-xs font-semibold disabled:opacity-40 ${quality === q ? "border-amber-400 text-amber-300" : "border-white/15 text-neutral-300"}`}>
                    {q === "4k" ? "4K (try)" : q}
                  </button>
                ))}
              </div>
              <p className="mt-2 text-[11px] text-neutral-400">4K is attempted but iPhone Safari may fall back to 1080p.</p>
            </div>
          )}
          {/* Reading assist toggles */}
          <div className="mt-3 border-t border-white/10 pt-3">
            <div className="mb-2 text-xs font-semibold text-neutral-300">Reading assist</div>
            <div className="grid grid-cols-1 gap-1.5">
              <button
                onClick={() => setReadingHighlight((v) => !v)}
                className={`flex items-center gap-2 rounded-lg border px-3 py-2 text-left text-sm ${readingHighlight ? "border-amber-400 text-amber-300" : "border-white/15 text-neutral-200"}`}
              >
                <AudioLines className="h-4 w-4 shrink-0" />
                <span className="flex-1">Reading highlight</span>
                <span className="text-[11px] opacity-70">{readingHighlight ? "On" : "Off"}</span>
              </button>
              <button
                onClick={() => setChunking((v) => !v)}
                className={`flex items-center gap-2 rounded-lg border px-3 py-2 text-left text-sm ${chunking ? "border-amber-400 text-amber-300" : "border-white/15 text-neutral-200"}`}
              >
                <AlignJustify className="h-4 w-4 shrink-0" />
                <span className="flex-1">Chunk phrases</span>
                <span className="text-[11px] opacity-70">{chunking ? "On" : "Off"}</span>
              </button>
              <button
                onClick={() => setPauses((v) => !v)}
                className={`flex items-center gap-2 rounded-lg border px-3 py-2 text-left text-sm ${pauses ? "border-amber-400 text-amber-300" : "border-white/15 text-neutral-200"}`}
              >
                <Timer className="h-4 w-4 shrink-0" />
                <span className="flex-1">Slow at punctuation</span>
                <span className="text-[11px] opacity-70">{pauses ? "On" : "Off"}</span>
              </button>
              <button
                onClick={() => setVoiceFollow((v) => !v)}
                disabled={!vfSupported}
                className={`flex items-center gap-2 rounded-lg border px-3 py-2 text-left text-sm disabled:opacity-40 ${voiceFollow ? "border-amber-400 text-amber-300" : "border-white/15 text-neutral-200"}`}
              >
                <AudioLines className="h-4 w-4 shrink-0" />
                <span className="flex-1">Voice-follow highlight</span>
                <span className="text-[11px] opacity-70">
                  {!vfSupported ? "Unsupported" : voiceFollow ? (vfStatus === "listening" ? "Listening" : vfStatus === "error" ? "Blocked" : "On") : "Off"}
                </span>
              </button>
            </div>
            {voiceFollow && vfSupported && (
              <p className="mt-2 text-[11px] text-neutral-400">
                Speak naturally — the visible script guides recognition and advances smoothly with you.
              </p>
            )}
          </div>
          <p className="mt-2 text-[11px] text-neutral-400">Tap the script to play / pause. Bluetooth remotes (Desview, AirTurn) work too.</p>

        </Popover>
      )}

      {/* REC pill — top-left when recording */}
      {videoMode && recording && (
        <div
          className="absolute z-40 flex items-center gap-2 rounded-full bg-red-600/90 px-3 py-1.5 text-sm font-bold text-white backdrop-blur-sm"
          style={{
            top: "calc(env(safe-area-inset-top, 0px) + 0.6rem)",
            left: "calc(env(safe-area-inset-left, 0px) + 0.6rem)",
            transform: mirrorV ? "scaleY(-1)" : undefined,
          }}
        >
          <span className="h-2.5 w-2.5 animate-pulse rounded-full bg-white" />
          REC {fmtDuration(elapsedMs)}
        </div>
      )}

      {/* Storage trouble — a silently failed write is how a take ends short.
          The text states the real cause; it never claims the phone is full. */}
      {videoMode && writeWarn && (
        <button
          type="button"
          onClick={() => { setWriteWarn(false); setWriteWarnMsg(""); }}
          className="absolute z-40 max-w-[70vw] rounded-xl bg-red-600/90 px-3 py-2 text-left text-xs font-bold leading-snug text-white"
          style={{
            top: "calc(env(safe-area-inset-top, 0px) + 3.2rem)",
            left: "calc(env(safe-area-inset-left, 0px) + 0.6rem)",
            transform: mirrorV ? "scaleY(-1)" : undefined,
          }}
        >
          {writeWarnMsg || "A piece of this take could not be written. Recording continues, but stop soon and check it."}
          {freeSpaceLabel ? ` (${freeSpaceLabel})` : ""}
        </button>
      )}

      {/* Saving-to-phone progress after Stop. The take is not in the library
          until this completes, so it gets a real bar, not a spinner. */}
      {videoMode && finalizing && (
        <div
          className="absolute inset-x-0 z-50 mx-auto w-[min(22rem,86vw)] rounded-2xl bg-black/85 px-4 py-3 text-center backdrop-blur-sm"
          style={{
            bottom: "calc(env(safe-area-inset-bottom, 0px) + 5.5rem)",
            transform: mirrorV ? "scaleY(-1)" : undefined,
          }}
        >
          <div className="text-sm font-black text-white">
            {finalizing.phase === "error" ? "Saving had trouble" : finalizing.phase === "assembling" ? "Finishing the video…" : "Saving to your phone…"}
          </div>
          <div className="mt-2 h-2 w-full overflow-hidden rounded-full bg-white/15">
            <div
              className={`h-full rounded-full transition-[width] duration-150 ${finalizing.phase === "error" ? "bg-red-400" : "bg-amber-400"}`}
              style={{
                width: `${finalizing.phase === "assembling" ? 97 : Math.min(95, Math.round((finalizing.done / finalizing.total) * 95))}%`,
              }}
            />
          </div>
          <div className="mt-1.5 text-xs text-neutral-300">
            {finalizing.phase === "error"
              ? "Some of this take may still be recoverable — open All videos and tap Repair."
              : `${Math.min(finalizing.done, finalizing.total)} of ${finalizing.total} seconds stored — keep this screen open`}
          </div>
          {finalizing.phase === "error" && (
            <button onClick={(e) => { e.stopPropagation(); setFinalizing(null); }}
              className="mt-2 rounded-full bg-white/10 px-4 py-1.5 text-xs text-neutral-200 active:scale-95">Close</button>
          )}
        </div>
      )}

      {/* Clips chip — top-left when NOT recording */}
      {videoMode && !recording && (
        <button onClick={(e) => { e.stopPropagation(); setClipsOpen(true); }}
          className="absolute z-40 inline-flex items-center gap-1.5 rounded-full bg-black/60 px-3 py-1.5 text-sm font-semibold text-neutral-100 backdrop-blur-sm active:scale-95"
          style={{
            top: "calc(env(safe-area-inset-top, 0px) + 0.6rem)",
            left: "calc(env(safe-area-inset-left, 0px) + 0.6rem)",
            transform: mirrorV ? "scaleY(-1)" : undefined,
          }}
          aria-label="Clips"
        >
          <Film className="h-4 w-4 text-amber-300" /> Clips {clips.length > 0 && <span className="text-amber-300">({clips.length})</span>}
        </button>
      )}

      {/* Mic pill — shows the active audio input; highlights when external (USB / DJI Mic 2 / wireless). */}
      {videoMode && camReady && controlsVisible && (
        <div
          className={`absolute z-40 inline-flex max-w-[60vw] items-center gap-1.5 rounded-full px-3 py-1.5 text-xs font-semibold backdrop-blur-sm ${
            !micLive ? "bg-red-500/90 text-white" : micIsExternal ? "bg-emerald-500/90 text-black" : "bg-black/60 text-neutral-100"
          }`}
          style={{
            top: "calc(env(safe-area-inset-top, 0px) + 0.6rem)",
            left: "50%",
            transform: `translateX(-50%)${mirrorV ? " scaleY(-1)" : ""}`,
          }}
          aria-label={micLive ? `Active microphone: ${activeMicLabel || "Built-in mic"}` : "No microphone connected"}
        >
          <Mic className="h-3.5 w-3.5 shrink-0" />
          <span className="truncate">
            {!micLive ? "No mic — connecting" : micIsExternal ? activeMicLabel : "Built-in mic"}
          </span>
        </div>
      )}



      {/* % remaining — always visible */}
      <div
        ref={remainingRef}
        className="absolute z-40 rounded-full bg-black/60 px-3 py-1.5 text-base font-semibold text-amber-300"
        style={{
          top: "calc(env(safe-area-inset-top, 0px) + 0.6rem)",
          right: "calc(env(safe-area-inset-right, 0px) + 0.6rem)",
          fontFamily: "var(--font-sans)",
          transform: mirrorV ? "scaleY(-1)" : undefined,
        }}
      >
        {remaining}% left
      </div>

      {/* Clips sheet */}
      {videoMode && clipsOpen && (
        <ClipsSheet
          clips={clips}
          scriptTitles={{ [script.id]: script.title || "Untitled script" }}
          onClose={() => setClipsOpen(false)}
          onDelete={async (id) => { await deleteClip(id); setClips((cs) => cs.filter((c) => c.id !== id)); }}
          onDeleteAll={async () => { await deleteAllForScript(script.id); setClips([]); }}
          onExport={exportClip}
          onReplace={(clip) => setClips((cs) => cs.some((c) => c.id === clip.id) ? cs.map((c) => c.id === clip.id ? clip : c) : [...cs, clip])}
          onRescue={async () => { await rescueAll(script.id); setClips(await listClipMeta(script.id)); }}

        />
      )}

      {saveJob && (
        <SaveOverlay
          job={saveJob}
          onClose={() => setSaveJob(null)}
          onFallback={() => { if (saveJob.file) saveJob.download(saveJob.file); }}
        />
      )}



      {/* Tiny reveal pill — only thing on screen when controls are hidden */}
      {!controlsVisible && (
        <button
          onClick={(e) => { e.stopPropagation(); setControlsVisible(true); }}
          className="absolute left-1/2 z-40 -translate-x-1/2 rounded-full bg-black/40 px-3 py-1 text-[10px] font-semibold text-white/60 backdrop-blur-sm active:scale-90"
          style={{ top: "calc(env(safe-area-inset-top, 0px) + 0.6rem)" }}
          aria-label="Show controls"
        >
          •••
        </button>
      )}

      {controlsVisible && (
        <>
          {/* Thin progress line above toolbar */}
          <div
            className="absolute left-0 right-0 z-20 h-[2px] bg-white/10"
            style={{ bottom: "calc(64px + env(safe-area-inset-bottom, 0px))" }}
          >
            <div ref={progressBarRef} className="h-full bg-amber-400" style={{ width: `${progress * 100}%`, willChange: playing ? "width" : undefined }} />
          </div>

          {/* Bottom toolbar */}
          <div
            className="absolute bottom-0 left-0 right-0 z-30 bg-black/85 backdrop-blur-md"
            style={{
              paddingBottom: "max(env(safe-area-inset-bottom, 0px), 0px)",
              paddingLeft: "env(safe-area-inset-left, 0px)",
              paddingRight: "env(safe-area-inset-right, 0px)",
            }}
            onClick={(e) => e.stopPropagation()}
          >
            <div className="flex items-center justify-between gap-1 px-2 py-2 sm:px-3">
              <button onClick={onExit} className={iconBtn} aria-label="Back">
                <ChevronLeft className="h-6 w-6 text-sky-400" strokeWidth={2.5} />
              </button>
              {!videoMode && (
                <button onClick={toggleMirror} className={iconBtn} aria-label="Mirror vertically for beam splitter">
                  <FlipVertical2 className={`h-6 w-6 ${mirrorV ? "text-amber-300" : ""}`} />
                </button>
              )}
              <button onClick={togglePlay} className={iconBtn} aria-label="Play / Pause">
                {playing
                  ? <Pause className="h-7 w-7 text-sky-400" fill="currentColor" />
                  : <Play className="h-7 w-7 text-sky-400" fill="currentColor" />}
              </button>
              {videoMode && (
                <button
                  onClick={recording ? stopRecording : startRecording}
                  disabled={videoMode && !camReady && !recording}
                  className={`${iconBtn} ${recording ? "bg-red-600 text-white" : "bg-red-500/90 text-white"} disabled:opacity-40`}
                  aria-label={recording ? "Stop recording" : "Start recording"}
                >
                  {recording ? <Square className="h-5 w-5" fill="currentColor" /> : <Circle className="h-6 w-6" fill="currentColor" />}
                </button>
              )}
              <button onClick={() => setPanel(panel === "settings" ? null : "settings")} className={iconBtn} aria-label="Settings">
                <SlidersHorizontal className="h-6 w-6" />
              </button>
              <button onClick={() => setPanel(panel === "size" ? null : "size")} className={iconBtn} aria-label="Text size">
                <Type className="h-6 w-6" />
              </button>
              <button onClick={() => setPanel(panel === "more" ? null : "more")} className={`${iconBtn} bg-sky-500/90 text-white`} aria-label="More">
                <MoreHorizontal className="h-5 w-5" />
              </button>
            </div>
          </div>
        </>
      )}
    </div>
  );
}


function Popover({ children, onClose }: { children: React.ReactNode; onClose: () => void }) {
  return (
    <>
      <div className="absolute inset-0 z-30" onClick={onClose} />
      <div
        className="absolute left-1/2 z-40 w-[min(92vw,420px)] -translate-x-1/2 rounded-2xl border border-white/10 bg-black/90 p-3 text-neutral-100 backdrop-blur-md"
        style={{ bottom: "calc(72px + env(safe-area-inset-bottom, 0px))" }}
      >
        {children}
      </div>
    </>
  );
}

function PopRow({ label, value, children }: { label: string; value: string; children: React.ReactNode }) {
  return (
    <div className="mb-3 last:mb-0">
      <div className="mb-1 flex justify-between text-xs">
        <span className="text-neutral-300">{label}</span>
        <span className="font-mono text-amber-300">{value}</span>
      </div>
      {children}
    </div>
  );
}

function ClipsSheet({
  clips, scriptTitles, onClose, onDelete, onDeleteAll, onExport, onReplace, onRescue,
}: {
  clips: ClipMeta[];
  scriptTitles: Record<string, string>;
  onClose: () => void;
  onDelete: (id: string) => void | Promise<void>;
  onDeleteAll: () => void | Promise<void>;
  onExport: (clip: ClipMeta) => void | Promise<void>;
  onReplace: (clip: ClipRecord) => void;
  onRescue: () => void | Promise<void>;
}) {
  const [busy, setBusy] = useState<string | null>(null);
  const [note, setNote] = useState<string | null>(null);
  const [broken, setBroken] = useState<Set<string>>(new Set());
  const [playingClip, setPlayingClip] = useState<ClipRecord | null>(null);
  const [playUrl, setPlayUrl] = useState<string | null>(null);
  const videoElRef = useRef<HTMLVideoElement | null>(null);
  const openClip = useCallback(async (meta: ClipMeta) => {
    setBusy(meta.id);
    try {
      const c = await getClip(meta.id);
      if (!c) { setNote("This recording is missing from phone storage."); return; }
      setPlayUrl((prev) => { if (prev) URL.revokeObjectURL(prev); return URL.createObjectURL(c.blob); });
      setPlayingClip(c);
    } finally {
      setBusy(null);
    }
  }, []);
  const closePlayer = useCallback(() => {
    setPlayUrl((prev) => { if (prev) URL.revokeObjectURL(prev); return null; });
    setPlayingClip(null);
  }, []);
  useEffect(() => () => { if (playUrl) URL.revokeObjectURL(playUrl); }, [playUrl]);

  // What the app is holding on this phone, refreshed whenever the list changes.
  const [space, setSpace] = useState<{ clipBytes: number; usage: number; quota: number } | null>(null);
  const refreshSpace = useCallback(async () => {
    try { setSpace(await storageUsage()); } catch { setSpace(null); }
  }, []);
  useEffect(() => { refreshSpace(); }, [refreshSpace, clips.length]);

  // Rebuild an unplayable recording from the raw data still in storage.
  const doRepair = useCallback(async (c: ClipMeta) => {
    setBusy(c.id);
    setNote("Rebuilding recording — this can take a minute for long takes…");
    try {
      const { clip, report } = await repairClip(c.id);
      if (clip) {
        onReplace(clip);
        setBroken((b) => { const n = new Set(b); report.playable ? n.delete(c.id) : n.add(c.id); return n; });
        setNote(report.playable
          ? `Restored ${fmtDuration(clip.durationMs)} · ${fmtSize(clip.sizeBytes)}. Tap it to play, then Save to Photos to keep it.`
          : `Recovered ${fmtSize(clip.sizeBytes)} of footage but this device still can't decode it. Use Save to Photos to get the file off the phone.`);
        if (report.playable) {
          setPlayUrl((prev) => { if (prev) URL.revokeObjectURL(prev); return URL.createObjectURL(clip.blob); });
          setPlayingClip(clip);
        }
      } else {
        setNote("No footage left in storage for this take.");
      }
    } catch {
      setNote("Repair failed. Try Save to Photos to export the raw file.");
    } finally {
      setBusy(null);
    }
  }, [onReplace]);

  // Rebuild a take to its full recoverable length (fixes takes that stop
  // short: the tail fragment was cut mid-write so players ignore the rest).
  const doRestore = useCallback(async (c: ClipMeta) => {
    setBusy(c.id);
    setNote("Restoring every recoverable second — long takes can take a minute…");
    try {
      const { clip, report } = await deepRestore(c.id);
      if (!clip) { setNote("No footage left in storage for this take."); return; }
      onReplace(clip);
      setBroken((b) => { const n = new Set(b); report.playable ? n.delete(c.id) : n.add(c.id); return n; });
      if (report.playable) {
        const gained = report.durationMs - report.previousDurationMs;
        setNote(gained > 2000
          ? `Restored to ${fmtDuration(report.durationMs)} (+${fmtDuration(gained)}) · ${fmtSize(report.bytes)}. Ready to save.`
          : `Full length confirmed: ${fmtDuration(report.durationMs)} · ${fmtSize(report.bytes)}. Ready to save.`);
        setPlayUrl((prev) => { if (prev) URL.revokeObjectURL(prev); return URL.createObjectURL(clip.blob); });
        setPlayingClip(clip);
      } else {
        setNote(`Kept all ${fmtSize(report.bytes)} of footage, but this device can't decode it. Save it to Files and it can still be repaired on a computer.`);
      }
    } catch {
      setNote("Restore failed. Try Save to Photos to export the raw file.");
    } finally {
      setBusy(null);
    }
  }, [onReplace]);

  return (
    <>
      <div className="absolute inset-0 z-40 bg-black/70 backdrop-blur-sm" onClick={onClose} />
      <div className="absolute inset-x-0 bottom-0 z-50 max-h-[85vh] overflow-hidden rounded-t-3xl border-t border-white/10 bg-neutral-950 text-neutral-100"
        onClick={(e) => e.stopPropagation()} style={{ paddingBottom: "max(env(safe-area-inset-bottom, 0px), 0px)", paddingLeft: "env(safe-area-inset-left, 0px)", paddingRight: "env(safe-area-inset-right, 0px)" }}>
        <div className="flex items-center justify-between px-4 pt-3">
          <div className="text-base font-bold">All videos <span className="text-neutral-400 font-normal">({clips.length})</span></div>
          <button onClick={onClose} className="grid h-9 w-9 place-items-center rounded-full text-neutral-400 hover:text-white" aria-label="Close">
            <X className="h-5 w-5" />
          </button>
        </div>
        <div className="max-h-[55vh] overflow-y-auto px-3 py-2">
          {clips.length === 0 ? (
            <div className="px-3 py-10 text-center text-sm text-neutral-400">No clips yet. Tap the red record button to start.</div>
          ) : (
            <ul className="space-y-2">
              {clips.map((c) => (
                <li key={c.id} className="flex items-center gap-3 rounded-xl border border-white/10 bg-white/[0.03] p-2">
                  <button onClick={() => openClip(c)} className="flex-1 min-w-0 text-left active:opacity-70">
                    <div className="text-sm font-semibold truncate flex items-center gap-1.5">
                      <Play className="h-3.5 w-3.5 text-amber-300" fill="currentColor" /> {scriptTitles[c.scriptId] || "Deleted script"}
                      {broken.has(c.id) && <span className="rounded-full bg-red-500/15 px-2 py-0.5 text-[10px] font-bold text-red-300">Needs repair</span>}
                    </div>
                    <div className="text-[11px] text-neutral-400">
                      {new Date(c.createdAt).toLocaleString([], { dateStyle: "medium", timeStyle: "short" })} · {fmtDuration(c.durationMs)} · {fmtSize(c.sizeBytes)} · {c.width && c.height ? `${c.width}×${c.height}` : c.mimeType.split(";")[0]}
                    </div>
                  </button>
                  {broken.has(c.id) ? (
                    <button onClick={() => doRepair(c)} disabled={busy === c.id} className="rounded-full border border-amber-400/60 px-3 py-1.5 text-xs font-bold text-amber-300 disabled:opacity-50">
                      {busy === c.id ? "Repairing…" : "Repair"}
                    </button>
                  ) : (
                    <button onClick={() => doRestore(c)} disabled={busy === c.id} className="rounded-full border border-emerald-400/50 px-3 py-1.5 text-xs font-bold text-emerald-300 disabled:opacity-50">
                      {busy === c.id ? "Restoring…" : "Restore full"}
                    </button>
                  )}
                   <button onClick={() => onExport(c)} className="grid h-9 w-9 place-items-center rounded-full text-amber-300 hover:bg-white/5" aria-label="Save this clip">
                    <Download className="h-4 w-4" />
                  </button>
                  <button onClick={() => { if (confirm("Delete this clip?")) onDelete(c.id); }} className="grid h-9 w-9 place-items-center rounded-full text-red-400 hover:bg-white/5" aria-label="Delete">
                    <Trash2 className="h-4 w-4" />
                  </button>
                </li>
              ))}
            </ul>
          )}
        </div>
        {note && <div className="px-4 pb-2 text-[11px] leading-snug text-amber-200/90">{note}</div>}
        <div className="space-y-2 border-t border-white/10 px-3 py-2">
          {space && (
            <div className="rounded-xl border border-white/10 bg-white/[0.03] p-3">
              <div className="flex items-baseline justify-between text-xs">
                <span className="font-semibold text-neutral-200">Videos on this phone</span>
                <span className="text-neutral-400">
                  {fmtSize(space.clipBytes)} used{space.quota ? ` · ${fmtSize(Math.max(0, space.quota - space.usage))} free` : ""}
                </span>
              </div>
              <div className="mt-2 h-1.5 overflow-hidden rounded-full bg-white/10">
                <div className="h-full rounded-full bg-amber-400" style={{ width: `${space.quota ? Math.min(100, Math.round((space.usage / space.quota) * 100)) : 0}%` }} />
              </div>
              <div className="mt-2 flex gap-2">
                <button
                  onClick={async () => {
                    setBusy("space");
                    setNote("Clearing leftover pieces…");
                    try { const n = await purgeOrphanChunks(); setNote(n > 0 ? "Leftover pieces cleared." : "Nothing left over to clear."); }
                    finally { setBusy(null); refreshSpace(); }
                  }}
                  disabled={busy === "space"}
                  className="flex-1 rounded-full border border-white/15 px-3 py-2 text-xs text-neutral-200 disabled:opacity-50"
                >
                  {busy === "space" ? "Clearing…" : "Free up space"}
                </button>
                <button
                  onClick={async () => {
                    if (!confirm("Delete every video stored in the app? This cannot be undone.")) return;
                    setBusy("space");
                    try { await clearAllStorage(); await onDeleteAll(); setNote("All videos deleted."); }
                    finally { setBusy(null); refreshSpace(); }
                  }}
                  disabled={busy === "space"}
                  className="flex-1 rounded-full border border-red-400/50 px-3 py-2 text-xs font-semibold text-red-300 disabled:opacity-50"
                >
                  Delete everything
                </button>
              </div>
            </div>
          )}
          <button
            onClick={async () => { setBusy("all"); setNote("Scanning storage for unfinished or damaged recordings…"); try { await onRescue(); setNote("Scan finished. Anything recoverable is now in the list."); } finally { setBusy(null); } }}
            disabled={busy === "all"}
            className="w-full rounded-full border border-white/15 px-4 py-2 text-sm text-neutral-200 disabled:opacity-50"
          >
            {busy === "all" ? "Scanning…" : "Recover missing / damaged recordings"}
          </button>
        </div>
        {clips.length > 0 && (
          <div className="flex gap-2 border-t border-white/10 p-3">
            <button onClick={() => { if (confirm("Delete all clips for this script?")) onDeleteAll(); }} className="rounded-full border border-white/15 px-4 py-2 text-sm text-neutral-300">
              Delete all
            </button>
            <div className="flex-1 text-right text-xs text-neutral-400">Use the download button beside a video to save it.</div>
          </div>
        )}
      </div>


      {playingClip && playUrl && (
        <div
          className="fixed inset-0 z-[60] bg-black"
          onClick={(e) => e.stopPropagation()}
        >
          {/* Video fills the whole screen and is centered by object-contain.
              Try to play as soon as it can; if the browser blocks it the
              native controls remain visible so the user can tap play. */}
          <video
            key={playingClip.id}
            ref={videoElRef}
            src={playUrl}
            controls
            playsInline
            preload="auto"
            onCanPlay={() => { videoElRef.current?.play().catch(() => {}); }}
            onError={() => setBroken((b) => new Set(b).add(playingClip.id))}
            className="absolute inset-0 h-full w-full object-contain"
          />

          {/* Floating close button — top-right, safe-area aware */}
          <button
            onClick={closePlayer}
            className="absolute z-10 grid h-10 w-10 place-items-center rounded-full bg-black/60 text-white backdrop-blur-sm active:scale-90"
            style={{
              top: "calc(env(safe-area-inset-top, 0px) + 0.5rem)",
              right: "calc(env(safe-area-inset-right, 0px) + 0.5rem)",
            }}
            aria-label="Close player"
          >
            <X className="h-5 w-5" />
          </button>

          {/* Floating take label — top-left */}
          <div
            className="absolute z-10 rounded-full bg-black/60 px-3 py-1.5 text-xs font-semibold text-neutral-100 backdrop-blur-sm max-w-[60vw] truncate"
            style={{
              top: "calc(env(safe-area-inset-top, 0px) + 0.5rem)",
              left: "calc(env(safe-area-inset-left, 0px) + 0.5rem)",
            }}
          >
            {scriptTitles[playingClip.scriptId] || "Deleted script"} · {new Date(playingClip.createdAt).toLocaleString([], { dateStyle: "medium", timeStyle: "short" })}
          </div>

          {/* Floating action row — bottom, above native video controls */}
          <div
            className="absolute z-10 left-0 right-0 flex gap-2 px-3"
            style={{
              bottom: "calc(env(safe-area-inset-bottom, 0px) + 3.75rem)",
              paddingLeft: "calc(env(safe-area-inset-left, 0px) + 0.75rem)",
              paddingRight: "calc(env(safe-area-inset-right, 0px) + 0.75rem)",
            }}
          >
             <button onClick={() => onExport(playingClip)} className="inline-flex items-center gap-2 rounded-full bg-amber-400 px-6 py-3 text-base font-black text-black shadow-lg active:scale-95">
               <Download className="h-5 w-5" /> Save video
            </button>
            {broken.has(playingClip.id) && (
              <button onClick={() => doRepair(playingClip)} disabled={busy === playingClip.id} className="inline-flex items-center gap-1.5 rounded-full border border-amber-400/70 bg-black/70 px-4 py-2 text-sm font-bold text-amber-300 backdrop-blur-sm disabled:opacity-50">
                {busy === playingClip.id ? "Repairing…" : "Repair this take"}
              </button>
            )}
            <div className="flex-1" />
            <button
              onClick={() => { const c = playingClip; if (confirm("Delete this clip?")) { onDelete(c.id); closePlayer(); } }}
              className="inline-flex items-center gap-1.5 rounded-full bg-black/70 border border-red-400/50 px-4 py-2 text-sm text-red-300 backdrop-blur-sm"
            >
              <Trash2 className="h-4 w-4" /> Delete
            </button>
          </div>
        </div>
      )}
    </>
  );
}
