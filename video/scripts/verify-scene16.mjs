// Verifies scene 16 from the scene graph (kinetograph inspect) and the rendered MP4 (ffprobe).
// Run after `kinetograph render`: node scripts/verify-scene16.mjs
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { splitBeats } from '../src/lib/captions.ts';
import { SCENE16_BEATS, SCENE16_FPS, SCENE16_FRAMES, SCENE16_SECONDS, scene16Timeline, targetRect } from '../src/data/scene16.ts';
import { SCREENS } from '../src/screens/geometry.ts';

const TOL = 1; // px
const BOX_TOL = 3; // px, for the whole pointer inside its button
const results = [];
let failed = false;
const check = (name, ok, detail) => {
  results.push(`${ok ? 'PASS' : 'FAIL'}  ${name}  ${detail}`);
  if (!ok) failed = true;
};

const script = JSON.parse(readFileSync(new URL('../src/data/script.json', import.meta.url), 'utf8'));
const beats = splitBeats(script.scenes.find((s) => s.n === 16).caption);
const timeline = scene16Timeline(beats);

const inspect = (frame) =>
  JSON.parse(execFileSync('npx', ['kinetograph', 'inspect', 'src/index.tsx', '--comp', 'Scene16', '--frame', String(frame), '--json'], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 }));

const find = (layers, id) => {
  for (const l of layers) {
    if (l.id === id) return l;
    const hit = l.children && find(l.children, id);
    if (hit) return hit;
  }
  return undefined;
};
const bbox = (l) => l.bounds;
const cy = (b) => b.y + b.height / 2;
const within = (p, b) => p.x >= b.x && p.x <= b.x + b.width && p.y >= b.y && p.y <= b.y + b.height;
const fmt = (n) => Number(n).toFixed(1);

SCENE16_BEATS.forEach((b, i) => {
  const frame = timeline[i].to - 5;
  const tag = `beat ${i} f${frame}`;
  const layers = inspect(frame).layers;

  const pointer = find(layers, 'pointer');
  if (b.target) {
    const btn = find(layers, `btn-${b.target}`);
    if (!pointer || !btn) {
      check(`${tag} pointer and btn-${b.target} exist`, false, `pointer=${!!pointer} btn=${!!btn}`);
    } else {
      // Tip is the layer origin: translation of its matrix.
      const tip = { x: pointer.matrix[4], y: pointer.matrix[5] };
      const r = bbox(btn);
      const expected = targetRect(b.screen, b.target);
      const sameAsGeometry = Math.abs(r.x - expected.x) <= TOL && Math.abs(r.y - expected.y) <= TOL && Math.abs(r.width - expected.width) <= TOL && Math.abs(r.height - expected.height) <= TOL;
      check(`${tag} btn-${b.target} bounds equal SCREENS.${b.screen}.${b.target}`, sameAsGeometry, `bounds ${fmt(r.x)},${fmt(r.y)} ${fmt(r.width)}x${fmt(r.height)}`);
      check(`${tag} pointer tip inside btn-${b.target}`, within(tip, r) && within(tip, expected), `tip ${fmt(tip.x)},${fmt(tip.y)} in ${fmt(r.x)},${fmt(r.y)} ${fmt(r.width)}x${fmt(r.height)}`);
      if (i >= 4) {
        // Whole arrow (full layer bounds) at rest stays inside the target button.
        const pb = bbox(pointer);
        const slack = Math.max(r.x - pb.x, r.y - pb.y, pb.x + pb.width - (r.x + r.width), pb.y + pb.height - (r.y + r.height));
        check(`${tag} pointer bounds inside btn-${b.target} (tolerance ${BOX_TOL} px)`, slack <= BOX_TOL, `pointer ${fmt(pb.x)},${fmt(pb.y)} ${fmt(pb.width)}x${fmt(pb.height)} in ${fmt(r.x)},${fmt(r.y)} ${fmt(r.width)}x${fmt(r.height)} (worst overshoot ${fmt(slack)})`);
      }
      if (i === 5) {
        const trash = find(layers, 'btn-trash');
        const t = bbox(trash);
        const s = SCREENS.dialogConfirm.trash;
        check(`${tag} pointer tip not inside btn-trash`, !within(tip, t) && !within(tip, s), `tip ${fmt(tip.x)},${fmt(tip.y)} vs trash ${fmt(t.x)},${fmt(t.y)} ${fmt(t.width)}x${fmt(t.height)}`);
      }
    }
  } else {
    const fade = find(layers, 'pointer-fade');
    check(`${tag} pointer hidden before its first beat`, !pointer || pointer.opacity === 0 || (fade && fade.opacity === 0), `pointer-fade opacity ${fade ? fade.opacity : 'absent'}`);
  }

  const wants = new Set(b.labels ?? []);
  for (const [label, target] of [['good', 'open'], ['bad', 'trash']]) {
    const line = find(layers, `callout-${target}-line`);
    if (wants.has(label)) {
      const btn = find(layers, `btn-${target}`);
      if (!line || !btn) {
        check(`${tag} callout-${target}-line and btn-${target} exist`, false, `line=${!!line} btn=${!!btn}`);
        continue;
      }
      const dy = Math.abs(cy(bbox(line)) - cy(bbox(btn)));
      check(`${tag} callout-${target}-line center y equals btn-${target} center y`, dy <= TOL, `line ${fmt(cy(bbox(line)))} vs button ${fmt(cy(bbox(btn)))} (diff ${fmt(dy)})`);
    } else {
      check(`${tag} no callout-${target}-line`, !line, line ? 'present' : 'absent');
    }
  }
});

const mp4 = new URL('../out/renders/Scene16.mp4', import.meta.url).pathname;
if (!existsSync(mp4)) {
  check('MP4 exists', false, mp4);
} else {
  const probe = JSON.parse(execFileSync('ffprobe', ['-v', 'error', '-show_entries', 'stream=codec_type,width,height,r_frame_rate,nb_frames,duration:format=duration', '-of', 'json', mp4], { encoding: 'utf8' }));
  const video = probe.streams.filter((s) => s.codec_type === 'video');
  const audio = probe.streams.filter((s) => s.codec_type === 'audio');
  check('MP4 has no audio stream', audio.length === 0, `${audio.length} audio streams`);
  check('MP4 is 1920x1080', video[0]?.width === 1920 && video[0]?.height === 1080, `${video[0]?.width}x${video[0]?.height}`);
  check(`MP4 is ${SCENE16_FPS} fps`, video[0]?.r_frame_rate === `${SCENE16_FPS}/1`, `r_frame_rate ${video[0]?.r_frame_rate}`);
  const dur = Number(probe.format.duration);
  check(`MP4 lasts ${SCENE16_SECONDS} s (script entry for scene 16)`, Math.abs(dur - SCENE16_SECONDS) <= 0.05, `format duration ${dur}`);
  const frames = Number(video[0]?.nb_frames);
  check(`MP4 has ${SCENE16_FRAMES} frames`, frames === SCENE16_FRAMES, `nb_frames ${video[0]?.nb_frames}`);
}

console.log(results.join('\n'));
console.log(failed ? '\nFAILED' : `\nall ${results.length} checks passed`);
process.exit(failed ? 1 : 0);
