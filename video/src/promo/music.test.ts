import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { FPS, FRAMES, L_CUT, PAD, SEGMENTS, VOICE, seg } from './timeline.ts';
import { NARRATION } from './narration.ts';
import { BEAT_PERIOD, BEAT_T0, FADE_SILENT_FROM, FILE_SECONDS, beatOffsetFrames } from './music.ts';
import { PROMO_MUSIC } from './music.ts';

/** The segment boundaries of the first assembly (Task 1 values) before the music moved them. */
const TASK1 = { b3: 495, b8: 1250 };
const MUSIC_FILE = new URL('../../public/audio/Measured_Steps.mp3', import.meta.url);

test('one continuous take from frame 0, no cut or restart', () => {
  assert.equal(PROMO_MUSIC.length, 1);
  const m = PROMO_MUSIC[0];
  assert.equal(m.file, 'audio/Measured_Steps.mp3');
  assert.equal(m.from, 0);
  assert.equal(m.to, FRAMES);
  assert.equal(m.shift + 0, -m.trimBefore / FPS + 0);
  assert.ok(m.trimBefore >= 0 && Number.isInteger(m.trimBefore));
  assert.ok(m.base > 0 && m.base <= 1);
});

test('the track fades out by itself: the film ends no earlier than the fade and at most 0.15 s later', () => {
  const m = PROMO_MUSIC[0];
  const sourceAtEnd = FRAMES / FPS + m.trimBefore / FPS;
  assert.ok(sourceAtEnd >= FADE_SILENT_FROM, `film ends at source ${sourceAtEnd}, the fade is silent from ${FADE_SILENT_FROM}`);
  assert.ok(sourceAtEnd - FADE_SILENT_FROM <= 0.15, `silent tail ${sourceAtEnd - FADE_SILENT_FROM} s`);
  assert.ok(sourceAtEnd <= FILE_SECONDS, 'the file is long enough');
});

test('segment boundaries 3 and 8 sit on a beat (within 1 frame), each moved at most 1 s from Task 1', () => {
  const m = PROMO_MUSIC[0];
  const b3 = seg('3').from;
  const b8 = seg('8').from;
  assert.ok(Math.abs(beatOffsetFrames(b3, m.trimBefore)) <= 1, `boundary 3 at ${b3} is ${beatOffsetFrames(b3, m.trimBefore)} frames from a beat`);
  assert.ok(Math.abs(beatOffsetFrames(b8, m.trimBefore)) <= 1, `boundary 8 at ${b8} is ${beatOffsetFrames(b8, m.trimBefore)} frames from a beat`);
  assert.ok(Math.abs(b3 - TASK1.b3) <= FPS, `boundary 3 moved ${b3 - TASK1.b3} frames`);
  assert.ok(Math.abs(b8 - TASK1.b8) <= FPS, `boundary 8 moved ${b8 - TASK1.b8} frames`);
});

test('the beat grid is about 120 BPM, starts on the lift at source 16.09 s, and the first host switch is the first beat after the lift', () => {
  assert.ok(Math.abs(60 / BEAT_PERIOD - 120) < 0.5);
  assert.ok(BEAT_T0 > 16 && BEAT_T0 < 16.2);
  const at = (seg('3').from + PROMO_MUSIC[0].trimBefore) / FPS;
  assert.ok(Math.abs(at - (BEAT_T0 + BEAT_PERIOD)) <= 1 / FPS, `boundary 3 at source ${at} s`);
});

test('FRAMES still at most 2130 and every line still inside its segment', () => {
  assert.ok(FRAMES <= 2130);
  const PADF = Math.round(PAD * FPS);
  for (const n of NARRATION) {
    const s = SEGMENTS.find((x) => x.id === n.seg)!;
    const v = VOICE.find((x) => x.id === n.id)!;
    assert.ok(v.from >= s.from + PADF, `${n.id} starts inside its segment`);
    if (L_CUT.includes(n.seg)) assert.ok(v.to <= s.to + 21, `${n.id} runs at most 21 frames into the next shot`);
    else assert.ok(v.to <= s.to - PADF, `${n.id} ends inside its segment`);
  }
});

test('the music file, when present, is the length and format the constants say', { skip: !existsSync(MUSIC_FILE) }, () => {
  const r = spawnSync('ffprobe', ['-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', MUSIC_FILE.pathname], { encoding: 'utf8' });
  assert.equal(r.status, 0);
  assert.ok(Math.abs(parseFloat(r.stdout) - FILE_SECONDS) < 0.1, r.stdout);
});
