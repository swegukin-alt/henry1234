// Voice-follow: listens via the Web Speech API (webkitSpeechRecognition on
// iOS Safari) and advances an anchor word index as it recognizes what the
// user just said. Highlight-only — never touches scroll speed.

import { useEffect, useRef, useState } from "react";
import { normalizeWord } from "./chunk-script";

export type VoiceFollowStatus = "off" | "starting" | "listening" | "error";

type Word = { norm: string; wordIndex: number };

// Web Speech API is unprefixed on modern browsers, prefixed on Safari.
function getRecognitionCtor(): any {
  if (typeof window === "undefined") return null;
  return (window as any).SpeechRecognition || (window as any).webkitSpeechRecognition || null;
}

export function isVoiceFollowSupported(): boolean {
  return getRecognitionCtor() !== null;
}

export function useVoiceFollow(opts: {
  enabled: boolean;
  words: Word[];
  lang: string; // "ko-KR" | "en-US"
}): { anchorWordIndex: number; status: VoiceFollowStatus } {
  const { enabled, words, lang } = opts;
  const [anchorWordIndex, setAnchorWordIndex] = useState<number>(-1);
  const [status, setStatus] = useState<VoiceFollowStatus>("off");
  const anchorRef = useRef<number>(-1);
  const wordsRef = useRef(words);
  const recRef = useRef<any>(null);
  const wantOnRef = useRef(false);
  const restartTimerRef = useRef<number | null>(null);
  const lastMatchAtRef = useRef<number>(0);
  const fadeTimerRef = useRef<number | null>(null);

  useEffect(() => { wordsRef.current = words; }, [words]);

  // Reset anchor when the script changes (word list identity)
  useEffect(() => {
    anchorRef.current = -1;
    setAnchorWordIndex(-1);
  }, [words]);

  useEffect(() => {
    const Ctor = getRecognitionCtor();
    if (!Ctor) { setStatus("off"); return; }
    if (!enabled) {
      wantOnRef.current = false;
      try { recRef.current?.stop(); } catch {}
      recRef.current = null;
      setStatus("off");
      return;
    }

    wantOnRef.current = true;
    setStatus("starting");

    const clearFadeTimer = () => {
      if (fadeTimerRef.current) { window.clearTimeout(fadeTimerRef.current); fadeTimerRef.current = null; }
    };
    const scheduleFade = () => {
      clearFadeTimer();
      fadeTimerRef.current = window.setTimeout(() => {
        // If nothing matched for a while, gently release the highlight so it
        // doesn't sit on a stale word — recognition keeps running.
        if (Date.now() - lastMatchAtRef.current >= 3800) {
          anchorRef.current = -1;
          setAnchorWordIndex(-1);
        }
      }, 4000);
    };

    const advanceAnchor = (heard: string[]) => {
      const words = wordsRef.current;
      if (!words.length || heard.length === 0) return;
      const anchor = anchorRef.current;
      // Search window: from current anchor (or start) forward ~40 words.
      const from = Math.max(0, anchor);
      const to = Math.min(words.length, from + 60);
      // Take the last 1-4 heard words as the "current" transcript tail.
      const tail = heard.slice(-4).filter(Boolean);
      if (tail.length === 0) return;
      let bestIdx = -1;
      // Walk forward and prefer the LATEST word in the window that matches
      // any of the tail words. This naturally advances as the user reads on.
      for (let i = from; i < to; i++) {
        const wnorm = words[i].norm;
        if (!wnorm) continue;
        for (const t of tail) {
          if (!t) continue;
          if (wnorm === t || (t.length >= 3 && (wnorm.startsWith(t) || t.startsWith(wnorm)))) {
            bestIdx = i;
            break;
          }
        }
      }
      if (bestIdx < 0) return;
      // Never move backward more than 3 tokens (recognition often re-emits).
      if (bestIdx < anchor - 3) return;
      // Never leap forward absurdly (>25 tokens) on a single utterance.
      if (anchor >= 0 && bestIdx - anchor > 25) return;
      if (bestIdx === anchor) return;
      anchorRef.current = bestIdx;
      setAnchorWordIndex(bestIdx);
      lastMatchAtRef.current = Date.now();
      scheduleFade();
    };

    const startNew = () => {
      if (!wantOnRef.current) return;
      let rec: any;
      try { rec = new Ctor(); } catch { setStatus("error"); return; }
      rec.continuous = true;
      rec.interimResults = true;
      rec.lang = lang;
      rec.maxAlternatives = 1;
      rec.onstart = () => { setStatus("listening"); };
      rec.onresult = (e: any) => {
        // Collect only NEW result entries (from resultIndex onward), take the
        // most recent one — that's what the user is saying right now.
        try {
          const results = e.results;
          const idx = Math.max(0, results.length - 1);
          const alt = results[idx][0];
          const transcript: string = alt?.transcript || "";
          if (!transcript.trim()) return;
          const heard = transcript.trim().split(/\s+/).map(normalizeWord).filter(Boolean);
          advanceAnchor(heard);
        } catch {}
      };
      rec.onerror = (e: any) => {
        // "no-speech", "aborted", "audio-capture" — just restart quietly.
        // "not-allowed" / "service-not-allowed" mean the user blocked mic; stop.
        const err = e?.error;
        if (err === "not-allowed" || err === "service-not-allowed") {
          wantOnRef.current = false;
          setStatus("error");
          return;
        }
      };
      rec.onend = () => {
        recRef.current = null;
        // Safari cuts sessions every ~60s. Reconnect if still wanted.
        if (wantOnRef.current) {
          if (restartTimerRef.current) window.clearTimeout(restartTimerRef.current);
          restartTimerRef.current = window.setTimeout(startNew, 250);
        } else {
          setStatus("off");
        }
      };
      try { rec.start(); recRef.current = rec; }
      catch { setStatus("error"); }
    };

    startNew();

    return () => {
      wantOnRef.current = false;
      if (restartTimerRef.current) { window.clearTimeout(restartTimerRef.current); restartTimerRef.current = null; }
      clearFadeTimer();
      try { recRef.current?.stop(); } catch {}
      recRef.current = null;
      setStatus("off");
    };
  }, [enabled, lang]);

  return { anchorWordIndex, status };
}
