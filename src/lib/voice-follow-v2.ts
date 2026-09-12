import { useEffect, useRef, useState } from "react";
import { normalizeWord } from "./chunk-script";

export type VoiceFollowStatus = "off" | "starting" | "listening" | "error";
type Word = { norm: string; wordIndex: number };

export function isVoiceFollowSupported(): boolean {
  if (typeof window === "undefined") return false;
  const AC = (window as any).AudioContext || (window as any).webkitAudioContext;
  return !!(AC && navigator.mediaDevices?.getUserMedia);
}

function downsample(input: Float32Array, rate: number) {
  if (rate === 16000) return input;
  const ratio = rate / 16000;
  const out = new Float32Array(Math.floor(input.length / ratio));
  for (let i = 0; i < out.length; i++) {
    const start = Math.floor(i * ratio), end = Math.min(input.length, Math.floor((i + 1) * ratio));
    let sum = 0;
    for (let j = start; j < end; j++) sum += input[j];
    out[i] = sum / Math.max(1, end - start);
  }
  return out;
}

function wav(pcm: Float32Array) {
  const buffer = new ArrayBuffer(44 + pcm.length * 2), view = new DataView(buffer);
  const text = (at: number, value: string) => [...value].forEach((char, i) => view.setUint8(at + i, char.charCodeAt(0)));
  text(0, "RIFF"); view.setUint32(4, 36 + pcm.length * 2, true); text(8, "WAVE"); text(12, "fmt ");
  view.setUint32(16, 16, true); view.setUint16(20, 1, true); view.setUint16(22, 1, true);
  view.setUint32(24, 16000, true); view.setUint32(28, 32000, true); view.setUint16(32, 2, true);
  view.setUint16(34, 16, true); text(36, "data"); view.setUint32(40, pcm.length * 2, true);
  pcm.forEach((value, i) => {
    const sample = Math.max(-1, Math.min(1, value));
    view.setInt16(44 + i * 2, sample < 0 ? sample * 0x8000 : sample * 0x7fff, true);
  });
  return new Blob([buffer], { type: "audio/wav" });
}

function rms(input: Float32Array) {
  if (!input.length) return 0;
  let sum = 0;
  for (const value of input) sum += value * value;
  return Math.sqrt(sum / input.length);
}

function similarity(a: string, b: string) {
  if (!a || !b) return 0;
  if (a === b) return 1;
  if (a.includes(b) || b.includes(a)) return Math.min(a.length, b.length) / Math.max(a.length, b.length);
  const pairs = new Map<string, number>();
  for (let i = 0; i < a.length - 1; i++) pairs.set(a.slice(i, i + 2), (pairs.get(a.slice(i, i + 2)) || 0) + 1);
  let shared = 0;
  for (let i = 0; i < b.length - 1; i++) {
    const pair = b.slice(i, i + 2), count = pairs.get(pair) || 0;
    if (count) { shared++; pairs.set(pair, count - 1); }
  }
  return (2 * shared) / Math.max(1, a.length + b.length - 2);
}

export function useVoiceFollow({
  enabled,
  words,
  lang,
  visibleWordIndexRef,
  getExternalStream,
}: {
  enabled: boolean;
  words: Word[];
  lang: string;
  visibleWordIndexRef?: { current: number };
  /** In video mode, reuse the camera stream's mic instead of opening a second
   *  mic session — iOS gives the mic to the newest session and silences the
   *  recording otherwise. */
  getExternalStream?: () => MediaStream | null;
}) {
  const [anchorWordIndex, setAnchorWordIndex] = useState(-1);
  const [status, setStatus] = useState<VoiceFollowStatus>("off");
  const anchor = useRef(-1), wordList = useRef(words);
  useEffect(() => { wordList.current = words; }, [words]);
  useEffect(() => { anchor.current = -1; setAnchorWordIndex(-1); }, [words]);

  useEffect(() => {
    if (!enabled) {
      anchor.current = -1;
      setAnchorWordIndex(-1);
      setStatus("off");
      return;
    }
    if (!isVoiceFollowSupported()) { setStatus("error"); return; }
    let stopped = false, stream: MediaStream | null = null, context: AudioContext | null = null;
    let source: MediaStreamAudioSourceNode | null = null, processor: ScriptProcessorNode | null = null;
    let recognition: any = null, chunks: Float32Array[] = [], samples = 0, newSamples = 0, rate = 48000, timer = 0, inFlight = 0;
    let requestSequence = 0, latestAppliedSequence = 0;
    let previousInterim = "", stableInterimHits = 0;
    let hasSentAudio = false, consecutiveFailures = 0;
    let noiseFloor = 0.0012;
    const requestControllers = new Map<number, AbortController>();
    const firstVisible = Math.max(0, visibleWordIndexRef?.current ?? 0);
    anchor.current = Math.min(firstVisible, Math.max(0, wordList.current.length - 1));
    setAnchorWordIndex(wordList.current.length ? anchor.current : -1);
    setStatus("starting");

    // Sequential alignment constrained to what is currently visible. Off-script
    // speech is ignored instead of being treated as a document-wide search.
    const advance = (raw: string, interim: boolean) => {
      const list = wordList.current;
      const visible = Math.max(0, visibleWordIndexRef?.current ?? anchor.current);
      // Manual scrolling is authoritative. Re-anchor near the eye-line without
      // ever jumping backward because of a stale transcription response.
      if (visible > anchor.current + 8) anchor.current = Math.min(visible, list.length - 1);
      const cursor = Math.max(0, anchor.current);
      const heardWords = raw.split(/\s+/).map(normalizeWord).filter(Boolean).slice(-14);
      const heard = heardWords.join("");
      if (!list.length || heard.length < (interim ? 3 : 2)) return;
      const from = Math.max(0, Math.min(cursor, visible) - 4);
      const lookAhead = interim ? 18 : 44;
      const to = Math.min(list.length - 1, Math.max(cursor, visible) + lookAhead);
      let bestEnd = -1, best = 0;
      for (let start = from; start <= Math.min(Math.max(cursor, visible) + 3, to); start++) {
        let candidate = "";
        for (let end = start; end <= to; end++) {
          candidate += list[end].norm;
          if (end < cursor || candidate.length < 2) continue;
          const width = Math.min(candidate.length, heard.length);
          const distancePenalty = Math.max(0, end - Math.max(cursor, visible) - 9) * 0.02;
          const shortPenalty = width < 5 ? 0.1 : 0;
          const score = similarity(candidate.slice(-width), heard.slice(-width)) - distancePenalty - shortPenalty;
          if (score > best) { best = score; bestEnd = end; }
        }
      }
      if (bestEnd <= cursor || best < (interim ? 0.74 : 0.56)) return;
      const next = Math.min(bestEnd, cursor + (interim ? 7 : 20));
      anchor.current = next;
      setAnchorWordIndex(next);
    };

    // Fast local interim results (usually 100–300 ms), used conservatively.
    const Recognition = (window as any).SpeechRecognition || (window as any).webkitSpeechRecognition;
    if (Recognition) try {
      recognition = new Recognition();
      recognition.lang = lang; recognition.continuous = true; recognition.interimResults = true; recognition.maxAlternatives = 3;
      recognition.onresult = (event: any) => {
        let transcript = "";
        for (let i = event.resultIndex; i < event.results.length; i++) transcript += ` ${event.results[i][0]?.transcript || ""}`;
        const normalized = transcript.split(/\s+/).map(normalizeWord).filter(Boolean).join("");
        if (!normalized) return;
        if (lang.startsWith("ko")) {
          // Korean browser interim recognition is fast but noisy. Require two
          // consecutive hypotheses to share a stable suffix before it may move
          // the cursor; the model stream remains the accuracy authority.
          const width = Math.min(previousInterim.length, normalized.length, 10);
          const agrees = width >= 3 && similarity(previousInterim.slice(-width), normalized.slice(-width)) >= 0.72;
          stableInterimHits = agrees ? stableInterimHits + 1 : 0;
          previousInterim = normalized;
          if (stableInterimHits < 1) return;
        }
        advance(transcript, true);
      };
      recognition.onend = () => { if (!stopped) try { recognition.start(); } catch {} };
      recognition.start();
    } catch { recognition = null; }

    const readEvents = async (response: Response, sequence: number) => {
      if (!response.body) return;
      const reader = response.body.getReader(), decoder = new TextDecoder();
      let buffer = "", transcript = "";
      while (!stopped) {
        const { value, done } = await reader.read();
        if (done) break;
        buffer += decoder.decode(value, { stream: true });
        const events = buffer.split("\n\n"); buffer = events.pop() || "";
        for (const event of events) for (const line of event.split("\n")) if (line.startsWith("data:")) try {
          const data = JSON.parse(line.slice(5).trim());
          if (sequence < latestAppliedSequence) continue;
          if (data.type === "transcript.text.delta" && data.delta) { transcript += data.delta; advance(transcript, false); }
          if (data.type === "transcript.text.done" && data.text) {
            latestAppliedSequence = Math.max(latestAppliedSequence, sequence);
            advance(data.text, false);
          }
        } catch {}
      }
    };

    const send = async () => {
      const minimumFreshAudio = rate * (hasSentAudio ? 0.14 : 0.36);
      if (stopped || inFlight >= 2 || newSamples < minimumFreshAudio) return;
      const count = Math.min(samples, Math.floor(rate * 0.6)), audio = new Float32Array(count);
      let need = count, pos = count;
      for (let i = chunks.length - 1; i >= 0 && need; i--) {
        const take = Math.min(need, chunks[i].length);
        audio.set(chunks[i].subarray(chunks[i].length - take), pos - take); pos -= take; need -= take;
      }
      const overlap = audio.slice(Math.max(0, audio.length - Math.floor(rate * 0.28)));
      chunks = [overlap]; samples = overlap.length;
      newSamples = 0;
      const level = rms(audio);
      // Adapt to the current iPhone/external-mic noise floor. A fixed peak
      // threshold discarded quiet Korean speech when the phone was mounted
      // sideways and farther from the speaker.
      if (level < noiseFloor * 1.55) {
        noiseFloor = noiseFloor * 0.92 + level * 0.08;
        return;
      }
      noiseFloor = Math.min(0.012, noiseFloor * 0.985 + Math.min(level, noiseFloor * 2) * 0.015);
      const audioFile = wav(downsample(audio, rate));
      const sequence = ++requestSequence;
      const controller = new AbortController();
      requestControllers.set(sequence, controller);
      inFlight++;
      try {
        const body = new FormData(); body.append("file", audioFile, "speech.wav");
        body.append("language", lang.startsWith("ko") ? "ko" : "en");
        // Do not prime transcription with the script itself. Short noisy windows
        // can otherwise be completed from the prompt instead of the microphone,
        // creating false advances during pauses or off-script speech. Visible
        // context is applied only by the sequential matcher in advance().
        const response = await fetch("/api/public/transcribe", { method: "POST", body, signal: controller.signal });
        if (response.ok && sequence >= latestAppliedSequence) {
          // The newest window wins immediately. Older overlapping streams may
          // finish later, but can no longer pull the cursor toward stale words.
          latestAppliedSequence = sequence;
          // Once a newer stream has reached response headers, older overlapping
          // streams cannot improve alignment and only consume scarce iOS
          // connection/decoder time.
          requestControllers.forEach((pending, pendingSequence) => {
            if (pendingSequence < sequence) pending.abort();
          });
          await readEvents(response, sequence);
          consecutiveFailures = 0;
          hasSentAudio = true;
          if (!stopped) setStatus("listening");
        } else if (!response.ok) {
          consecutiveFailures++;
          if (consecutiveFailures >= 3 && !stopped) setStatus("error");
        }
      } catch (error) {
        if (controller.signal.aborted) return;
        consecutiveFailures++;
        if (consecutiveFailures >= 3 && !stopped) setStatus("error");
      } finally { requestControllers.delete(sequence); inFlight--; }
    };

    (async () => {
      const shared = getExternalStream?.() ?? null;
      if (shared && shared.getAudioTracks().some((t) => t.readyState === "live")) {
        stream = shared;
        ownsStream = false;
      } else {
        try { stream = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true } }); }
        catch { if (!stopped) setStatus("error"); return; }
      }
      if (stopped) { if (ownsStream) stream.getTracks().forEach((track) => track.stop()); return; }
      const AC = (window as any).AudioContext || (window as any).webkitAudioContext;
      context = new AC(); await context!.resume(); rate = context!.sampleRate;
      source = context!.createMediaStreamSource(stream); processor = context!.createScriptProcessor(1024, 1, 1);
      processor.onaudioprocess = (event) => {
        const copy = new Float32Array(event.inputBuffer.getChannelData(0)); chunks.push(copy); samples += copy.length; newSamples += copy.length;
        while (samples > rate * 2 && chunks.length > 1) samples -= chunks.shift()!.length;
      };
      const silent = context!.createGain(); silent.gain.value = 0;
      source.connect(processor); processor.connect(silent); silent.connect(context!.destination);
      setStatus("listening"); window.setTimeout(send, 360); timer = window.setInterval(send, 140);
    })();

    return () => {
      stopped = true; window.clearInterval(timer);
      requestControllers.forEach((controller) => controller.abort());
      requestControllers.clear();
      try { recognition?.abort(); processor?.disconnect(); source?.disconnect(); } catch {}
      try { stream?.getTracks().forEach((track) => track.stop()); context?.close(); } catch {}
      setStatus("off");
    };
  }, [enabled, lang, visibleWordIndexRef]);

  return { anchorWordIndex, status };
}