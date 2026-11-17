/**
 * The cut list of the v0.2 promo: which device is on screen from which frame, hard cuts only, covering 0 to FRAMES with no gap.
 * Every cut that shows a computer starts the frame its text lands (a key press plus MAC_DELAY). Pure: node can import it.
 */
import { HW_CANDIDATES_AT, MAC_DELAY, PRESSES } from './events.ts';
import { FRAMES, seg } from './timeline.ts';

export type Dev = 'phone' | 'mac' | 'win' | 'linux' | 'stage' | 'wide' | 'hero' | 'card';
export type Cut = { id: string; from: number; to: number; dev: Dev };

const press = (key: string, near: number): number => {
  const hit = PRESSES.filter((p) => p.key === key).sort((a, b) => Math.abs(a.t - near) - Math.abs(b.t - near))[0];
  if (!hit) throw new Error(`no press ${key}`);
  return hit.t;
};
const s2 = seg('2');
const s4 = seg('4');
/** The last typed letter of the live mode: its text lands on the Mac MAC_DELAY frames later. */
export const LIVE_LAST: number = Math.max(...PRESSES.filter((p) => p.fx.k === 'char' && p.t >= s2.from && p.t < press('toggle:draft', s2.from)).map((p) => p.t));
export const DRAFT_SEND: number = press('send', s2.to);
export const HW_SEND: number = press('send', s4.to);
const QUICK_SEND = press('send', seg('6').to);
const TOGGLE = press('toggle:draft', s2.from);

export const CUTS: readonly Cut[] = (() => {
  const c: Cut[] = [];
  const add = (id: string, dev: Dev, from: number, to: number): void => { c.push({ id, from, to, dev }); };
  add('1', 'hero', 0, seg('1').to);
  add('2a', 'phone', s2.from, LIVE_LAST + MAC_DELAY);
  add('2b', 'mac', LIVE_LAST + MAC_DELAY, TOGGLE - 2);
  add('2c', 'phone', TOGGLE - 2, DRAFT_SEND + MAC_DELAY);
  add('2d', 'mac', DRAFT_SEND + MAC_DELAY, s2.to);
  add('3', 'phone', seg('3').from, seg('3').to);
  add('4a', 'phone', s4.from, HW_CANDIDATES_AT);
  add('4b', 'phone', HW_CANDIDATES_AT, HW_SEND + MAC_DELAY);
  add('4c', 'win', HW_SEND + MAC_DELAY, s4.to);
  add('5', 'phone', seg('5').from, seg('5').to);
  add('6a', 'phone', seg('6').from, QUICK_SEND + MAC_DELAY);
  add('6b', 'linux', QUICK_SEND + MAC_DELAY, seg('6').to);
  add('7', 'phone', seg('7').from, seg('7').to);
  add('8', 'stage', seg('8').from, seg('8').to);
  add('9', 'wide', seg('9').from, seg('9').to);
  add('10', 'card', seg('10').from, FRAMES);
  return c;
})();

export const cutById = (id: string): Cut => {
  const c = CUTS.find((x) => x.id === id);
  if (!c) throw new Error(`no cut ${id}`);
  return c;
};
export const cutAt = (frame: number): Cut => CUTS.find((c) => frame >= c.from && frame < c.to) ?? CUTS[CUTS.length - 1];
