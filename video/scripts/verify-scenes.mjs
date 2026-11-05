// Verifies registered scenes from the scene graph (kinetograph inspect) and the rendered MP4 (ffprobe).
// Run after `kinetograph render`: node scripts/verify-scenes.mjs [scene numbers...] [--no-mp4]
// Without numbers it checks every registered scene and, instead of one MP4 per scene, out/renders/Main.mp4 (the whole film).
// With numbers it checks those scenes and their own out/renders/SceneNN.mp4. Checks the frame 5 before the end of every beat.
import { execFileSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { FILM_FRAMES, FPS, SCENES, compileRegistered, sceneEntry, sceneFrames, sceneId } from '../src/data/scenes/index.ts';
import { SCREENS } from '../src/screens/geometry.ts';

const TOL = 1; // px
const BOX_TOL = 3; // px, for the whole pointer inside its button
const MIN_BOX_HEIGHT = 70; // a Mac arrow (about 48 px tall) fits inside a button only when the button is at least about this tall

const args = process.argv.slice(2);
const wantMp4 = !args.includes('--no-mp4');
const wanted = args.filter((a) => a !== '--no-mp4').map(Number);
const wholeFilm = wanted.length === 0;
const specs = wanted.length === 0 ? SCENES : wanted.map((n) => {
  const spec = SCENES.find((s) => s.n === n);
  if (!spec) throw new Error(`scene ${n} is not registered`);
  return spec;
});

const results = [];
let failed = false;
const check = (name, ok, detail) => {
  results.push(`${ok ? 'PASS' : 'FAIL'}  ${name}  ${detail}`);
  if (!ok) failed = true;
};

const inspect = (comp, frame) =>
  JSON.parse(execFileSync('npx', ['kinetograph', 'inspect', 'src/index.tsx', '--comp', comp, '--frame', String(frame), '--json'], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 })).layers;

const find = (layers, id) => {
  for (const l of layers) {
    if (l.id === id) return l;
    const hit = l.children && find(l.children, id);
    if (hit) return hit;
  }
  return undefined;
};
const cy = (b) => b.y + b.height / 2;
const within = (p, b) => p.x >= b.x && p.x <= b.x + b.width && p.y >= b.y && p.y <= b.y + b.height;
const fmt = (n) => Number(n).toFixed(1);

const checkMp4 = (comp, seconds, frames, what) => {
  const mp4 = new URL(`../out/renders/${comp}.mp4`, import.meta.url).pathname;
  if (!existsSync(mp4)) {
    check(`${comp} MP4 exists`, false, mp4);
    return;
  }
  const probe = JSON.parse(execFileSync('ffprobe', ['-v', 'error', '-show_entries', 'stream=codec_type,width,height,r_frame_rate,nb_frames,duration:format=duration', '-of', 'json', mp4], { encoding: 'utf8' }));
  const video = probe.streams.filter((s) => s.codec_type === 'video');
  const audio = probe.streams.filter((s) => s.codec_type === 'audio');
  check(`${comp} MP4 has no audio stream`, audio.length === 0, `${audio.length} audio streams`);
  check(`${comp} MP4 is 1920x1080`, video[0]?.width === 1920 && video[0]?.height === 1080, `${video[0]?.width}x${video[0]?.height}`);
  check(`${comp} MP4 is ${FPS} fps`, video[0]?.r_frame_rate === `${FPS}/1`, `r_frame_rate ${video[0]?.r_frame_rate}`);
  const dur = Number(probe.format.duration);
  check(`${comp} MP4 lasts ${seconds} s (script seconds of ${what})`, Math.abs(dur - seconds) <= 0.05, `format duration ${dur}`);
  check(`${comp} MP4 has ${frames} frames`, Number(video[0]?.nb_frames) === frames, `nb_frames ${video[0]?.nb_frames}`);
};

for (const spec of specs) {
  const comp = sceneId(spec.n);
  const c = compileRegistered(spec);
  const seconds = sceneEntry(spec.n).seconds;
  const labelTargets = [...new Set(spec.beats.flatMap((b) => (b.labels ?? []).map((l) => l.target)))];

  spec.beats.forEach((b, i) => {
    const frame = c.timeline[i].to - 5;
    const tag = `${comp} beat ${i} f${frame}`;
    const layers = inspect(comp, frame);
    const pointer = find(layers, 'pointer');
    const last = b.steps && b.steps[b.steps.length - 1];

    if (last) {
      const btn = find(layers, `btn-${last.target}`);
      if (!pointer || !btn) {
        check(`${tag} pointer and btn-${last.target} exist`, false, `pointer=${!!pointer} btn=${!!btn}`);
      } else {
        // Tip is the layer origin: translation of its matrix (the center of a TapDot).
        const tip = { x: pointer.matrix[4], y: pointer.matrix[5] };
        const r = btn.bounds;
        const expected = SCREENS[b.screen][last.target];
        const same = Math.abs(r.x - expected.x) <= TOL && Math.abs(r.y - expected.y) <= TOL && Math.abs(r.width - expected.width) <= TOL && Math.abs(r.height - expected.height) <= TOL;
        check(`${tag} btn-${last.target} bounds equal SCREENS.${b.screen}.${last.target}`, same, `bounds ${fmt(r.x)},${fmt(r.y)} ${fmt(r.width)}x${fmt(r.height)}`);
        check(`${tag} pointer tip inside btn-${last.target}`, within(tip, r) && within(tip, expected), `tip ${fmt(tip.x)},${fmt(tip.y)} in ${fmt(r.x)},${fmt(r.y)} ${fmt(r.width)}x${fmt(r.height)}`);
        if ((last.device ?? b.device) !== 'iphone' && expected.height >= MIN_BOX_HEIGHT) {
          // Whole arrow (full layer bounds) at rest stays inside the target button.
          const pb = pointer.bounds;
          const slack = Math.max(r.x - pb.x, r.y - pb.y, pb.x + pb.width - (r.x + r.width), pb.y + pb.height - (r.y + r.height));
          check(`${tag} pointer bounds inside btn-${last.target} (tolerance ${BOX_TOL} px)`, slack <= BOX_TOL, `pointer ${fmt(pb.x)},${fmt(pb.y)} ${fmt(pb.width)}x${fmt(pb.height)} in ${fmt(r.x)},${fmt(r.y)} ${fmt(r.width)}x${fmt(r.height)} (worst overshoot ${fmt(slack)})`);
        }
        for (const l of b.labels ?? []) {
          if (l.kind !== 'bad') continue;
          const bad = find(layers, `btn-${l.target}`);
          if (!bad) {
            check(`${tag} btn-${l.target} exists`, false, 'absent');
            continue;
          }
          const t = bad.bounds;
          const s = SCREENS[b.screen][l.target];
          check(`${tag} pointer tip not inside btn-${l.target}`, !within(tip, t) && !within(tip, s), `tip ${fmt(tip.x)},${fmt(tip.y)} vs ${l.target} ${fmt(t.x)},${fmt(t.y)} ${fmt(t.width)}x${fmt(t.height)}`);
        }
      }
    } else if (b.hidePointer) {
      // hidePointer: the pointer has faded out 8 frames into the beat, so it is gone at the end of it.
      const fade = find(layers, 'pointer-fade');
      check(`${tag} pointer hidden (hidePointer)`, !!fade && fade.opacity === 0, `pointer-fade opacity ${fade ? fade.opacity : 'absent'}`);
    } else if (!c.runs.some((r) => frame >= r.cues[0].from && frame < r.to)) {
      // No step and no pointer run on screen: the pointer must be hidden. (Inside a run it stays where it was.)
      const fade = find(layers, 'pointer-fade');
      check(`${tag} pointer hidden`, !pointer || pointer.opacity === 0 || (fade && fade.opacity === 0), `pointer-fade opacity ${fade ? fade.opacity : 'absent'}`);
    }

    const wants = new Set((b.labels ?? []).map((l) => l.target));
    for (const target of labelTargets) {
      const line = find(layers, `callout-${target}-line`);
      if (wants.has(target)) {
        const btn = find(layers, `btn-${target}`);
        if (!line || !btn) {
          check(`${tag} callout-${target}-line and btn-${target} exist`, false, `line=${!!line} btn=${!!btn}`);
          continue;
        }
        const dy = Math.abs(cy(line.bounds) - cy(btn.bounds));
        check(`${tag} callout-${target}-line center y equals btn-${target} center y`, dy <= TOL, `line ${fmt(cy(line.bounds))} vs button ${fmt(cy(btn.bounds))} (diff ${fmt(dy)})`);
      } else {
        check(`${tag} no callout-${target}-line`, !line, line ? 'present' : 'absent');
      }
    }
  });

  if (spec.n === 18) {
    // The same six digits on both devices: the Mac panel's text and the iPhone page's text, in the last frame of beats 3 and 4.
    for (const i of [3, 4]) {
      const frame = c.timeline[i].to - 5;
      const layers = inspect(comp, frame);
      const mac = find(layers, 'pair-code-text')?.text?.text;
      const phone = find(layers, 'phone-pair-code')?.text?.text;
      check(`${comp} beat ${i} f${frame} both devices show the same code`, mac !== undefined && mac === phone && /^\d{6}$/.test(mac), `Mac ${mac} iPhone ${phone}`);
    }
  }

  if (wantMp4 && !wholeFilm) checkMp4(comp, seconds, sceneFrames(spec.n), `scene ${spec.n}`);
}

if (wantMp4 && wholeFilm) {
  const total = SCENES.reduce((sum, spec) => sum + sceneEntry(spec.n).seconds, 0);
  checkMp4('Main', total, FILM_FRAMES, 'all scenes');
}

console.log(results.join('\n'));
console.log(failed ? '\nFAILED' : `\nall ${results.length} checks passed`);
process.exit(failed ? 1 : 0);
