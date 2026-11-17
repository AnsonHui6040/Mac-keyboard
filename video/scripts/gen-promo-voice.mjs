// Narration audio for the v0.2 promo film.
//   node scripts/gen-promo-voice.mjs measure
//   node scripts/gen-promo-voice.mjs generate <id> [--dry-run]
// The API key comes from env ELEVENLABS_API_KEY or the macOS Keychain (service ELEVENLABS_KEYCHAIN_SERVICE, default ELEVENLABS_API_KEY).
// The key is only ever passed to curl on stdin; it is never printed, logged or written.
import { execFileSync, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { appendFileSync, existsSync, mkdtempSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = fileURLToPath(new URL('..', import.meta.url));
const VOICE_DIR = join(ROOT, 'public/voice/promo');
const LOG = join(VOICE_DIR, 'requests.log');
const MANIFEST = join(ROOT, 'src/promo/voice-manifest.json');
const IDS = ['01', '02', '03', '04', '05', '06', '07', '08', '09', '10'];
const PAUSE_IDS = new Set(['03', '05', '07', '08']);
const VOICE = 'r6qgCCGI7RWKXCagm158';
const MODEL = 'eleven_v4';

const round3 = (n) => Math.round(n * 1000) / 1000;
const sha = (path) => createHash('sha256').update(readFileSync(path)).digest('hex');
const mp3 = (id) => join(VOICE_DIR, `${id}.mp3`);

const seconds = (path) =>
  round3(Number(execFileSync('ffprobe', ['-v', 'error', '-show_entries', 'format=duration', '-of', 'default=nw=1:nk=1', path], { encoding: 'utf8' }).trim()));

const firstPause = (path) => {
  const r = spawnSync('ffmpeg', ['-hide_banner', '-nostats', '-i', path, '-af', 'silencedetect=noise=-35dB:d=0.08', '-f', 'null', '-'], { encoding: 'utf8' });
  const starts = [...(r.stderr ?? '').matchAll(/silence_start:\s*(-?[0-9.]+)/g)].map((m) => Number(m[1]));
  const t = starts.find((s) => s > 0.3);
  return t === undefined ? null : round3(t);
};

function measure() {
  const out = {};
  for (const id of IDS) {
    out[id] = { seconds: seconds(mp3(id)), sha256: sha(mp3(id)), firstPause: PAUSE_IDS.has(id) ? firstPause(mp3(id)) : null };
  }
  // Integer-like keys such as "10" jump to the front of a JS object, so the file is written by hand to keep 01..10 in order.
  const text = '{\n' + IDS.map((id) => `  "${id}": ${JSON.stringify(out[id], null, 2).replaceAll('\n', '\n  ')}`).join(',\n') + '\n}\n';
  writeFileSync(MANIFEST, text);
  console.log(text);
}

function requestBody(narration, id) {
  const i = narration.findIndex((n) => n.id === id);
  if (i < 0) throw new Error(`unknown id ${id}`);
  const body = {
    text: narration[i].spoken,
    model_id: MODEL,
    language_code: 'zh',
    voice_settings: { stability: 0.5, similarity_boost: 0.75, style: 0.2, use_speaker_boost: true },
  };
  if (i > 0) body.previous_text = narration[i - 1].spoken;
  if (i < narration.length - 1) body.next_text = narration[i + 1].spoken;
  return body;
}

function readKey() {
  const env = process.env.ELEVENLABS_API_KEY;
  if (env && env.trim()) return env.trim();
  const service = process.env.ELEVENLABS_KEYCHAIN_SERVICE || 'ELEVENLABS_API_KEY';
  try {
    const k = execFileSync('security', ['find-generic-password', '-s', service, '-w'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
    return k || null;
  } catch {
    return null;
  }
}

async function generate(id, dryRun) {
  if (!IDS.includes(id)) throw new Error(`id must be one of ${IDS.join(', ')}`);
  const { NARRATION } = await import('../src/promo/narration.ts');
  const body = requestBody(NARRATION, id);
  if (dryRun) {
    console.log(JSON.stringify(body, null, 2));
    console.log(`output: ${mp3(id)}`);
    return;
  }
  const key = readKey();
  if (!key) {
    console.error('no ElevenLabs API key found (set ELEVENLABS_API_KEY or add it to the Keychain)');
    process.exit(1);
  }
  const dir = mkdtempSync(join(tmpdir(), 'promo-voice-'));
  try {
    const bodyFile = join(dir, 'body.json');
    const headFile = join(dir, 'headers.txt');
    const outFile = join(dir, `${id}.mp3`);
    writeFileSync(bodyFile, JSON.stringify(body));
    const r = spawnSync('curl', ['-sS', '--fail-with-body', '-X', 'POST', `https://api.elevenlabs.io/v1/text-to-speech/${VOICE}?output_format=mp3_44100_128`,
      '-H', '@-', '-H', 'Content-Type: application/json', '-H', 'Accept: audio/mpeg', '--data-binary', `@${bodyFile}`, '-D', headFile, '-o', outFile],
      { input: `xi-api-key: ${key}\n`, encoding: 'utf8' });
    if (r.status !== 0) {
      console.error(`request failed (curl exit ${r.status}): ${String(r.stderr).replaceAll(key, '***').slice(0, 300)}`);
      process.exit(1);
    }
    const headers = readFileSync(headFile, 'utf8');
    const requestId = /^request-id:\s*(\S+)/im.exec(headers)?.[1] ?? '-';
    renameSync(outFile, mp3(id));
    const now = new Date().toISOString().replace(/\.\d+Z$/, 'Z');
    const row = [id, requestId, now, MODEL, VOICE, 'zh', sha(mp3(id)), '-'].join('\t');
    const lines = readFileSync(LOG, 'utf8').split('\n');
    const cut = lines.findIndex((l) => l.startsWith('# replaced'));
    const live = (cut < 0 ? lines : lines.slice(0, cut)).filter((l) => l !== '');
    const old = (cut < 0 ? [] : lines.slice(cut + 1)).filter((l) => l !== '');
    const at = live.findIndex((l) => l.startsWith(`${id}\t`));
    if (at >= 0) old.push(live[at]);
    const next = at >= 0 ? live.map((l, i) => (i === at ? row : l)) : [...live, row];
    writeFileSync(LOG, [...next, '# replaced', ...old].join('\n') + '\n');
    console.log(`wrote ${mp3(id)}; approved is '-' until the user has listened`);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
  measure();
}

const [cmd, arg, flag] = process.argv.slice(2);
if (cmd === 'measure') measure();
else if (cmd === 'generate' && arg) await generate(arg, flag === '--dry-run');
else {
  console.error('usage: gen-promo-voice.mjs measure | generate <id> [--dry-run]');
  process.exit(2);
}
