/** Shots, titles and the end card of ProductFilm (docs/video/product-film-storyboard.md). Seconds times 30 is frames. Pure. */
export const FPS = 30;
export const FRAMES = 1515;
export const WIDTH = 1920;
export const HEIGHT = 1080;

export type ShotKind = 'hero' | 'phone' | 'mac' | 'stage' | 'card';
export type Shot = { id: string; from: number; to: number; kind: ShotKind };

const fr = (s: number): number => Math.round(s * FPS);
const shot = (id: string, from: number, to: number, kind: ShotKind): Shot => ({ id, from: fr(from), to: fr(to), kind });

export const SHOTS: readonly Shot[] = [
  shot('1', 0, 3.0, 'hero'),
  shot('2', 3.0, 3.9, 'phone'),
  shot('3', 3.9, 4.6, 'mac'),
  shot('4', 4.6, 5.0, 'phone'),
  shot('5', 5.0, 5.4, 'mac'),
  shot('6', 5.4, 6.2, 'phone'),
  shot('7', 6.2, 9.0, 'mac'),
  shot('8', 9.0, 10.2, 'phone'),
  shot('9', 10.2, 12.2, 'phone'),
  shot('10', 12.2, 12.9, 'mac'),
  shot('11', 12.9, 15.1, 'phone'),
  shot('12', 15.1, 16.0, 'phone'),
  shot('13', 16.0, 17.5, 'mac'),
  shot('14', 17.5, 18.1, 'phone'),
  shot('15', 18.1, 21.7, 'phone'),
  shot('16', 21.7, 23.1, 'phone'),
  shot('17', 23.1, 23.9, 'mac'),
  shot('18', 23.9, 26.9, 'phone'),
  shot('19', 26.9, 27.5, 'mac'),
  shot('20', 27.5, 28.3, 'phone'),
  shot('21a', 28.3, 29.0, 'stage'),
  shot('21b', 29.0, 31.2, 'stage'),
  shot('21c', 31.2, 32.8, 'stage'),
  shot('21d', 32.8, 35.4, 'stage'),
  shot('21e', 35.4, 37.7, 'stage'),
  shot('21f', 37.7, 41.0, 'stage'),
  shot('30', 41.0, 44.5, 'stage'),
  shot('31', 44.5, 50.5, 'card'),
];

export const shotAt = (frame: number): Shot => SHOTS.find((s) => frame >= s.from && frame < s.to) ?? SHOTS[SHOTS.length - 1];
export const shotById = (id: string): Shot => SHOTS.find((s) => s.id === id)!;

export type Title = { id: string; text: string; from: number; to: number; x: number; y: number; size: number; width: number; align: 'left' | 'center' };
const title = (id: string, text: string, from: number, to: number, at: { x: number; y: number; size: number; width: number; align?: 'left' | 'center' }): Title => ({ id, text, from: fr(from), to: fr(to), align: 'left', ...at });

/** Titles sit in the black of the frame: top left over the close-ups, top left above the Mac screen in the 3D shots. */
const TOP = { x: 96, y: 64, size: 88, width: 1560 };
export const TITLES: readonly Title[] = [
  title('t1', '人不在 Mac 前卻要打字', 0.6, 2.8, { x: 760, y: 640, size: 84, width: 1060 }),
  title('t2', '用 iPhone 打字到 Mac', 4.0, 6.4, TOP),
  title('t3', '即時模式每按一個鍵就送出', 6.4, 9.0, TOP),
  title('t4', '草稿模式先改好再傳送', 10.2, 13.2, TOP),
  title('t5', '中文可以用手寫', 17.7, 20.5, TOP),
  title('t6', '也可以在 App 改用速成', 24.1, 26.8, TOP),
  title('t7', '一指移動游標', 29.0, 31.2, { x: 120, y: 58, size: 84, width: 1200 }),
  title('t8', '輕點就是點按', 31.2, 32.8, { x: 120, y: 58, size: 84, width: 1200 }),
  title('t9', '按住再拖曳', 32.8, 35.4, { x: 120, y: 58, size: 84, width: 1200 }),
  title('t10', '兩指輕點是右鍵', 35.4, 37.7, { x: 120, y: 58, size: 84, width: 1200 }),
  title('t11', '兩指滑動來捲動', 37.7, 41.0, { x: 120, y: 58, size: 84, width: 1200 }),
];

export type CardLine = { at: number; text: string; size: number; y: number; weight: 400 | 500 | 700; color: string };
const line = (at: number, text: string, size: number, y: number, weight: 400 | 500 | 700, color: string): CardLine => ({ at: fr(at), text, size, y, weight, color });
export const CARD_X = 160;
export const END_CARD: readonly CardLine[] = [
  line(44.5, 'Remote Keyboard', 120, 170, 700, '#f5f5f7'),
  line(44.5, 'v0.1.0 Alpha', 56, 350, 500, '#f5f5f7'),
  line(44.5, '透過 SideStore 安裝', 52, 450, 400, '#9a9ba1'),
  line(44.5, '不是 App Store 版本', 52, 530, 400, '#9a9ba1'),
  line(46.5, '下載 github.com/AnsonHui6040/Mac-keyboard', 56, 690, 500, '#f5f5f7'),
  line(46.5, '安裝教學 youtu.be/dGhEuzRpAEg', 56, 780, 500, '#f5f5f7'),
  line(46.5, '與 Apple 沒有關聯', 32, 960, 400, '#9a9ba1'),
];

/** Length for the reading-speed rule: every CJK character counts 1, every run of Latin letters or digits counts 1. */
export const captionLength = (text: string): number => (text.match(/[㐀-鿿]/g) ?? []).length + (text.match(/[A-Za-z0-9]+/g) ?? []).length;

export const FORBIDDEN: readonly string[] = [' · ', '→', '，', ',', '零延遲', '絕對', '完全不漏字', 'Claude'];
