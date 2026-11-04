/** Pure subtitle helpers: beat splitting, wrapping and timing. No external imports. */

const SENTENCE_END = '。！？';
const CLAUSE_BREAK = '，；';
const NO_LINE_START = '，。！？；：、）」』”’,.!?;:)';

/** Full-width and Chinese characters count 1, half-width (ASCII, including spaces) count 0.5. */
export function displayLength(s: string): number {
  let n = 0;
  for (const ch of s) {
    const code = ch.codePointAt(0) as number;
    const half = code <= 0x7f || (code >= 0xff61 && code <= 0xff9f);
    n += half ? 0.5 : 1;
  }
  return n;
}

function splitKeepingEnds(text: string, enders: string): string[] {
  const out: string[] = [];
  let cur = '';
  for (const ch of text) {
    cur += ch;
    if (enders.includes(ch)) {
      out.push(cur);
      cur = '';
    }
  }
  if (cur.length > 0) out.push(cur);
  return out;
}

/**
 * Split on sentence enders (。！？). A sentence longer than maxChars is cut at
 * clause breaks (，；) by greedily merging clauses up to maxChars.
 * Concatenating the result always reproduces the input.
 */
export function splitBeats(text: string, maxChars = 30): string[] {
  const beats: string[] = [];
  for (const sentence of splitKeepingEnds(text, SENTENCE_END)) {
    if (displayLength(sentence) <= maxChars) {
      beats.push(sentence);
      continue;
    }
    let cur = '';
    for (const clause of splitKeepingEnds(sentence, CLAUSE_BREAK)) {
      if (cur !== '' && displayLength(cur + clause) > maxChars) {
        beats.push(cur);
        cur = clause;
      } else {
        cur += clause;
      }
    }
    if (cur !== '') beats.push(cur);
  }
  return beats;
}

/** Break a beat into units: an ASCII word run (no break inside), a space, or one character. */
function units(beat: string): string[] {
  const out: string[] = [];
  let word = '';
  for (const ch of beat) {
    const code = ch.codePointAt(0) as number;
    if (code <= 0x7f && ch !== ' ') {
      word += ch;
    } else {
      if (word !== '') {
        out.push(word);
        word = '';
      }
      out.push(ch);
    }
  }
  if (word !== '') out.push(word);
  return out;
}

/** Wrap a beat into lines of at most maxChars display length. Throws when more than two lines are needed. */
export function wrapBeat(beat: string, maxChars = 30): string[] {
  if (displayLength(beat) <= maxChars) return [beat];
  const lines: string[] = [];
  let cur = '';
  for (const u of units(beat)) {
    const fits = displayLength(cur + u) <= maxChars;
    // Closing punctuation may hang past the limit rather than start a line.
    const hangs = cur !== '' && NO_LINE_START.includes(u);
    if (cur === '' || fits || hangs) {
      cur += u;
    } else {
      lines.push(cur.replace(/ +$/, ''));
      cur = u === ' ' ? '' : u;
    }
  }
  if (cur !== '') lines.push(cur);
  if (lines.length > 2) {
    throw new Error(`wrapBeat: needs ${lines.length} lines (max 2): ${displayLength(beat)} display chars, maxChars ${maxChars}`);
  }
  return lines;
}

/** Minimum frames a beat must stay on screen: ceil(max(2.5 s, displayLength / 5 s) * fps). */
export function minBeatFrames(beat: string, fps: number): number {
  const seconds = Math.max(2.5, displayLength(beat) / 5);
  return Math.ceil(seconds * fps - 1e-9);
}

/**
 * Lay beats end to end over totalFrames. Each beat first gets its minimum
 * (reading speed and any scripted minSeconds); leftover frames are shared in
 * proportion to those minimums. Throws when the minimums do not fit.
 */
export function beatTimeline(
  beats: string[],
  minSeconds: (number | undefined)[],
  totalFrames: number,
  fps: number,
): { from: number; to: number }[] {
  if (minSeconds.length !== beats.length) {
    throw new Error(`beatTimeline: ${beats.length} beats but ${minSeconds.length} minSeconds entries`);
  }
  const mins = beats.map((b, i) => {
    const ms = minSeconds[i];
    const scripted = ms === undefined ? 0 : Math.ceil(ms * fps - 1e-9);
    return Math.max(minBeatFrames(b, fps), scripted);
  });
  const required = mins.reduce((a, b) => a + b, 0);
  if (required > totalFrames) {
    throw new Error(`beatTimeline: beats need ${required} frames but only ${totalFrames} are available`);
  }
  const extra = totalFrames - required;
  const out: { from: number; to: number }[] = [];
  let cumMin = 0;
  let prevTo = 0;
  mins.forEach((m, i) => {
    cumMin += m;
    const to = i === mins.length - 1 ? totalFrames : cumMin + Math.floor((extra * cumMin) / required);
    out.push({ from: prevTo, to });
    prevTo = to;
  });
  return out;
}
