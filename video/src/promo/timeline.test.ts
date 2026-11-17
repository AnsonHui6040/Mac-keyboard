import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { FILM_FRAMES, sceneFrames } from '../data/scenes/index.ts';
import { FRAMES as INTRO_FRAMES } from '../intro/timeline.ts';
import { FORBIDDEN, FRAMES as FILM_FRAMES_OLD, captionLength } from '../film/timeline.ts';
import manifest from './voice-manifest.json' with { type: 'json' };
import { NARRATION } from './narration.ts';
import { toSrt } from './srt.ts';
import { END_CARD, FPS, FRAMES, HOLD_AFTER_TAP, L_CUT, PAD, PAD_RATE, PAD_START, SEG2_DRAFT_AT, SEGMENTS, SEG_MIN, TITLES, VOICE, padFrame, seg, voice } from './timeline.ts';

const m = manifest as Record<string, { seconds: number; firstPause: number | null }>;
const clean = (x: number): number => Math.round(x * 1e6) / 1e6;
const PADF = Math.round(PAD * FPS);

test('segment length is the longer of the picture minimum and the voice plus pads', () => {
  assert.deepEqual(SEG_MIN, { '1': 4.0, '2': 12.6, '3': 4.5, '4': 9.5, '5': 4.0, '6': 7.9, '7': 2.0, '8': 12.0, '9': 4.5, '10': 6.5 });
  for (const n of NARRATION) {
    const s = seg(n.seg);
    if (L_CUT.includes(n.seg)) continue;
    assert.equal(s.to - s.from, Math.ceil(clean(Math.max(SEG_MIN[n.seg], m[n.id].seconds + 2 * PAD) * FPS)), n.seg);
  }
});

test('segments 3 and 5 end HOLD_AFTER_TAP frames after the host tap', () => {
  assert.equal(HOLD_AFTER_TAP, 45);
  assert.deepEqual(L_CUT, ['3', '5']);
  for (const [sid, id] of [['3', '03'], ['5', '05']] as const) {
    const s = seg(sid);
    assert.equal(s.to - s.from, PADF + Math.round(m[id].firstPause! * FPS) + HOLD_AFTER_TAP, sid);
  }
  assert.equal(seg('3').to - seg('3').from, 70);
  assert.equal(seg('5').to - seg('5').from, 76);
});

test('segments are contiguous from 0 and FRAMES is at most 2130', () => {
  assert.equal(SEGMENTS.length, 10);
  assert.equal(SEGMENTS[0].from, 0);
  for (let i = 1; i < SEGMENTS.length; i++) assert.equal(SEGMENTS[i].from, SEGMENTS[i - 1].to);
  assert.equal(SEGMENTS[9].to, FRAMES);
  assert.ok(FRAMES <= 2130);
  assert.equal(FRAMES, 1983);
});

test('FRAMES differs from every other composition', () => {
  const others = [FILM_FRAMES_OLD, INTRO_FRAMES, FILM_FRAMES, ...Array.from({ length: 21 }, (_, i) => sceneFrames(i + 1))];
  for (const o of others) assert.notEqual(FRAMES, o);
});

test('lines 03 and 05 may run up to 21 frames into the next shot, the others sit inside their segment with PAD on both sides, lines at least 9 frames apart', () => {
  assert.equal(VOICE.length, 10);
  for (const n of NARRATION) {
    const s = seg(n.seg);
    const v = voice(n.id);
    assert.equal(v.to, v.from + Math.ceil(clean(m[n.id].seconds * FPS)), n.id);
    if (L_CUT.includes(n.seg)) {
      assert.equal(v.from, s.from + PADF, n.id);
      assert.ok(v.to > s.to && v.to - s.to <= 21, `${n.id} runs ${v.to - s.to} frames over`);
    } else {
      assert.ok(v.from >= s.from + PADF, n.id);
      assert.ok(v.to <= s.to - PADF, n.id);
    }
  }
  assert.equal(voice('04').from, Math.max(seg('4').from + PADF, voice('03').to + 9));
  assert.equal(voice('06').from, Math.max(seg('6').from + PADF, voice('05').to + 9));
  for (let i = 1; i < VOICE.length; i++) assert.ok(VOICE[i].from - VOICE[i - 1].to >= 9, VOICE[i].id);
});

test('the trackpad of the old shot 21 fits segment 8 at most 25% faster', () => {
  assert.equal(padFrame(PAD_START), 876);
  assert.equal(Math.round(padFrame(seg('8').to - 6)), 1252);
  assert.ok(PAD_RATE >= 1 && PAD_RATE <= 1.25, String(PAD_RATE));
  assert.equal(PAD_START, voice('08').from + Math.round(m['08'].firstPause! * FPS));
  assert.equal(padFrame(0), 849);
  assert.equal(padFrame(FRAMES), 1252);
});

test('titles: text, reading speed, forbidden strings', () => {
  assert.deepEqual(TITLES.map((t) => t.text), [
    '一支 iPhone 打字到三部電腦', '即時模式每按一個鍵就送出', '草稿模式先改好再傳送', '點一下換電腦',
    '中文可以用手寫', '也可以在 App 改用速成', '一指移動游標', '輕點就是點按', '按住再拖曳', '兩指輕點是右鍵', '兩指滑動來捲動',
  ]);
  for (const t of TITLES) {
    assert.ok(t.to > t.from && t.from >= 0 && t.to <= FRAMES, t.id);
    assert.ok(captionLength(t.text) / ((t.to - t.from) / FPS) < 7, t.id);
    for (const f of FORBIDDEN) assert.ok(!t.text.includes(f), `${t.id} ${f}`);
    assert.ok(t.size >= 76, t.id);
  }
});

test('the draft title starts on the frame of the draft key and the live title ends there', () => {
  assert.equal(SEG2_DRAFT_AT, seg('2').from + Math.round(5.6 * FPS));
  const p2 = TITLES.find((t) => t.id === 'p2')!;
  const p3 = TITLES.find((t) => t.id === 'p3')!;
  assert.equal(p2.to, SEG2_DRAFT_AT);
  assert.equal(p3.from, SEG2_DRAFT_AT);
});

test('end card lines', () => {
  const at = seg('10').from;
  const rows = END_CARD.map((l) => [l.at - at, l.text, l.size, l.y, l.weight, l.color]);
  assert.deepEqual(rows, [
    [0, 'Remote Keyboard', 120, 170, 700, '#f5f5f7'],
    [0, 'v0.2.0 Alpha', 56, 350, 500, '#f5f5f7'],
    [0, '支援 macOS 15、Windows 11、Ubuntu 26.04', 52, 450, 400, '#9a9ba1'],
    [0, '透過 SideStore 安裝 不是 App Store 版本', 52, 530, 400, '#9a9ba1'],
    [60, '下載 github.com/AnsonHui6040/Mac-keyboard', 56, 690, 500, '#f5f5f7'],
    [60, '與 Apple、Microsoft、Canonical 沒有關聯', 32, 960, 400, '#9a9ba1'],
  ]);
});

test('the SRT file is generated from the narration and the timeline', () => {
  const file = readFileSync(new URL('../../../docs/video/promo-v0.2.srt', import.meta.url), 'utf8');
  assert.equal(file, toSrt());
  const blocks = file.trim().split('\n\n');
  assert.equal(blocks.length, 10);
  const ts = (f: number): string => {
    const ms = Math.round((f * 1000) / FPS);
    const p = (n: number, w: number): string => String(n).padStart(w, '0');
    return `${p(Math.floor(ms / 3600000), 2)}:${p(Math.floor(ms / 60000) % 60, 2)}:${p(Math.floor(ms / 1000) % 60, 2)},${p(ms % 1000, 3)}`;
  };
  blocks.forEach((b, i) => {
    const [idx, time, ...text] = b.split('\n');
    const v = VOICE[i];
    assert.equal(idx, String(i + 1));
    assert.equal(time, `${ts(v.from)} --> ${ts(v.to)}`);
    assert.equal(text.join('\n'), NARRATION[i].caption);
  });
});
