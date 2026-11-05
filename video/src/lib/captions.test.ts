import { test } from 'node:test';
import assert from 'node:assert/strict';
import script from '../data/script.json' with { type: 'json' };
import { displayLength, splitBeats, wrapBeat, minBeatFrames, beatTimeline } from './captions.ts';

const FPS = 30;
const scene = (n: number) => {
  const s = script.scenes.find((x) => x.n === n);
  if (!s) throw new Error(`scene ${n} missing from script.json`);
  return s;
};
const scene16 = scene(16);

test('displayLength: full-width counts 1, half-width counts 0.5', () => {
  assert.equal(displayLength('這是正常的。'), 6);
  assert.equal(displayLength('Apple'), 2.5);
  assert.equal(displayLength('a b'), 1.5);
  assert.equal(displayLength('「完成」，'), 5);
  assert.equal(displayLength(''), 0);
});

test('splitBeats: scene 16 splits into the approved beats', () => {
  assert.deepEqual(splitBeats(scene16.caption), [
    '這個版本沒有經過 Apple 公證，第一次打開會被擋下，',
    '這是正常的。',
    '先按「完成」，到系統設定的「隱私權與安全性」，',
    '捲到最下方按「強制打開」。',
    '系統再問一次時，要按中間的「強制打開」。',
    '藍色那顆是丟到垃圾桶，不要按。',
    '最後用 Touch ID 或密碼確認。',
  ]);
  assert.equal(splitBeats(scene16.caption).join(''), scene16.caption);
});

test('splitBeats: every scene round-trips and no beat is empty', () => {
  for (const s of script.scenes) {
    const beats = splitBeats(s.caption);
    assert.equal(beats.join(''), s.caption, `scene ${s.n}`);
    assert.ok(beats.every((b) => b.length > 0), `scene ${s.n}`);
  }
});

test('splitBeats: short sentences stay separate, maxChars respected', () => {
  assert.deepEqual(splitBeats('一二三。四五六！七八九？'), ['一二三。', '四五六！', '七八九？']);
  assert.deepEqual(splitBeats('一二三，四五六，七八九。', 6), ['一二三，', '四五六，', '七八九。']);
  assert.deepEqual(splitBeats('一二三，四五六，七八九。', 8), ['一二三，四五六，', '七八九。']);
  assert.deepEqual(splitBeats('沒有句號'), ['沒有句號']);
});

test('wrapBeat: one line when short, two lines when long, throws beyond two', () => {
  assert.deepEqual(wrapBeat('這是正常的。'), ['這是正常的。']);
  const long = '一二三四五六七八九十'.repeat(4); // 40
  const lines = wrapBeat(long);
  assert.equal(lines.length, 2);
  assert.equal(lines.join(''), long);
  assert.ok(lines.every((l) => displayLength(l) <= 30));
  assert.throws(() => wrapBeat('一二三四五六七八九十'.repeat(7)), /lines/);
});

test('wrapBeat: does not split an English word or start a line with punctuation', () => {
  const beat = '一二三四五六七八九十一二三四五六七八九十一二三四五六七八九 Touch ID，確認。';
  const lines = wrapBeat(beat);
  assert.equal(lines.length, 2);
  assert.ok(lines.every((l) => !'，。'.includes(l[0])));
  assert.ok(lines.some((l) => l.includes('Touch')) && !lines[0].endsWith('Tou'));
  assert.equal(lines.join('').replace(/ /g, ''), beat.replace(/ /g, ''));
});

test('minBeatFrames: floor of 2.5 s, otherwise 5 chars per second', () => {
  assert.equal(minBeatFrames('這是正常的。', 30), 75);
  assert.equal(minBeatFrames('一二三四五六七八九十一二三四五六七八九十', 30), 120); // 20 chars -> 4 s
  assert.equal(minBeatFrames('一二三四五六七八九十一二三四五六七八九十一', 30), 126); // 21 chars -> 4.2 s
  assert.equal(minBeatFrames('一二三。', 24), 60);
});

test('beatTimeline: contiguous, starts at 0, ends at totalFrames, respects minimums', () => {
  const beats = ['這是正常的。', '一二三四五六七八九十一二三四五六七八九十'];
  const tl = beatTimeline(beats, [undefined, undefined], 300, FPS);
  assert.equal(tl.length, 2);
  assert.equal(tl[0].from, 0);
  assert.equal(tl[0].to, tl[1].from);
  assert.equal(tl[1].to, 300);
  assert.ok(tl[0].to - tl[0].from >= 75);
  assert.ok(tl[1].to - tl[1].from >= 120);
  // leftover 105 frames shared 75:120
  assert.equal(tl[0].to - tl[0].from, 75 + Math.floor((105 * 75) / 195));
});

test('beatTimeline: scripted minSeconds raises the minimum', () => {
  const tl = beatTimeline(['這是正常的。', '這是正常的。'], [6, undefined], 300, FPS);
  assert.ok(tl[0].to - tl[0].from >= 180);
  assert.ok(tl[1].to - tl[1].from >= 75);
  assert.equal(tl[1].to, 300);
});

test('beatTimeline: exact fit gives exactly the minimums', () => {
  const tl = beatTimeline(['這是正常的。', '這是正常的。'], [undefined, undefined], 150, FPS);
  assert.deepEqual(tl, [{ from: 0, to: 75 }, { from: 75, to: 150 }]);
});

test('beatTimeline: throws with required and available frames when it does not fit', () => {
  assert.throws(
    () => beatTimeline(['這是正常的。', '這是正常的。'], [undefined, undefined], 149, FPS),
    (e: Error) => /150/.test(e.message) && /149/.test(e.message),
  );
  assert.throws(() => beatTimeline(['一。'], [], 100, FPS), /minSeconds/);
});

for (const s of script.scenes) {
  test(`scene ${s.n}: caption beats fit in ${s.seconds}s at ${FPS}fps`, () => {
    const beats = splitBeats(s.caption);
    for (const b of beats) wrapBeat(b);
    const tl = beatTimeline(beats, beats.map(() => undefined), s.seconds * FPS, FPS);
    assert.equal(tl[0].from, 0);
    assert.equal(tl[tl.length - 1].to, s.seconds * FPS);
    tl.forEach((seg, i) => {
      assert.ok(seg.to - seg.from >= minBeatFrames(beats[i], FPS));
      if (i > 0) assert.equal(seg.from, tl[i - 1].to);
    });
  });
}

test('wrapBeat keeps a CJK character with the ASCII word before it, so a line never starts with a lone 線', () => {
  const beat = '先準備這些：iOS 18 以上的 iPhone、Apple 晶片的 Mac、一條 USB 線、Wi-Fi，';
  assert.deepEqual(wrapBeat(beat), ['先準備這些：iOS 18 以上的 iPhone、Apple 晶片的 Mac、一條', 'USB 線、Wi-Fi，']);
  // directly attached, and only one character joins the word
  assert.deepEqual(wrapBeat('甲'.repeat(28) + 'USB線乙'), ['甲'.repeat(28), 'USB線乙']);
});

test('wrapBeat output for every other caption is unchanged (single lines stay single lines)', () => {
  assert.deepEqual(wrapBeat('Touch ID 或密碼確認。'), ['Touch ID 或密碼確認。']);
});
