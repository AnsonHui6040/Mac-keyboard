// Checks from the rendered MP4 that the interface sounds land on the frames the events list says.
// Run after `kinetograph render`: node scripts/verify-audio.mjs [mp4]
// For isolated press events (no other event in the 400 ms before) it band-limits the audio with ffmpeg and compares the energy
// in the 80 ms from the press frame with the 300 ms before it, and finds the first 1 ms block that jumps. Then the same for
// control frames far from every event, which must show no jump. Press sounds are bursts, the music is steady, so a jump on the
// frame is the effect. A click passes with 10 dB more energy; a tap (low, and among the pad's own notes) with a peak 3 dB higher.
// Both must start within 4 ms of the frame.
import { execFileSync } from 'node:child_process';
import { FPS } from '../src/data/scenes/index.ts';
import { soundEvents } from '../src/audio/events.ts';

const mp4 = process.argv[2] ?? new URL('../out/renders/Main.mp4', import.meta.url).pathname;
const SR = 48000;
const WANT = 8; // press events to report per kind, at least
const filters = { click: 'highpass=f=1500', tap: 'highpass=f=150' }; // click is a bright tick; tap is lower, so the band starts lower
const decode = (hp) => {
  const raw = execFileSync('ffmpeg', ['-v', 'error', '-i', mp4, '-vn', '-ac', '1', '-ar', String(SR), '-af', hp, '-f', 'f32le', '-'], { maxBuffer: 1 << 30 });
  return new Float32Array(raw.buffer, raw.byteOffset, Math.floor(raw.byteLength / 4));
};
const rms = (a, from, to) => {
  let s = 0;
  for (let i = from; i < to; i++) s += a[i] * a[i];
  return Math.sqrt(s / Math.max(1, to - from));
};
const peak = (a, from, to) => {
  let p = 0;
  for (let i = from; i < to; i++) p = Math.max(p, Math.abs(a[i]));
  return p;
};
const db = (x) => 20 * Math.log10(Math.max(x, 1e-9));
const ms = (n) => Math.round((n / 1000) * SR);
// rmsGain: energy in the 80 ms from the frame against the 300 ms before it. peakGain: highest sample in the 60 ms from the frame
// against the highest in the 300 ms before. onset: the first 1 ms block, from 20 ms before the frame, whose peak is 1.25 times the
// highest sample of the 300 ms before (milliseconds after the frame start; null if none within 100 ms).
const measure = (a, frame) => {
  const at = Math.round((frame / FPS) * SR);
  const beforeRms = rms(a, at - ms(300), at);
  const beforePeak = peak(a, at - ms(300), at);
  let onset = null;
  for (let k = -20; k < 100 && onset === null; k++) if (peak(a, at + ms(k), at + ms(k + 1)) > 1.25 * beforePeak) onset = k;
  return { before: beforeRms, after: rms(a, at, at + ms(80)), rmsGain: db(rms(a, at, at + ms(80))) - db(beforeRms), peakGain: db(peak(a, at, at + ms(60))) - db(beforePeak), onset };
};

const events = soundEvents();
const isolated = (e) => events.every((o) => o === e || o.frame > e.frame || e.frame - o.frame > 12);
const rows = [];
let failed = false;
for (const kind of ['click', 'tap']) {
  const a = decode(filters[kind]);
  const picks = events.filter((e) => e.kind === kind && isolated(e));
  const step = Math.max(1, Math.floor(picks.length / WANT));
  const chosen = picks.filter((_, i) => i % step === 0).slice(0, Math.max(WANT, 8));
  for (const e of chosen) {
    const m = measure(a, e.frame);
    const ok = (kind === 'click' ? m.rmsGain >= 10 : m.peakGain >= 3) && m.onset !== null && Math.abs(m.onset) <= 4;
    if (!ok) failed = true;
    rows.push({ what: kind, frame: e.frame, sec: (e.frame / FPS).toFixed(2), before: db(m.before).toFixed(1), after: db(m.after).toFixed(1), gain: m.rmsGain.toFixed(1), peak: m.peakGain.toFixed(1), onset: m.onset === null ? 'none' : `${m.onset} ms`, ok: ok ? 'PASS' : 'FAIL' });
  }
  // controls: frames at least 2 s from every event, as they sit in the film
  const controls = [];
  for (let f = 90; controls.length < 4 && f < 10000; f += 997) if (events.every((o) => Math.abs(o.frame - f) > 2 * FPS)) controls.push(f);
  for (const f of controls) {
    const m = measure(a, f);
    const ok = m.rmsGain < 3 && m.peakGain < 1.5 && m.onset === null;
    if (!ok) failed = true;
    rows.push({ what: `${kind} control`, frame: f, sec: (f / FPS).toFixed(2), before: db(m.before).toFixed(1), after: db(m.after).toFixed(1), gain: m.rmsGain.toFixed(1), peak: m.peakGain.toFixed(1), onset: m.onset === null ? 'none' : `${m.onset} ms`, ok: ok ? 'PASS' : 'FAIL' });
  }
}
console.log(`${'what'.padEnd(14)} ${'frame'.padStart(6)} ${'sec'.padStart(7)} ${'300ms before dB'.padStart(16)} ${'80ms after dB'.padStart(14)} ${'rms gain'.padStart(9)} ${'peak gain'.padStart(10)} ${'onset'.padStart(8)}`);
for (const r of rows) console.log(`${r.what.padEnd(14)} ${String(r.frame).padStart(6)} ${r.sec.padStart(7)} ${r.before.padStart(16)} ${r.after.padStart(14)} ${r.gain.padStart(9)} ${r.peak.padStart(10)} ${r.onset.padStart(8)}  ${r.ok}`);
console.log(failed ? '\nFAILED' : `\nall ${rows.length} checks passed`);
process.exit(failed ? 1 : 0);
