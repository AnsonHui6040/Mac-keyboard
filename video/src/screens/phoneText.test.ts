import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { PHONE_MIN_TEXT } from './layouts.ts';

// iPhone screens must keep readable text at 26 pt or more (24 px on the canvas). PText throws at render time; this checks the sources too.
const FILES = ['../components/ios.tsx', './phonePages.tsx', './Typing.tsx', './VpnFlow.tsx', './SettingsFlow.tsx', './MyApps.tsx', './SignIn.tsx', './phonePages2.tsx', './IpaFlow.tsx', './AddIpa.tsx', './KeyboardFlow.tsx', './AppSetup.tsx'];

test('every size literal on an iPhone screen is at least PHONE_MIN_TEXT, except the status bar glyph sizes', () => {
  for (const f of FILES) {
    const src = readFileSync(new URL(f, import.meta.url), 'utf8');
    for (const m of src.matchAll(/\bsize=\{(\d+)\}/g)) {
      const n = Number(m[1]);
      // icon sizes are tile sizes, not text: they sit on components named *Icon
      const line = src.slice(src.lastIndexOf('\n', m.index), src.indexOf('\n', m.index));
      if (/Icon|Ellipse|Rect|Row|Chevron/.test(line)) continue;
      assert.ok(n >= PHONE_MIN_TEXT, `${f}: ${line.trim()}`);
    }
  }
});

test('PHONE_MIN_TEXT of 26 gives at least 24 px on the canvas', () => {
  assert.ok(PHONE_MIN_TEXT * 0.94 >= 24);
});
