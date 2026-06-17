import { createFileRoute } from "@tanstack/react-router";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { ChevronLeft, FlipHorizontal2, Play, Pause, SlidersHorizontal, Type, MoreHorizontal } from "lucide-react";

export const Route = createFileRoute("/")({
  head: () => ({
    meta: [
      { title: "Prompter — Teleprompter for iPhone" },
      { name: "description", content: "A clean, easy-to-read teleprompter with mirror mode, live progress, and Korean support." },
      { name: "theme-color", content: "#0a0a0a" },
      { name: "apple-mobile-web-app-capable", content: "yes" },
      { name: "apple-mobile-web-app-status-bar-style", content: "black-translucent" },
      { property: "og:title", content: "Prompter" },
      { property: "og:description", content: "A clean teleprompter that runs in your browser." },
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
};

const STORAGE_SCRIPTS = "prompter.scripts.v1";
const STORAGE_ACTIVE = "prompter.active.v1";
const STORAGE_SETTINGS = "prompter.settings.v1";

const DEFAULT_SETTINGS: Settings = {
  fontSize: 64,
  speed: 60,
  mirrorH: false,
  mirrorV: false,
  bg: "black",
  countdown: 3,
  width: 90,
};

const SAMPLE = `여러분, 안녕하세요. 오늘 이 자리에 함께해 주셔서 감사합니다.

Welcome. This is your teleprompter. Paste a script, tap Play, and the words will scroll smoothly.

화면 하단에 남은 분량이 퍼센트로 표시됩니다. Adjust speed and font size from the controls. Tap the screen to pause.`;

function uid() {
  return Math.random().toString(36).slice(2, 10);
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
  const [mode, setMode] = useState<"library" | "edit" | "play">("library");
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
  const deleteScript = (id: string) => {
    setScripts((a) => a.filter((s) => s.id !== id));
    if (activeId === id) setActiveId(null);
  };

  if (!hydrated) return <div className="min-h-screen bg-[#0a0a0a]" />;

  if (mode === "play" && active) {
    return (
      <Prompter
        script={active}
        settings={settings}
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
        />
      ) : (
        <Editor
          script={active}
          settings={settings}
          onChange={updateActive}
          onSettings={setSettings}
          onBack={() => setMode("library")}
          onPlay={() => {
            // Must run synchronously inside the user gesture for iOS to honor it.
            const el: any = document.documentElement;
            const req = el.requestFullscreen || el.webkitRequestFullscreen || el.webkitEnterFullscreen;
            try { req?.call(el).catch?.(() => {}); } catch {}
            setMode("play");
          }}
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
  scripts, activeId, onSelect, onCreate, onDelete,
}: {
  scripts: Script[]; activeId: string | null;
  onSelect: (id: string) => void; onCreate: () => void; onDelete: (id: string) => void;
}) {
  return (
    <div>
      <header className="flex items-center justify-between py-4">
        <div>
          <h1 className="text-3xl font-black tracking-tight">Prompter</h1>
          <p className="text-sm text-neutral-400">Your scripts, saved on this device.</p>
        </div>
        <button
          onClick={onCreate}
          className="rounded-full bg-amber-400 px-4 py-2 text-sm font-bold text-black active:scale-95 transition"
        >
          + New
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
            No scripts yet. Tap <span className="text-amber-400 font-bold">+ New</span> to start.
          </li>
        )}
      </ul>
    </div>
  );
}

function Editor({
  script, settings, onChange, onSettings, onBack, onPlay,
}: {
  script: Script;
  settings: Settings;
  onChange: (patch: Partial<Script>) => void;
  onSettings: (s: Settings) => void;
  onBack: () => void;
  onPlay: () => void;
}) {
  return (
    <div>
      <header className="flex items-center justify-between py-3">
        <button onClick={onBack} className="text-sm text-neutral-400 hover:text-white">‹ Scripts</button>
        <button
          onClick={onPlay}
          disabled={!script.body.trim()}
          className="rounded-full bg-amber-400 px-5 py-2 text-sm font-bold text-black disabled:opacity-40 active:scale-95 transition"
        >
          ▶ Play
        </button>
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
        <Slider label="Font size" value={settings.fontSize} min={24} max={140} step={2} suffix="px"
          onChange={(v) => set({ fontSize: v })} />
        <Slider label="Scroll speed" value={settings.speed} min={10} max={250} step={5} suffix="px/s"
          onChange={(v) => set({ speed: v })} />
        <Slider label="Text width" value={settings.width} min={50} max={100} step={5} suffix="%"
          onChange={(v) => set({ width: v })} />
        <div className="flex flex-wrap gap-2 pt-1">
          <Toggle on={settings.mirrorH} onClick={() => set({ mirrorH: !settings.mirrorH })}>Mirror ↔</Toggle>
          <Toggle on={settings.mirrorV} onClick={() => set({ mirrorV: !settings.mirrorV })}>Mirror ↕</Toggle>
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
        className="mt-2 w-full accent-amber-400"
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
  script, settings, onExit, onSettings,
}: { script: Script; settings: Settings; onExit: () => void; onSettings: (s: Settings) => void }) {
  const scrollRef = useRef<HTMLDivElement>(null);
  const rafRef = useRef<number | null>(null);
  const lastTsRef = useRef<number>(0);
  const [playing, setPlaying] = useState(false);
  const [progress, setProgress] = useState(0); // 0..1
  const [isPortrait, setIsPortrait] = useState(false);
  const [speed, setSpeed] = useState(settings.speed);
  const [fontSize, setFontSize] = useState(settings.fontSize);
  // Beam-splitter teleprompter rig: horizontal flip so text reads correctly
  // through the angled glass.
  const [mirrorV, setMirrorV] = useState(false);
  const [mirrorH, setMirrorH] = useState(settings.mirrorH);
  const [panel, setPanel] = useState<null | "settings" | "size" | "more">(null);
  const [controlsVisible, setControlsVisible] = useState(true);

  // Persist live edits back to settings
  useEffect(() => {
    onSettings({ ...settings, speed, fontSize, mirrorH, mirrorV });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [speed, fontSize, mirrorH, mirrorV]);

  const bgClass = settings.bg === "white" ? "bg-white text-neutral-900"
    : settings.bg === "sepia" ? "bg-[#f5ecd7] text-[#2a1f0f]"
    : "bg-black text-neutral-50";

  const computeProgress = useCallback(() => {
    const el = scrollRef.current;
    if (!el) return 0;
    const max = el.scrollHeight - el.clientHeight;
    if (max <= 0) return 1;
    return Math.min(1, Math.max(0, el.scrollTop / max));
  }, []);

  const tick = useCallback((ts: number) => {
    const el = scrollRef.current;
    if (!el) return;
    if (!lastTsRef.current) lastTsRef.current = ts;
    const dt = (ts - lastTsRef.current) / 1000;
    lastTsRef.current = ts;
    el.scrollTop += speed * dt;
    const p = computeProgress();
    setProgress(p);
    if (p >= 1) { setPlaying(false); return; }
    rafRef.current = requestAnimationFrame(tick);
  }, [speed, computeProgress]);

  useEffect(() => {
    if (playing) {
      lastTsRef.current = 0;
      rafRef.current = requestAnimationFrame(tick);
    } else if (rafRef.current) {
      cancelAnimationFrame(rafRef.current);
      rafRef.current = null;
    }
    return () => { if (rafRef.current) cancelAnimationFrame(rafRef.current); };
  }, [playing, tick]);

  const togglePlay = () => {
    setPlaying((p) => {
      const next = !p;
      if (next) { setControlsVisible(false); setPanel(null); }
      return next;
    });
  };
  const reset = () => {
    setPlaying(false);
    if (scrollRef.current) scrollRef.current.scrollTop = 0;
    setProgress(0);
  };
  // Smooth nudge that does NOT stop playback. While playing, the rAF tick
  // mutates scrollTop every frame, so a CSS smooth-scroll target would be
  // overwritten immediately — we apply the offset directly instead.
  const nudge = useCallback((dir: 1 | -1) => {
    const el = scrollRef.current;
    if (!el) return;
    const step = dir * Math.max(60, el.clientHeight * 0.18);
    if (playing) {
      el.scrollTop += step;
    } else {
      try { el.scrollBy({ top: step, behavior: "smooth" }); }
      catch { el.scrollTop += step; }
    }
    setProgress(computeProgress());
  }, [computeProgress, playing]);

  // Bluetooth remote (Desview RM-S1/S2 etc.) keyboard mapping
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const tag = (e.target as HTMLElement)?.tagName;
      if (tag === "INPUT" || tag === "TEXTAREA") return;
      const k = e.key, code = e.code;

      // Escape / Home / font size
      if (k === "Escape" || code === "Escape") { e.preventDefault(); onExit(); return; }
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

  const onScroll = () => { if (!playing) setProgress(computeProgress()); };
  const remaining = Math.round((1 - progress) * 100);

  // Portrait detection for hint only (no auto-rotate)
  useEffect(() => {
    const mq = window.matchMedia("(orientation: portrait)");
    const update = () => setIsPortrait(mq.matches);
    update();
    mq.addEventListener?.("change", update);
    return () => { mq.removeEventListener?.("change", update); };
  }, []);

  const iconBtn = "grid h-11 w-11 place-items-center rounded-full text-neutral-300 active:scale-90 transition";

  return (
    <div className={`${bgClass} fixed inset-0 overflow-hidden select-none`} style={{ fontFamily: "var(--font-prompter)" }}>
      {/* Scrolling text — finger tap pauses and reveals controls */}
      <div
        ref={scrollRef}
        onScroll={onScroll}
        onClick={() => { setPlaying(false); setControlsVisible(true); }}
        className="absolute inset-0 overflow-y-auto overscroll-contain"
        style={{ WebkitOverflowScrolling: "touch" }}
      >
        <div className="mx-auto" style={{ width: `${settings.width}%`, transform: mirrorV ? "scaleY(-1)" : undefined }}>
          <div style={{ height: "20vh" }} />
          <div className="whitespace-pre-wrap font-bold leading-[1.4] tracking-tight" style={{ fontSize: `${fontSize}px`, transform: mirrorH ? "scaleX(-1)" : undefined }}>
            {script.body}
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
            <input type="range" min={10} max={250} step={5} value={speed} onChange={(e) => setSpeed(Number(e.target.value))} className="w-full accent-amber-400" />
          </PopRow>
          <PopRow label="Width" value={`${settings.width}%`}>
            <input type="range" min={50} max={100} step={5} value={settings.width} onChange={(e) => onSettings({ ...settings, width: Number(e.target.value) })} className="w-full accent-amber-400" />
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
            <input type="range" min={24} max={140} step={2} value={fontSize} onChange={(e) => setFontSize(Number(e.target.value))} className="w-full accent-amber-400" />
          </PopRow>
        </Popover>
      )}
      {panel === "more" && (
        <Popover onClose={() => setPanel(null)}>
          <div className="grid grid-cols-2 gap-2">
            <button onClick={() => { reset(); setPanel(null); }} className="rounded-lg border border-white/15 px-3 py-2 text-sm">↺ Reset</button>
            <button onClick={() => setMirrorH((v) => !v)} className={`rounded-lg border px-3 py-2 text-sm ${mirrorH ? "border-amber-400 text-amber-300" : "border-white/15"}`}>Flip ↔ (beam-splitter rig)</button>
          </div>
          <p className="mt-2 text-[11px] text-neutral-400">Tap the script to play / pause. Bluetooth remotes (Desview, AirTurn) work too.</p>
        </Popover>
      )}

      {/* Tiny reveal pill — only thing on screen when controls are hidden */}
      {!controlsVisible && (
        <button
          onClick={(e) => { e.stopPropagation(); setControlsVisible(true); }}
          className="absolute top-2 left-1/2 z-40 -translate-x-1/2 rounded-full bg-black/40 px-3 py-1 text-[10px] font-semibold text-white/60 backdrop-blur-sm active:scale-90"
          aria-label="Show controls"
        >
          •••
        </button>
      )}

      {controlsVisible && (
        <>
          {/* Thin progress line above toolbar */}
          <div className="absolute bottom-[64px] left-0 right-0 z-20 h-[2px] bg-white/10">
            <div className="h-full bg-amber-400" style={{ width: `${progress * 100}%` }} />
          </div>

          {/* Bottom toolbar */}
          <div
            className="absolute bottom-0 left-0 right-0 z-30 bg-black/85 backdrop-blur-md"
            style={{ paddingBottom: "max(env(safe-area-inset-bottom), 0px)" }}
            onClick={(e) => e.stopPropagation()}
          >
            <div className="flex items-center justify-between px-3 py-2">
              <button onClick={onExit} className={iconBtn} aria-label="Back">
                <ChevronLeft className="h-6 w-6 text-sky-400" strokeWidth={2.5} />
              </button>
              <button onClick={() => setMirrorH((v) => !v)} className={iconBtn} aria-label="Mirror for beam splitter">
                <FlipHorizontal2 className={`h-6 w-6 ${mirrorH ? "text-amber-300" : ""}`} />
              </button>
              <button onClick={togglePlay} className={iconBtn} aria-label="Play / Pause">
                {playing
                  ? <Pause className="h-7 w-7 text-sky-400" fill="currentColor" />
                  : <Play className="h-7 w-7 text-sky-400" fill="currentColor" />}
              </button>
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
            {/* % remaining — tucked subtly in the toolbar */}
            <div className="absolute -top-7 right-3 rounded-full bg-black/70 px-2.5 py-1 text-xs font-bold text-amber-300 tabular-nums">
              {remaining}% left
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
      <div className="absolute bottom-[72px] left-1/2 z-40 w-[min(92vw,420px)] -translate-x-1/2 rounded-2xl border border-white/10 bg-black/90 p-3 text-neutral-100 backdrop-blur-md">
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


