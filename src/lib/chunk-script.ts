// Turn a raw script into a token stream the reader can render as spans.
//
// - Words get a stable `wordIndex` so voice-follow can highlight them.
// - Spaces preserve original whitespace.
// - Breaks are soft line breaks inserted at natural breath-group boundaries
//   (Korean particles, commas, sentence enders, English conjunctions) when
//   `chunking` is on.
// - `pauseAfter` marks tokens where the auto-scroll should briefly slow:
//   "strong" for sentence enders, "soft" for commas / clause breaks.

export type Token =
  | { kind: "word"; text: string; wordIndex: number; norm: string; pauseAfter: "strong" | "soft" | null }
  | { kind: "space"; text: string }
  | { kind: "break" };

// Korean phrase-final particles/endings that safely end a breath group.
// Kept intentionally short — false positives feel worse than false negatives.
const KO_PARTICLE_ENDINGS = [
  "은", "는", "이", "가", "을", "를", "에", "에서", "으로", "로",
  "와", "과", "도", "만", "요", "다", "죠", "네", "니다", "습니다",
  "고", "며", "면서", "지만", "면", "라서", "니까",
];

const KO_CLAUSE_STARTERS = new Set([
  "그리고", "하지만", "그런데", "그래서", "그러나", "또한", "또", "즉",
  "따라서", "결국", "그러면", "그럼", "먼저", "다음", "마지막으로",
]);

const EN_CONJUNCTIONS = new Set([
  "and", "but", "so", "because", "or", "yet", "for", "nor",
  "while", "although", "though", "since", "unless", "when", "if",
]);

const STRONG_PUNCT = /[.!?…。！？]$/;
const SOFT_PUNCT = /[,;:—、，]$/;

function isHangul(ch: string): boolean {
  const c = ch.charCodeAt(0);
  return (c >= 0xac00 && c <= 0xd7a3) || (c >= 0x1100 && c <= 0x11ff) || (c >= 0x3130 && c <= 0x318f);
}

export function detectLang(body: string): "ko-KR" | "en-US" {
  let hangul = 0;
  let letters = 0;
  for (const ch of body) {
    if (isHangul(ch)) { hangul++; letters++; }
    else if (/[a-zA-Z]/.test(ch)) letters++;
  }
  if (letters === 0) return "en-US";
  return hangul / letters > 0.25 ? "ko-KR" : "en-US";
}

// Normalize a word for fuzzy matching — strip punctuation, lowercase.
export function normalizeWord(w: string): string {
  return w.replace(/[^\p{L}\p{N}가-힣]/gu, "").toLowerCase();
}

// Strip trailing punctuation only (keep letters/digits/hangul).
function stripTrailingPunct(w: string): string {
  return w.replace(/[^\p{L}\p{N}가-힣]+$/gu, "");
}

function endsWithKoreanParticle(bareWord: string): boolean {
  if (!bareWord) return false;
  // Only trigger on words with at least one Hangul syllable.
  if (![...bareWord].some(isHangul)) return false;
  for (const p of KO_PARTICLE_ENDINGS) {
    if (bareWord.endsWith(p) && bareWord.length > p.length) return true;
  }
  return false;
}

export function tokenize(body: string, chunking: boolean): Token[] {
  const tokens: Token[] = [];
  let wordIndex = 0;
  // Simple word/space splitter that preserves original whitespace.
  const parts = body.split(/(\s+)/);
  // Track running visual line length (approx characters) so we don't emit
  // one-word lines from over-eager chunking.
  let lineLen = 0;
  const MIN_LINE_CHARS = 14; // don't break earlier than this on a line

  for (let i = 0; i < parts.length; i++) {
    const part = parts[i];
    if (part === "") continue;
    if (/^\s+$/.test(part)) {
      // Preserve explicit newlines as hard breaks (reset line length).
      if (part.includes("\n")) {
        tokens.push({ kind: "space", text: part });
        lineLen = 0;
      } else {
        tokens.push({ kind: "space", text: part });
        lineLen += part.length;
      }
      continue;
    }

    const bare = stripTrailingPunct(part);
    const norm = normalizeWord(part);
    const strong = STRONG_PUNCT.test(part);
    const soft = !strong && SOFT_PUNCT.test(part);
    const koParticleEnd = endsWithKoreanParticle(bare);
    const enConj = EN_CONJUNCTIONS.has(norm);
    const koStarter = KO_CLAUSE_STARTERS.has(bare);

    // Emit an EN conjunction / KO clause starter as a line break BEFORE the word.
    if (chunking && (enConj || koStarter) && lineLen >= MIN_LINE_CHARS) {
      // Replace preceding trailing space (if any) with a break.
      const prev = tokens[tokens.length - 1];
      if (prev?.kind === "space" && !prev.text.includes("\n")) tokens.pop();
      tokens.push({ kind: "break" });
      lineLen = 0;
    }

    tokens.push({
      kind: "word",
      text: part,
      wordIndex: wordIndex++,
      norm,
      pauseAfter: strong ? "strong" : soft ? "soft" : null,
    });
    lineLen += part.length;

    // Break AFTER this word for strong/soft punctuation or Korean particle end.
    const shouldBreakAfter =
      chunking &&
      lineLen >= MIN_LINE_CHARS &&
      (strong || soft || koParticleEnd);

    if (shouldBreakAfter) {
      // Peek next non-empty part to avoid orphaning a single trailing word.
      let nextIdx = i + 1;
      while (nextIdx < parts.length && parts[nextIdx] === "") nextIdx++;
      // Skip the whitespace token; look at the word after it.
      const nextWordIdx = nextIdx < parts.length && /^\s+$/.test(parts[nextIdx]) ? nextIdx + 1 : nextIdx;
      const nextWord = nextWordIdx < parts.length ? parts[nextWordIdx] : "";
      const restIsShort = nextWord && nextWord.length <= 3 && nextWordIdx === parts.length - 1;
      if (!restIsShort) {
        // Consume the immediately following whitespace so we don't render "word \n".
        if (nextIdx < parts.length && /^\s+$/.test(parts[nextIdx]) && !parts[nextIdx].includes("\n")) {
          i = nextIdx; // skip it
        }
        tokens.push({ kind: "break" });
        lineLen = 0;
      }
    }
  }

  return tokens;
}

// Extract plain word list (with wordIndex) from tokens for voice-follow matching.
export function wordListFromTokens(tokens: Token[]): { norm: string; wordIndex: number }[] {
  const out: { norm: string; wordIndex: number }[] = [];
  for (const t of tokens) {
    if (t.kind === "word" && t.norm) out.push({ norm: t.norm, wordIndex: t.wordIndex });
  }
  return out;
}
