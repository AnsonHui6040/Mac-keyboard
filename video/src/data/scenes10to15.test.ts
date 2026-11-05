import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { SCREENS, restPoint, type Rect } from '../screens/geometry.ts';
import { FPS, compileRegistered, sceneEntry } from './scenes/index.ts';
import { scene10 } from './scenes/scene10.ts';
import { scene11 } from './scenes/scene11.ts';
import { scene12 } from './scenes/scene12.ts';
import { scene14 } from './scenes/scene14.ts';
import { scene15 } from './scenes/scene15.ts';
import { IPA_NAME, ZIP_NAME, IPA_SHA256, ZIP_SHA256, RELEASE_URL, SIDESTORE_URL, SIGNIN_CODE } from './artifacts.ts';
import { PAIR_CODE } from './pairing.ts';
import { commandText, outputAt } from '../screens/terminal.ts';
import { CODE_LENGTH, CODE_PITCH, CODE_START, typedDigits } from '../screens/signinCode.ts';
import { scene05 } from './scenes/scene05.ts';
import { pointerAt } from '../lib/pointer.ts';
import { fitSize } from '../screens/extensionFit.ts';

const inside = (p: { x: number; y: number }, r: Rect) => p.x >= r.x && p.x <= r.x + r.width && p.y >= r.y && p.y <= r.y + r.height;

test('the SHA-256 values are 64 hex characters and equal the design document', () => {
  const doc = readFileSync(new URL('../../../docs/superpowers/specs/2026-11-04-install-tutorial-video-design.md', import.meta.url), 'utf8');
  for (const [name, sha] of [[IPA_NAME, IPA_SHA256], [ZIP_NAME, ZIP_SHA256]]) {
    assert.match(sha, /^[0-9a-f]{64}$/);
    assert.ok(doc.includes(`${name}\`）為 \`${sha}\``) || doc.includes(sha), name);
  }
  assert.equal(IPA_NAME, 'RemoteKeyboard-v0.1.0-unsigned.ipa');
  assert.equal(ZIP_NAME, 'RemoteKeyboardReceiver-v0.1.0-macOS.zip');
});

test('scene 10: the Release page, 終端機 with both hashes on screen for at least 6 s, then AirDrop on the Mac and 儲存到「檔案」 on the iPhone', () => {
  assert.deepEqual(scene10.beats.map((b) => b.screen), ['ipaDownload', 'ipaVerify', 'ipaSend']);
  assert.deepEqual(scene10.beats.map((b) => b.steps?.map((s) => [s.target, s.device ?? b.device])), [[['ipadl', 'mac']], [['hash', 'mac']], [['airdrop', 'mac'], ['save', 'iphone']]]);
  const c = compileRegistered(scene10);
  assert.equal(c.deviceAt(0), 'mac');
  assert.equal(c.deviceAt(c.timeline[2].from + 5), 'mac');
  assert.equal(c.deviceAt(c.timeline[2].to - 5), 'iphone');
  // the command is typed, the output shows, and from then on the command and both hashes stay to the end of the beat
  const len = c.timeline[1].to - c.timeline[1].from;
  const visible = len - outputAt(commandText(IPA_NAME).length);
  assert.ok(visible >= 6 * FPS, `${visible} frames`);
  assert.ok(scene10.beats[1].minSeconds && scene10.beats[1].minSeconds * FPS - outputAt(commandText(IPA_NAME).length) >= 6 * FPS);
});

test('scene 15: the hash is on screen for at least 4 s on the terminal page, which is the page between the second and the third step', () => {
  const c = compileRegistered(scene15);
  const t = c.stepTimes[1];
  const visible = (t[2].start - t[1].start) - outputAt(commandText(ZIP_NAME).length);
  assert.ok(visible >= 4 * FPS, `${visible} frames`);
});

test('the address bars: Release page, iloader download page, and the terminal title are the ones of the brief', () => {
  assert.equal(RELEASE_URL, 'github.com/AnsonHui6040/Mac-keyboard/releases/tag/v0.1.0-alpha.1');
  assert.equal(SIDESTORE_URL, 'sidestore.io');
  const mac = readFileSync(new URL('../screens/macPages.tsx', import.meta.url), 'utf8');
  assert.match(mac, /title="github\.com" address=\{RELEASE_URL\}/);
  assert.match(mac, /address=\{SIDESTORE_URL\}/);
  assert.match(mac, /title="終端機"/);
  assert.ok(!mac.includes('Downloads — zsh'));
});

test('scene 5: sidestore.io first (press the download button, then the iloader window), a verification code beat, then Stable SideStore', () => {
  assert.deepEqual(scene05.beats.map((b) => b.steps?.map((s) => s.target)), [['idl', 'open'], ['trust'], ['add', 'signin'], ['code'], ['device', 'stable']]);
  assert.deepEqual(scene05.beats.map((b) => b.device), ['mac', 'iphone', 'mac', 'mac', 'mac']);
  assert.equal(scene05.beats[0].steps![0].press, true);
  const c = compileRegistered(scene05);
  // the pointer is on the code field before the first digit, and the last digit is typed with time to read the whole code before the beat ends
  const land = c.stepTimes[3][0].land;
  const len = c.timeline[3].to - c.timeline[3].from;
  assert.equal(typedDigits(CODE_START - 1), 0);
  assert.equal(typedDigits(CODE_START), 1);
  assert.equal(typedDigits(CODE_START + CODE_PITCH * (CODE_LENGTH - 1)), CODE_LENGTH);
  assert.ok(land + CODE_START + CODE_PITCH * (CODE_LENGTH - 1) + 30 <= len, 'six digits and a second to read them');
});

test('the verification code of scene 5 is fictional, six digits, and not the pairing code', () => {
  assert.match(SIGNIN_CODE, /^\d{6}$/);
  assert.notEqual(SIGNIN_CODE, PAIR_CODE);
  const src = readFileSync(new URL('../screens/Iloader.tsx', import.meta.url), 'utf8');
  assert.equal([...src.matchAll(/['"`>]\d{6}['"`<]/g)].length, 0);
});

test('scene 11: the second option is good, Remove is bad; both labels together at least 3 s; the dialog is not pressed before beat 4 and the pointer never rests on Remove', () => {
  const both = scene11.beats.filter((b) => b.labels?.some((l) => l.kind === 'bad'));
  assert.equal(both.length, 1);
  assert.deepEqual(both[0].labels, [{ target: 'keepEach', kind: 'good' }, { target: 'remove', kind: 'bad' }]);
  const c = compileRegistered(scene11);
  const i = scene11.beats.indexOf(both[0]);
  assert.ok((c.timeline[i].to - c.timeline[i].from) / FPS >= 3);
  assert.equal(both[0].minSeconds && both[0].minSeconds >= 3, true);
  for (const b of scene11.beats.slice(1, 4)) assert.ok(b.steps?.every((s) => s.target === 'keepEach' && !s.press));
  // beat 4: the Register option is pressed, then My Apps lists Remote Keyboard and the pointer goes to its icon; no label there
  assert.deepEqual(scene11.beats[4].steps, [{ target: 'keepEach', press: true }, { target: 'rkapp' }]);
  assert.equal(scene11.beats[4].labels, undefined);
  assert.equal(scene11.beats.length, 5);
  for (let f = c.timeline[1].from; f < c.timeline[3].to; f++) {
    const p = pointerAt(f, c.cues, FPS);
    assert.ok(!inside(p, SCREENS.extDialog.remove), `frame ${f}`);
  }
  const end = pointerAt(c.timeline[3].to - 5, c.cues, FPS);
  const r = restPoint(SCREENS.extDialog.keepEach);
  assert.ok(Math.abs(end.x - r.x) < 1 && Math.abs(end.y - r.y) < 1);
  // the two Keep labels stay on one line: the longer one is shrunk below the other
  assert.ok(fitSize(26.95) < fitSize(18.47));
});

test('the dialog buttons run in the document order, top to bottom, with room for neighbouring rings', () => {
  const d = SCREENS.extDialog;
  const order = ['keepMain', 'keepEach', 'remove', 'choose', 'cancel'];
  assert.deepEqual(Object.keys(d), [...order, 'rkapp']);
  for (let k = 1; k < order.length; k++) assert.ok(d[order[k]].y - (d[order[k - 1]].y + d[order[k - 1]].height) >= 20);
});

test('scene 12 and 14 raised their seconds by at most 3 over the first script (13 and 12)', () => {
  assert.ok(sceneEntry(12).seconds - 13 >= 0 && sceneEntry(12).seconds - 13 <= 3);
  assert.ok(sceneEntry(14).seconds - 12 >= 0 && sceneEntry(14).seconds - 12 <= 3);
  assert.equal(scene12.beats[0].steps?.length, 5);
  assert.equal(scene14.beats[0].steps?.filter((s) => s.target === 'next').length, 4);
});

test('scene 15: the drag has no press step, the pointer then clicks 應用程式 and double clicks Remote Keyboard Receiver there', () => {
  const steps = scene15.beats[2].steps!;
  assert.deepEqual(steps.map((s) => [s.target, !!s.press]), [['receiver', false], ['apps', false], ['apps', true], ['rkapp', true]]);
  const c = compileRegistered(scene15);
  const end = pointerAt(c.timeline[2].to - 5, c.cues, FPS);
  assert.ok(inside(end, SCREENS.zipFlow.rkapp));
  // the drop lands on 應用程式
  const t = c.stepTimes[2];
  const drop = pointerAt(c.timeline[2].from + t[1].land, c.cues, FPS);
  assert.ok(inside(drop, SCREENS.zipFlow.apps));
  assert.equal(scene15.beats[0].steps, undefined);
  // the double click on the app: the second ring comes 10 frames after the first and the app has bounced before the beat ends
  assert.ok(t[3].land + 10 + 14 < c.timeline[2].to - c.timeline[2].from);
});
