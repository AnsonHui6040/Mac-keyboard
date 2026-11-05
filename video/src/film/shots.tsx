/** The close-up shots: for each one the camera on the slab, where it looks, and how it drifts. The 3D shots are Stage.tsx. */
import type { ReactNode } from 'react';
import { Layer } from '@kinetographdev/core';
import { KB } from '../intro/layout.ts';
import { MacScreen, caretAt } from './MacScreen.tsx';
import { PHONE_TOP, PhoneScreen } from './PhoneScreen.tsx';
import { PhoneRings } from './Fingers.tsx';
import { Slab, type SlabParams } from './Slab.tsx';
import { DOC, LOGIN_FIELDS, MAC, centerOf, kbTop, keyRect } from './layout.ts';
import { draftCaretX, fingerAt, macAt, phoneAt } from './state.ts';
import { shotById } from './timeline.ts';

type Pt = { x: number; y: number };
const smooth = (u: number): number => { const t = Math.min(1, Math.max(0, u)); return t * t * (3 - 2 * t); };
/** Piecewise smooth path through [frame, x, y] keys. */
const path = (keys: [number, number, number][], f: number): Pt => {
  if (f <= keys[0][0]) return { x: keys[0][1], y: keys[0][2] };
  for (let i = 1; i < keys.length; i++) {
    if (f <= keys[i][0]) {
      const u = smooth((f - keys[i - 1][0]) / (keys[i][0] - keys[i - 1][0]));
      return { x: keys[i - 1][1] + (keys[i][1] - keys[i - 1][1]) * u, y: keys[i - 1][2] + (keys[i][2] - keys[i - 1][2]) * u };
    }
  }
  const l = keys[keys.length - 1];
  return { x: l[1], y: l[2] };
};
/** Where the phone's finger has been around a frame, averaged so the camera glides instead of jumping from key to key. */
const finger = (f: number, r: number): Pt => {
  let x = 0; let y = 0; let n = 0;
  for (let k = f - r; k <= f + r; k++) {
    const g = fingerAt(k);
    if (g.visible) { x += g.x; y += g.y; n++; }
  }
  if (n === 0) { const g = fingerAt(f + 8); return { x: g.x, y: g.y }; }
  return { x: x / n, y: y / n };
};
const caret = (f: number, r: number, line?: number): Pt => {
  let x = 0; let y = 0;
  for (let k = f - r; k <= f + r; k++) {
    const m = macAt(k);
    const lines = line === undefined ? m.lines : m.lines.slice(0, line + 1);
    const c = caretAt(lines, m.screen === 'doc2');
    x += c.x; y += c.y;
  }
  return { x: x / (2 * r + 1), y: y / (2 * r + 1) };
};

const PHONE: SlabParams = { mag: 2.5, pitch: 40, roll: -9, yaw: 7, tx: 40, ty: 110, persp: 1300, focusH: 48 };
const MACP: SlabParams = { mag: 2.25, pitch: 34, roll: 7, yaw: -5, tx: -20, ty: 130, persp: 1350, focusH: 42 };
const withP = (b: SlabParams, o: Partial<SlabParams>): SlabParams => ({ ...b, ...o });

type Cfg = { dev: 'phone' | 'mac'; p: SlabParams; /** per frame drift of tx, ty, roll */ d: [number, number, number]; focus: (f: number, l: number) => Pt };
const DRAFT_Y = (kb: 'draft' | 'quick' | 'handwriting'): number => kbTop(kb) + KB[kb].rowY! + 26;
const pwField: Pt = { x: LOGIN_FIELDS.password.x + 300, y: LOGIN_FIELDS.password.y + 32 };
const line = (i: number): number => DOC.textY + i * DOC.pitch + DOC.pitch / 2;

const CFG: Record<string, Cfg> = {
  '2': { dev: 'phone', p: PHONE, d: [-0.5, 0.1, 0.02], focus: (f) => finger(f, 5) },
  '3': { dev: 'mac', p: withP(MACP, { mag: 3.0 }), d: [-0.5, 0, -0.02], focus: (f) => { const c = caret(f, 3); return { x: c.x - 40, y: c.y }; } },
  '4': { dev: 'phone', p: withP(PHONE, { mag: 2.6 }), d: [-0.5, 0.1, 0.02], focus: (f) => finger(f, 4) },
  '5': { dev: 'mac', p: withP(MACP, { mag: 3.0 }), d: [-0.5, 0, -0.02], focus: (f) => { const c = caret(f, 3); return { x: c.x - 40, y: c.y }; } },
  '6': { dev: 'phone', p: withP(PHONE, { mag: 2.0, pitch: 36, roll: -8, yaw: 6, tx: 80 }), d: [-0.9, 0.1, 0.02], focus: (f) => finger(f, 6) },
  '7': { dev: 'mac', p: withP(MACP, { mag: 1.6, pitch: 24, yaw: -4, focusH: 50 }), d: [-0.4, 0, -0.02], focus: (f) => { const c = caret(f, 7); return { x: c.x - 120, y: c.y }; } },
  '8': { dev: 'phone', p: withP(PHONE, { mag: 1.7, pitch: 26 }), d: [-0.6, -0.4, 0.02], focus: (f) => finger(f, 8) },
  '9': { dev: 'phone', p: withP(PHONE, { mag: 1.8, pitch: 34, roll: -8, yaw: 6, tx: 0, ty: -80, focusH: 36 }), d: [-0.4, 0.1, 0.02], focus: (f) => { const s = phoneAt(f); return { x: Math.min(draftCaretX('draft', s.draft, s.draft.length) , 520) - 50, y: DRAFT_Y('draft') }; } },
  '10': { dev: 'mac', p: withP(MACP, { mag: 1.7, pitch: 26, yaw: -4 }), d: [-0.4, 0, -0.02], focus: () => ({ x: 360, y: line(1) }) },
  '11': { dev: 'phone', p: withP(PHONE, { mag: 1.8, pitch: 34, ty: -80, focusH: 36 }), d: [-0.3, 0, 0.02], focus: (f) => {
    const row = DRAFT_Y('draft');
    const end = draftCaretX('draft', 'Chek before sending', 19) - 40;
    const gap = draftCaretX('draft', 'Chek before sending', 3);
    return path([[387, end, row], [409, gap + 20, row]], f);
  } },
  '12': { dev: 'phone', p: withP(PHONE, { mag: 1.75, pitch: 30, roll: -8, yaw: 6, ty: 80 }), d: [-0.5, 0, 0.02], focus: (f) => {
    const row = DRAFT_Y('draft');
    const end = draftCaretX('draft', 'Check before sending\n', 21);
    const enter = centerOf(keyRect('draft', 'enter'));
    const send = centerOf(keyRect('draft', 'send'));
    return path([[453, end - 120, row], [466, enter.x - 200, (row + enter.y) / 2], [478, send.x - 130, row + 20]], f);
  } },
  '13': { dev: 'mac', p: withP(MACP, { mag: 1.7, pitch: 26, yaw: -4 }), d: [-0.4, 0, -0.02], focus: () => ({ x: 380, y: line(1) }) },
  '14': { dev: 'phone', p: withP(PHONE, { mag: 2.4 }), d: [-0.5, 0.1, 0.02], focus: (f) => finger(f, 5) },
  '15': { dev: 'phone', p: withP(PHONE, { mag: 2.3, pitch: 34, roll: -8, yaw: 6, ty: 90, focusH: 60 }), d: [-0.3, 0, 0.015], focus: (f) => finger(f, 14) },
  '16': { dev: 'phone', p: withP(PHONE, { mag: 1.8, pitch: 28 }), d: [-0.4, 0, 0.02], focus: (f) => path([[651, 330, 440], [661, 330, 292], [671, 330, 292], [681, 600, 560], [691, 640, 260]], f) },
  '17': { dev: 'mac', p: withP(MACP, { mag: 2.0, pitch: 30, yaw: -4 }), d: [-0.4, 0, -0.02], focus: () => ({ x: 300, y: line(2) }) },
  '18': { dev: 'phone', p: withP(PHONE, { mag: 1.8, pitch: 30, ty: 70 }), d: [-0.5, 0, 0.02], focus: (f) => finger(f, 8) },
  '19': { dev: 'mac', p: withP(MACP, { mag: 1.15, pitch: 18, yaw: -3, ty: 90, focusH: 60 }), d: [-0.3, 0, -0.02], focus: () => ({ x: 460, y: 400 }) },
  '20': { dev: 'phone', p: withP(PHONE, { mag: 1.7, pitch: 34, ty: 30, pool: 1.8 }), d: [-0.5, 0.1, 0.02], focus: (f) => path([[825, 360, 215], [849, 360, 480]], f) },
  '22': { dev: 'mac', p: withP(MACP, { mag: 2.1, pitch: 32, focusH: 34 }), d: [-0.4, 0, -0.02], focus: () => ({ x: pwField.x - 40, y: pwField.y }) },
  '23': { dev: 'phone', p: withP(PHONE, { mag: 3.4, pitch: 36, ty: 120 }), d: [-0.4, 0, 0.02], focus: () => ({ x: 218, y: kbTop('connected') + 49 }) },
  '24': { dev: 'phone', p: withP(PHONE, { mag: 2.6 }), d: [-0.5, 0.1, 0.02], focus: (f) => finger(f, 4) },
  '25': { dev: 'mac', p: withP(MACP, { mag: 3.0 }), d: [-0.5, 0, -0.02], focus: () => ({ x: pwField.x - 40, y: pwField.y }) },
  '28': { dev: 'mac', p: withP(MACP, { mag: 1.45, pitch: 22, yaw: -4, focusH: 52 }), d: [-0.3, 0, -0.02], focus: (f) => path([[1362, 640, 130], [1372, 640, 130], [1398, 640, 438]], f) },
};
CFG['26'] = CFG['24'];
CFG['27'] = CFG['25'];

export const CloseShot = ({ id, f }: { id: string; f: number }) => {
  const shot = shotById(id);
  const c = CFG[id];
  const l = f - shot.from;
  const p: SlabParams = { ...c.p, tx: c.p.tx + c.d[0] * l, ty: c.p.ty + c.d[1] * l, roll: c.p.roll + c.d[2] * l };
  const at = c.focus(f, l);
  let body: ReactNode;
  if (c.dev === 'phone') {
    const state = phoneAt(f);
    body = (
      <Slab w={720} h={755} p={p} fx={at.x} fy={at.y - PHONE_TOP}
        overlay={<Layer y={-PHONE_TOP}><PhoneRings f={f} /></Layer>}>
        <Layer y={-PHONE_TOP}><PhoneScreen state={state} f={f} /></Layer>
      </Slab>
    );
  } else {
    body = (
      <Slab w={MAC.w} h={MAC.h} p={p} fx={at.x} fy={at.y}>
        <MacScreen f={f} />
      </Slab>
    );
  }
  return <>{body}</>;
};
