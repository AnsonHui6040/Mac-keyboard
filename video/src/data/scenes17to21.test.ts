import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { SCREENS, type Rect } from '../screens/geometry.ts';
import { FPS, SCENES, compileRegistered, sceneEntry } from './scenes/index.ts';
import { scene17 } from './scenes/scene17.ts';
import { scene18 } from './scenes/scene18.ts';
import { scene19 } from './scenes/scene19.ts';
import { scene20 } from './scenes/scene20.ts';
import { scene21 } from './scenes/scene21.ts';
import { CODE_LEFT, FOCUS_LINE, PAIR_CODE, REMAINING_LINE, WAIT_LEFT } from './pairing.ts';
import { TYPED_20, TYPE20_PITCH, TYPE20_START, CONNECT_AT, typed20 } from '../screens/typing20.ts';
import { DAYS, MARKED_DAYS, MARK_PITCH, MARK_START, cellRect, CARD } from '../screens/calendar.ts';
import { PANEL17, PANEL18, MENU_ICON, MENUBAR_H, PANEL_W } from '../screens/layouts.ts';
import { STAGE_BOTTOM } from '../screens/geometry.ts';
import { PHONE_ORIGIN_RIGHT } from '../screens/phone.ts';
import { pointerAt } from '../lib/pointer.ts';

const read = (f: string) => readFileSync(new URL(f, import.meta.url), 'utf8');
const inside = (p: { x: number; y: number }, r: Rect) => p.x >= r.x && p.x <= r.x + r.width && p.y >= r.y && p.y <= r.y + r.height;
const within = (a: Rect, b: Rect) => a.x >= b.x && a.y >= b.y && a.x + a.width <= b.x + b.width && a.y + a.height <= b.y + b.height;

test('the pairing code is 482915 and both devices draw it from the same constant; no other six-digit literal is drawn', () => {
  assert.equal(PAIR_CODE, '482915');
  const mac = read('../screens/macReceiver.tsx');
  const phone = read('../screens/phonePages3.tsx');
  // the Mac panel's code and the iPhone page's code are both {PAIR_CODE}
  assert.match(mac, /id="pair-code-text"[^>]*>\{PAIR_CODE\}</);
  assert.match(phone, /id="phone-pair-code"[^>]*>\{PAIR_CODE\}</);
  for (const [name, src] of [['macReceiver.tsx', mac], ['phonePages3.tsx', phone]]) assert.equal([...src.matchAll(/['"`>]\d{6}['"`<]/g)].length, 0, name);
});

test('the countdown text is 剩餘 mm:ss with fixed values, and the panel line says 文字編輯（可輸入）', () => {
  assert.match(WAIT_LEFT, /^剩餘 \d\d:\d\d$/);
  assert.match(CODE_LEFT, /^剩餘 \d\d:\d\d$/);
  assert.match(REMAINING_LINE, /^剩餘接收時間 \d\d:\d\d$/);
  assert.equal(FOCUS_LINE, '目前欄位：文字編輯（可輸入）');
});

test('no scene source names a real app (Claude2) or a real device name', () => {
  const bad = ['Claude' + '2'];
  const dirs = ['../screens/', '../components/', './scenes/'];
  for (const d of dirs) {
    for (const f of readdirSync(new URL(d, import.meta.url))) {
      if (!/\.(ts|tsx)$/.test(f) || f.endsWith('.test.ts')) continue;
      const src = read(d + f);
      for (const w of bad) assert.ok(!src.includes(w), `${d}${f} has ${w}`);
    }
  }
});

test('scene 17: Bluetooth 允許, the menu bar icon, 授權輔助使用, the switch; all on the Mac', () => {
  assert.deepEqual(scene17.beats.map((b) => b.device), ['mac', 'mac', 'mac']);
  assert.deepEqual(scene17.beats.map((b) => b.steps?.map((s) => s.target)), [['allow'], ['icon', 'authorize'], ['toggle']]);
  assert.ok(scene17.beats.every((b) => b.steps!.every((s) => s.press)));
});

test('scene 18 follows the manual: Mac 配對新 iPhone; iPhone 已配對 Mac, 配對 Mac; the code on both; Mac 確認, then iPhone 確認', () => {
  assert.deepEqual(scene18.beats.map((b) => b.device), ['mac', 'mac', 'iphone', undefined, 'mac']);
  assert.deepEqual(scene18.beats.map((b) => b.steps?.map((s) => [s.target, s.device ?? b.device])), [
    undefined,
    [['pairNew', 'mac']],
    [['phoneRow', 'iphone'], ['pairMac', 'iphone']],
    undefined,
    [['macConfirm', 'mac'], ['phoneConfirm', 'iphone']],
  ]);
  const c = compileRegistered(scene18);
  // the tag and pointer follow the device in the last beat: Mac in the first half, iPhone in the second
  const { from, to } = c.timeline[4];
  assert.equal(c.deviceAt(from + 2), 'mac');
  assert.equal(c.deviceAt(to - 2), 'iphone');
  assert.equal(c.deviceAt(c.timeline[3].from + 2), undefined);
  assert.deepEqual(c.runs.map((r) => r.device), ['mac', 'iphone', 'mac', 'iphone']);
});

test('scene 19: 已儲存 on both, 完成 on the Mac and then on the iPhone, in one beat', () => {
  assert.equal(scene19.beats.length, 1);
  assert.deepEqual(scene19.beats[0].steps!.map((s) => [s.target, s.device ?? scene19.beats[0].device]), [['macDone', 'mac'], ['phoneDone', 'iphone']]);
  const c = compileRegistered(scene19);
  const { from, to } = c.timeline[0];
  assert.deepEqual(c.runs.map((r) => r.device), ['mac', 'iphone']);
  assert.equal(c.deviceAt(from + 2), 'mac');
  assert.equal(c.deviceAt(to - 2), 'iphone');
});

test('scene 20 order: the Mac document first, then the iPhone field, the globe key, Remote Keyboard, 遠端; the last beat has no steps', () => {
  assert.deepEqual(scene20.beats.map((b) => b.device), ['mac', 'iphone', 'iphone', undefined]);
  assert.deepEqual(scene20.beats.flatMap((b) => b.steps?.map((s) => s.target) ?? []), ['doc', 'field', 'globe', 'rk', 'remote']);
  assert.equal(scene20.beats[3].steps, undefined);
});

test('scene 20 types the whole sentence on the Mac before the last beat ends, after 已連接 shows', () => {
  const c = compileRegistered(scene20);
  const len = c.timeline[3].to - c.timeline[3].from;
  assert.equal(typed20(0), 0);
  assert.equal(typed20(len - 1), TYPED_20.length);
  assert.ok(CONNECT_AT < TYPE20_START);
  assert.ok(TYPE20_START + TYPE20_PITCH * (TYPED_20.length - 1) + 10 < len, 'the last letter has time to be seen');
  assert.match(TYPED_20, /^[A-Za-z ]+$/);
});

test('scene 21 has no device and no pointer; the calendar marks 7 days', () => {
  assert.ok(scene21.beats.every((b) => !b.device && !b.steps));
  const c = compileRegistered(scene21);
  assert.equal(c.runs.length, 0);
  assert.equal(MARKED_DAYS, 7);
  assert.equal(DAYS, 31);
  // all seven are marked before the first beat ends, with time to see them
  assert.ok(MARK_START + MARK_PITCH * (MARKED_DAYS - 1) + 6 + 20 < c.timeline[0].to - c.timeline[0].from);
  // the calendar and its cells stay inside the card, above the subtitle divider
  for (let d = 1; d <= DAYS; d++) assert.ok(within(cellRect(d), CARD), `day ${d}`);
  assert.ok(CARD.y + CARD.height < STAGE_BOTTOM);
});

test('scenes 17 to 21 are registered with the script lengths, and their screens fit above the divider and clear of the phone', () => {
  for (const n of [17, 18, 19, 20, 21]) assert.ok(SCENES.some((s) => s.n === n), `scene ${n}`);
  assert.equal([17, 18, 19, 20, 21].map((n) => sceneEntry(n).seconds).join(','), '16,21,8,17,12');
  assert.ok(PANEL17.rect.y + PANEL17.rect.height < STAGE_BOTTOM);
  assert.ok(PANEL17.rect.x + PANEL17.rect.width <= 1920 && PANEL17.rect.y >= MENUBAR_H);
  // the panel hangs under the icon: its right edge reaches past the icon's, its top is just under the bar
  assert.ok(PANEL17.rect.x + PANEL_W > MENU_ICON.x + MENU_ICON.width);
  const phoneLeft = PHONE_ORIGIN_RIGHT.x - 14;
  for (const [k, p] of Object.entries(PANEL18)) {
    assert.ok(p.rect.y + p.rect.height < STAGE_BOTTOM, k);
    assert.ok(p.rect.x + p.rect.width < phoneLeft - 40, k);
    for (const [name, b] of Object.entries(p.buttons)) assert.ok(within(b, p.rect), `${k}.${name}`);
  }
  for (const [name, b] of Object.entries(PANEL17.buttons)) assert.ok(within(b, PANEL17.rect), `panel17.${name}`);
});

test('the pointer is inside its target just before each step slot ends, in scenes 17 to 20 (every step, not only the last)', () => {
  for (const spec of [scene17, scene18, scene19, scene20]) {
    const c = compileRegistered(spec);
    spec.beats.forEach((b, i) => {
      const steps = b.steps ?? [];
      const slot = steps.length > 0 ? Math.floor((c.timeline[i].to - c.timeline[i].from) / steps.length) : 0;
      steps.forEach((step, k) => {
        // 10 frames before the slot ends: after the press, before the run fades out
        const frame = c.timeline[i].from + (k + 1) * slot - 10;
        const run = c.runs.find((r) => r.device === (step.device ?? b.device) && r.from <= frame && r.to > frame);
        assert.ok(run, `scene ${spec.n} beat ${i} step ${k} has a run`);
        const p = pointerAt(frame, run!.cues, FPS);
        assert.ok(inside(p, SCREENS[b.screen][step.target]), `scene ${spec.n} beat ${i} ${step.target}`);
      });
    });
  }
});

test('button ids are unique per screen: the two confirm buttons and the two done buttons have their own target names', () => {
  assert.ok(SCREENS.pairFlow.macConfirm && SCREENS.pairFlow.phoneConfirm && SCREENS.pairDone.macDone && SCREENS.pairDone.phoneDone);
  assert.ok(!('confirm' in SCREENS.pairFlow) && !('done' in SCREENS.pairDone));
});
