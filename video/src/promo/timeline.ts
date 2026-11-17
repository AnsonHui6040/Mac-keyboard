/** Segments, narration, titles and the end card of the v0.2 promo. Seconds times 30 is frames. Pure. */
import manifestJson from './voice-manifest.json' with { type: 'json' };
import { TITLES as OLD_TITLES, type CardLine, type Title } from '../film/timeline.ts';
import { NARRATION, type LineId, type SegId } from './narration.ts';

export type { LineId, SegId };
export const FPS = 30;
export const WIDTH = 1920;
export const HEIGHT = 1080;
/** Silence before and after each line, in seconds. */
export const PAD = 0.2;

const manifest = manifestJson as Record<LineId, { seconds: number; sha256: string; firstPause: number | null }>;
const SEG_IDS: readonly SegId[] = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '10'];
const LINE_OF: Record<SegId, LineId> = Object.fromEntries(NARRATION.map((n) => [n.seg, n.id])) as Record<SegId, LineId>;

/** What the picture needs, in seconds. */
export const SEG_MIN: Record<SegId, number> = { '1': 4.0, '2': 9.0, '3': 2.5, '4': 9.5, '5': 2.0, '6': 8.0, '7': 2.0, '8': 12.0, '9': 4.5, '10': 6.5 };

/** Seconds to frames without floating-point dust (12.8 s times 30 is 384.00000000000006). */
const frames = (s: number): number => Math.ceil(Math.round(s * FPS * 1e6) / 1e6);
const PAD_FRAMES = Math.round(PAD * FPS);

export type Segment = { id: SegId; from: number; to: number };
export const SEGMENTS: readonly Segment[] = (() => {
  let t = 0;
  return SEG_IDS.map((id) => {
    const from = t;
    t += frames(Math.max(SEG_MIN[id], manifest[LINE_OF[id]].seconds + 2 * PAD));
    return { id, from, to: t };
  });
})();
export const seg = (id: SegId): { from: number; to: number } => {
  const s = SEGMENTS.find((x) => x.id === id)!;
  return { from: s.from, to: s.to };
};
export const FRAMES: number = SEGMENTS[SEGMENTS.length - 1].to;

export const VOICE: readonly { id: LineId; from: number; to: number }[] = NARRATION.map((n) => {
  const from = seg(n.seg).from + PAD_FRAMES;
  return { id: n.id, from, to: from + frames(manifest[n.id].seconds) };
});
export const voice = (id: LineId): { from: number; to: number } => {
  const v = VOICE.find((x) => x.id === id)!;
  return { from: v.from, to: v.to };
};

// --- the trackpad (old shot 21: old frames 876 to 1252) timed to line 08 ---
const OLD_PAD_FIRST = 876;
const OLD_PAD_LAST = 1252;
const OLD_PAD_FIRST_ALL = 849;
/** The frame where the narration has said 「鍵盤還能變成觸控板」 and the first finger moves. */
export const PAD_START: number = voice('08').from + Math.round(manifest['08'].firstPause! * FPS);
/** Old frames per new frame. */
export const PAD_RATE: number = (OLD_PAD_LAST - OLD_PAD_FIRST) / (seg('8').to - 6 - PAD_START);
export const padFrame = (f: number): number => Math.min(OLD_PAD_LAST, Math.max(OLD_PAD_FIRST_ALL, OLD_PAD_FIRST + (f - PAD_START) * PAD_RATE));
/** The new frame of an old shot 21 frame (the inverse of padFrame). */
const newFrame = (old: number): number => Math.round(PAD_START + (old - OLD_PAD_FIRST) / PAD_RATE);

// --- titles ---
const TOP = { x: 96, y: 64, size: 88, width: 1560 };
const mk = (id: string, text: string, from: number, to: number, at: { x: number; y: number; size: number; width: number }): Title => ({ id, text, from, to, align: 'left', ...at });
const inSeg = (id: SegId): [number, number] => [seg(id).from + PAD_FRAMES, seg(id).to - PAD_FRAMES];
const half = (id: SegId): number => { const [a, b] = inSeg(id); return Math.round((a + b) / 2); };
const old = (id: string): Title => OLD_TITLES.find((t) => t.id === id)!;
const padTitle = (oldId: string, id: string): Title => {
  const t = old(oldId);
  return { ...t, id, from: newFrame(t.from), to: newFrame(t.to) };
};

export const TITLES: readonly Title[] = [
  mk('p1', '一支 iPhone 打字到三部電腦', ...inSeg('1'), TOP),
  mk('p2', '即時模式每按一個鍵就送出', inSeg('2')[0], half('2'), TOP),
  mk('p3', '草稿模式先改好再傳送', half('2'), inSeg('2')[1], TOP),
  mk('p4', '點一下換電腦', ...inSeg('3'), TOP),
  mk('p5', '中文可以用手寫', ...inSeg('4'), TOP),
  mk('p6', '也可以在 App 改用速成', ...inSeg('6'), TOP),
  padTitle('t7', 'p7'),
  padTitle('t8', 'p8'),
  padTitle('t9', 'p9'),
  padTitle('t10', 'p10'),
  padTitle('t11', 'p11'),
];

// --- end card ---
const at10 = seg('10').from;
const line = (at: number, text: string, size: number, y: number, weight: 400 | 500 | 700, color: string): CardLine => ({ at, text, size, y, weight, color });
export const END_CARD: readonly CardLine[] = [
  line(at10, 'Remote Keyboard', 120, 170, 700, '#f5f5f7'),
  line(at10, 'v0.2.0 Alpha', 56, 350, 500, '#f5f5f7'),
  line(at10, '支援 macOS 15、Windows 11、Ubuntu 26.04', 52, 450, 400, '#9a9ba1'),
  line(at10, '透過 SideStore 安裝 不是 App Store 版本', 52, 530, 400, '#9a9ba1'),
  line(at10 + 2 * FPS, '下載 github.com/AnsonHui6040/Mac-keyboard', 56, 690, 500, '#f5f5f7'),
  line(at10 + 2 * FPS, '與 Apple、Microsoft、Canonical 沒有關聯', 32, 960, 400, '#9a9ba1'),
];
