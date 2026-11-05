import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { SCREENS, STAGE_BOTTOM } from './geometry.ts';
import { PHONE_BEZEL, PHONE_ORIGIN } from './phone.ts';
import { INSET_CARD, INSET_LEADER, INSET_LINES, INSET_SIZE, INSET_WEIGHT } from './extensionInset.ts';
import { theme } from '../theme.ts';

const phoneBody = { left: PHONE_ORIGIN.x - PHONE_BEZEL };
const row = SCREENS.extDialog.keepEach;

test('the inset is two lines, Medium weight, 30 px or larger', () => {
  assert.deepEqual([...INSET_LINES], ['Keep App Extensions', '(Register App ID for Each Extension)']);
  assert.ok(INSET_SIZE >= 30);
  assert.equal(INSET_WEIGHT, 500);
});

test('the inset card lies inside the canvas, left of the phone, below the device tag and above the subtitle divider', () => {
  const c = INSET_CARD;
  assert.ok(c.x >= 0 && c.y >= 0 && c.x + c.width <= 1920 && c.y + c.height <= 1080);
  assert.ok(c.x >= theme.divider.x, 'inside the 72 px stage margin');
  assert.ok(c.x + c.width < phoneBody.left, 'does not touch the phone, bezel included');
  assert.ok(c.x - 2.5 >= 72 && c.x + c.width + 2.5 <= 700, 'ring stroke included, in the free area x 72 to 700');
  // the device tag is drawn from (72, 72) at 30 px, so its box ends at 72 + 30 * 1.5 and is no wider than 220 px
  const tag = { x: theme.deviceTag.x, y: theme.deviceTag.y, width: 220, height: theme.deviceTag.size * 1.5 };
  const overlapsTag = c.x < tag.x + tag.width && c.x + c.width > tag.x && c.y < tag.y + tag.height && c.y + c.height > tag.y;
  assert.ok(!overlapsTag, 'does not overlap the device tag');
  assert.ok(c.y + c.height < theme.divider.y && c.y + c.height < STAGE_BOTTOM, 'above the subtitle divider (y=884)');
});

test('the leader line runs from the card to the left edge of the row ring, level with the row center', () => {
  const l = INSET_LEADER;
  assert.equal(l.x1, INSET_CARD.x + INSET_CARD.width);
  assert.equal(l.x2, row.x - theme.callout.ringGap);
  assert.ok(l.x2 > l.x1);
  assert.equal(l.y, row.y + row.height / 2);
  assert.ok(l.y > INSET_CARD.y && l.y < INSET_CARD.y + INSET_CARD.height);
  assert.ok(l.width <= 4, 'thin');
});

test('the inset does not add words, arrows or separators beyond the option text', () => {
  const src = readFileSync(new URL('./extensionInset.tsx', import.meta.url), 'utf8');
  assert.ok(!/[→←↑↓▶►]| · /.test(src));
});
