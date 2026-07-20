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
      // Search window: from just before the current anchor forward ~150 words
      // so recognition catch-up (which arrives seconds later) still lands ahead.
      const from = Math.max(0, anchor - 2);
      const to = Math.min(words.length, from + 150);
      // Use the last ~10 heard tokens as the recent transcript tail.
      const tail = heard.slice(-10).filter(Boolean);
      if (tail.length === 0) return;
      // For each script word in the window, score how many tail words match.
      // Prefer the FURTHEST-FORWARD strong match — that tracks the reader's
      // mouth even when recognition lags a beat behind.
      let bestIdx = -1;
      let bestScore = 0;
      for (let i = from; i < to; i++) {
        const wnorm = words[i].norm;
        if (!wnorm) continue;
        let score = 0;
        for (const t of tail) {
          if (!t) continue;
          if (wnorm === t) { score += 2; continue; }
          if (t.length >= 3 && wnorm.length >= 3 && (wnorm.startsWith(t) || t.startsWith(wnorm))) {
            score += 1;
          }
        }
        if (score >= 1 && (score > bestScore || i > bestIdx)) {
          bestIdx = i;
          bestScore = score;
        }
      }
      if (bestIdx < 0) return;
      // Never move backward more than 2 tokens (recognition often re-emits).
      if (bestIdx < anchor - 2) return;
      // Never leap forward absurdly on a single utterance.
      if (anchor >= 0 && bestIdx - anchor > 50) return;
      if (bestIdx === anchor) return;
      anchorRef.current = bestIdx;
      setAnchorWordIndex(bestIdx);
      lastMatchAtRef.current = Date.now();
      scheduleFade();
    };

    // Ask for the mic explicitly — on iOS Safari, recognition sometimes
    // silently no-ops until mic permission has been granted at least once.
    const primeMic = async () => {
      try {
        const md = (navigator as any).mediaDevices;
        if (md?.getUserMedia) {
          const s = await md.getUserMedia({ audio: true });
          s.getTracks().forEach((t: MediaStreamTrack) => t.stop());
        }
      } catch { /* ignore — recognition.start() will surface not-allowed */ }
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
        // Collect every word from the in-flight utterance(s) — from
        // e.resultIndex to the end — so we always see the freshest speech.
        try {
          const results = e.results;
          const start = typeof e.resultIndex === "number" ? e.resultIndex : Math.max(0, results.length - 1);
          let combined = "";
          for (let i = start; i < results.length; i++) {
            const alt = results[i][0];
            if (alt?.transcript) combined += " " + alt.transcript;
          }
          if (!combined.trim()) return;
          const heard = combined.trim().split(/\s+/).map(normalizeWord).filter(Boolean);
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

    primeMic().then(() => { if (wantOnRef.current) startNew(); });

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
