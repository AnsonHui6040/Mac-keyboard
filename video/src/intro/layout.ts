/**
 * Key rectangles of the real-device keyboard screenshots in docs/manual/images, in image pixels (720 wide, 1:1 on the phone screen).
 * Measured with a script (connected components of the two key colors: letter keys #6b6b6b, function keys #424242), not drawn by hand.
 * Pure numbers and conversion functions, so node can import it.
 */
export type R = { x: number; y: number; w: number; h: number };
export type KbName = 'connected' | 'draft' | 'quick' | 'blocked' | 'handwriting' | 'trackpad';
export type KbInfo = { file: string; h: number; panelTop: number; toolbarY: number; rowY: number | null; keys: Record<string, R> };

export const KB: Record<KbName, KbInfo> = {
  connected: {
    file: 'kb-connected.png', h: 594, panelTop: 0, toolbarY: 24, rowY: null,
    keys: {
      trackpadBtn: { x: 295, y: 24, w: 130, h: 49 },
      hide: { x: 437, y: 24, w: 130, h: 49 },
      shift: { x: 6, y: 282, w: 91, h: 74 },
      delete: { x: 623, y: 282, w: 91, h: 74 },
      sym: { x: 6, y: 378, w: 99, h: 74 },
      zh: { x: 117, y: 378, w: 99, h: 74 },
      enter: { x: 586, y: 378, w: 128, h: 74 },
      space: { x: 228, y: 378, w: 346, h: 74 },
      q: { x: 6, y: 89, w: 60, h: 73 },
      w: { x: 78, y: 89, w: 60, h: 73 },
      e: { x: 150, y: 89, w: 60, h: 73 },
      r: { x: 222, y: 89, w: 60, h: 73 },
      t: { x: 294, y: 89, w: 60, h: 73 },
      y: { x: 366, y: 89, w: 60, h: 73 },
      u: { x: 438, y: 89, w: 60, h: 73 },
      i: { x: 510, y: 89, w: 60, h: 73 },
      o: { x: 582, y: 89, w: 60, h: 73 },
      p: { x: 654, y: 89, w: 60, h: 73 },
      a: { x: 42, y: 185, w: 60, h: 74 },
      s: { x: 114, y: 185, w: 60, h: 74 },
      d: { x: 186, y: 185, w: 60, h: 74 },
      f: { x: 258, y: 185, w: 60, h: 74 },
      g: { x: 330, y: 185, w: 60, h: 74 },
      h: { x: 402, y: 185, w: 60, h: 74 },
      j: { x: 474, y: 185, w: 60, h: 74 },
      k: { x: 546, y: 185, w: 60, h: 74 },
      l: { x: 618, y: 185, w: 60, h: 74 },
      z: { x: 109, y: 282, w: 61, h: 73 },
      x: { x: 182, y: 282, w: 62, h: 73 },
      c: { x: 256, y: 282, w: 61, h: 73 },
      v: { x: 329, y: 282, w: 62, h: 73 },
      b: { x: 403, y: 282, w: 61, h: 73 },
      n: { x: 476, y: 282, w: 62, h: 73 },
      m: { x: 550, y: 282, w: 61, h: 73 },
    },
  },
  draft: {
    file: 'kb-remoteDraft.png', h: 648, panelTop: 4, toolbarY: 13, rowY: 75,
    keys: {
      trackpadBtn: { x: 295, y: 13, w: 130, h: 49 },
      hide: { x: 437, y: 13, w: 130, h: 49 },
      left: { x: 11, y: 75, w: 67, h: 53 },
      right: { x: 90, y: 75, w: 67, h: 53 },
      send: { x: 602, y: 76, w: 106, h: 52 },
      shift: { x: 6, y: 335, w: 91, h: 74 },
      delete: { x: 623, y: 335, w: 91, h: 74 },
      sym: { x: 6, y: 432, w: 99, h: 74 },
      zh: { x: 117, y: 432, w: 99, h: 74 },
      enter: { x: 586, y: 432, w: 128, h: 74 },
      space: { x: 228, y: 432, w: 346, h: 74 },
      q: { x: 6, y: 142, w: 60, h: 74 },
      w: { x: 78, y: 142, w: 60, h: 74 },
      e: { x: 150, y: 142, w: 60, h: 74 },
      r: { x: 222, y: 142, w: 60, h: 74 },
      t: { x: 294, y: 142, w: 60, h: 74 },
      y: { x: 366, y: 142, w: 60, h: 74 },
      u: { x: 438, y: 142, w: 60, h: 74 },
      i: { x: 510, y: 142, w: 60, h: 74 },
      o: { x: 582, y: 142, w: 60, h: 74 },
      p: { x: 654, y: 142, w: 60, h: 74 },
      a: { x: 42, y: 238, w: 60, h: 75 },
      s: { x: 114, y: 238, w: 60, h: 75 },
      d: { x: 186, y: 238, w: 60, h: 75 },
      f: { x: 258, y: 238, w: 60, h: 75 },
      g: { x: 330, y: 238, w: 60, h: 75 },
      h: { x: 402, y: 238, w: 60, h: 75 },
      j: { x: 474, y: 238, w: 60, h: 75 },
      k: { x: 546, y: 238, w: 60, h: 75 },
      l: { x: 618, y: 238, w: 60, h: 75 },
      z: { x: 109, y: 335, w: 61, h: 74 },
      x: { x: 182, y: 335, w: 62, h: 74 },
      c: { x: 256, y: 335, w: 61, h: 74 },
      v: { x: 329, y: 335, w: 62, h: 74 },
      b: { x: 403, y: 335, w: 61, h: 74 },
      n: { x: 476, y: 335, w: 62, h: 74 },
      m: { x: 550, y: 335, w: 61, h: 74 },
    },
  },
  quick: {
    file: 'kb-quick.png', h: 739, panelTop: 1, toolbarY: 40, rowY: 103,
    keys: {
      trackpadBtn: { x: 295, y: 40, w: 130, h: 49 },
      hide: { x: 437, y: 40, w: 130, h: 49 },
      left: { x: 11, y: 103, w: 68, h: 52 },
      right: { x: 90, y: 103, w: 67, h: 52 },
      send: { x: 602, y: 103, w: 106, h: 52 },
      shift: { x: 6, y: 426, w: 91, h: 74 },
      delete: { x: 623, y: 426, w: 91, h: 74 },
      sym: { x: 6, y: 523, w: 99, h: 74 },
      zh: { x: 117, y: 523, w: 99, h: 74 },
      enter: { x: 586, y: 523, w: 128, h: 74 },
      space: { x: 228, y: 523, w: 346, h: 74 },
      q: { x: 6, y: 233, w: 60, h: 74 },
      w: { x: 78, y: 233, w: 60, h: 74 },
      e: { x: 150, y: 233, w: 60, h: 74 },
      r: { x: 222, y: 233, w: 60, h: 74 },
      t: { x: 294, y: 233, w: 60, h: 74 },
      y: { x: 366, y: 233, w: 60, h: 74 },
      u: { x: 438, y: 233, w: 60, h: 74 },
      i: { x: 510, y: 233, w: 60, h: 74 },
      o: { x: 582, y: 233, w: 60, h: 74 },
      p: { x: 654, y: 233, w: 60, h: 74 },
      a: { x: 42, y: 330, w: 60, h: 74 },
      s: { x: 114, y: 330, w: 60, h: 74 },
      d: { x: 186, y: 330, w: 60, h: 74 },
      f: { x: 258, y: 330, w: 60, h: 74 },
      g: { x: 330, y: 330, w: 60, h: 74 },
      h: { x: 402, y: 330, w: 60, h: 74 },
      j: { x: 474, y: 330, w: 60, h: 74 },
      k: { x: 546, y: 330, w: 60, h: 74 },
      l: { x: 618, y: 330, w: 60, h: 74 },
      z: { x: 109, y: 427, w: 61, h: 73 },
      x: { x: 182, y: 427, w: 62, h: 73 },
      c: { x: 256, y: 427, w: 61, h: 73 },
      v: { x: 329, y: 427, w: 62, h: 73 },
      b: { x: 403, y: 427, w: 61, h: 73 },
      n: { x: 476, y: 427, w: 62, h: 73 },
      m: { x: 550, y: 427, w: 61, h: 73 },
    },
  },
  blocked: {
    file: 'kb-blocked.png', h: 610, panelTop: 6, toolbarY: 40, rowY: null,
    keys: {
      trackpadBtn: { x: 295, y: 40, w: 130, h: 49 },
      hide: { x: 437, y: 40, w: 130, h: 49 },
      shift: { x: 6, y: 297, w: 91, h: 74 },
      delete: { x: 623, y: 297, w: 91, h: 74 },
      sym: { x: 6, y: 394, w: 99, h: 74 },
      zh: { x: 117, y: 394, w: 99, h: 74 },
      enter: { x: 586, y: 394, w: 128, h: 74 },
      space: { x: 228, y: 394, w: 346, h: 74 },
      q: { x: 6, y: 104, w: 60, h: 74 },
      w: { x: 78, y: 104, w: 60, h: 74 },
      e: { x: 150, y: 104, w: 60, h: 74 },
      r: { x: 222, y: 104, w: 60, h: 74 },
      t: { x: 294, y: 104, w: 60, h: 74 },
      y: { x: 366, y: 104, w: 60, h: 74 },
      u: { x: 438, y: 104, w: 60, h: 74 },
      i: { x: 510, y: 104, w: 60, h: 74 },
      o: { x: 582, y: 104, w: 60, h: 74 },
      p: { x: 654, y: 104, w: 60, h: 74 },
      a: { x: 42, y: 201, w: 60, h: 74 },
      s: { x: 114, y: 201, w: 60, h: 74 },
      d: { x: 186, y: 201, w: 60, h: 74 },
      f: { x: 258, y: 201, w: 60, h: 74 },
      g: { x: 330, y: 201, w: 60, h: 74 },
      h: { x: 402, y: 201, w: 60, h: 74 },
      j: { x: 474, y: 201, w: 60, h: 74 },
      k: { x: 546, y: 201, w: 60, h: 74 },
      l: { x: 618, y: 201, w: 60, h: 74 },
      z: { x: 109, y: 298, w: 61, h: 73 },
      x: { x: 182, y: 298, w: 62, h: 73 },
      c: { x: 256, y: 298, w: 61, h: 73 },
      v: { x: 329, y: 298, w: 62, h: 73 },
      b: { x: 403, y: 298, w: 61, h: 73 },
      n: { x: 476, y: 298, w: 62, h: 73 },
      m: { x: 550, y: 298, w: 61, h: 73 },
    },
  },
  handwriting: {
    file: 'kb-handwriting-empty.png', h: 755, panelTop: 4, toolbarY: 13, rowY: 75,
    keys: {
      trackpadBtn: { x: 295, y: 13, w: 130, h: 49 },
      hide: { x: 437, y: 13, w: 130, h: 49 },
      left: { x: 11, y: 75, w: 67, h: 53 },
      right: { x: 90, y: 75, w: 67, h: 53 },
      send: { x: 602, y: 76, w: 106, h: 52 },
      sym: { x: 6, y: 539, w: 99, h: 74 },
      zh: { x: 117, y: 539, w: 99, h: 74 },
      space: { x: 228, y: 539, w: 235, h: 74 },
      rewrite: { x: 475, y: 539, w: 99, h: 74 },
      enter: { x: 586, y: 539, w: 128, h: 74 },
      pad: { x: 6, y: 141, w: 708, h: 375 },
    },
  },
  trackpad: {
    file: 'kb-trackpad.png', h: 648, panelTop: 4, toolbarY: 13, rowY: null,
    keys: {
      trackpadBtn: { x: 295, y: 13, w: 130, h: 49 },
      hide: { x: 437, y: 13, w: 130, h: 49 },
      pad: { x: 6, y: 77, w: 708, h: 429 },
    },
  },
};

/** Phone screen on the canvas: x 1152, 720 wide, bottom edge at y 864. The screenshots are drawn 1:1, bottom aligned. */
export const PHONE = { x: 1152, w: 720, bottom: 864, bezel: 14, radius: 72 } as const;
/** Mac display: outer box, the screen inset, the menu bar height. */
export const DISPLAY = { x: 40, y: 36, w: 1060, h: 832, inset: 10, radius: 26, menuH: 44 } as const;
/** The TextEdit window at full size. */
export const TEXTEDIT: R = { x: 66, y: 100, w: 1008, h: 744 };
/** Height of a MacWindow title bar. */
export const TITLEBAR = 56;

export const COLORS = { letter: '#6b6b6b', func: '#424242', panel: '#1f1f1f', field: '#363539', hwPad: '#3d3d3d', trackPad: '#333333', blue: '#0a84ff' } as const;

/** Canvas y of the top row of a screenshot. */
export const kbTop = (kb: KbName): number => PHONE.bottom - KB[kb].h;
/** Image rect to canvas rect. */
export const toCanvas = (kb: KbName, r: R): R => ({ x: PHONE.x + r.x, y: kbTop(kb) + r.y, w: r.w, h: r.h });
export const keyRect = (kb: KbName, key: string): R => {
  const r = KB[kb].keys[key];
  if (!r) throw new Error(`no key ${key} on ${kb}`);
  return toCanvas(kb, r);
};
export const centerOf = (r: R): { x: number; y: number } => ({ x: r.x + r.w / 2, y: r.y + r.h / 2 });
export const keyCenter = (kb: KbName, key: string): { x: number; y: number } => centerOf(keyRect(kb, key));

/** The 即時 / 草稿 switch: its 草稿 half (image coordinates), and the 即時 half. */
export const modeToggle = (kb: KbName, side: 'live' | 'draft'): R => ({ x: side === 'draft' ? 646 : 582, y: KB[kb].toolbarY + 2, w: 60, h: 45 });
/** Draft field (image coordinates) on the screenshots that have a draft row. */
export const draftField = (kb: KbName): R => ({ x: 169, y: KB[kb].rowY ?? 75, w: 421, h: 53 });

/** Handwriting candidate row (handwriting-empty image coordinates): the row of kb-handwriting.png moved up by 27. */
export const HW_CAND = { y: 175, xs: [90, 245, 401, 556], size: 38, texts: ['香港', '一香港', '手香港', '木香港'] } as const;
/** kb-handwriting.png is 782 high, kb-handwriting-empty.png 755: ink traced on the first goes to the second by this much. */
export const HW_SHIFT = 27;

/** Quick (速成) roots by key. */
export const QUICK_ROOT: Record<string, string> = {
  q: '手', w: '田', e: '水', r: '口', t: '廿', y: '卜', u: '山', i: '戈', o: '人', p: '心',
  a: '日', s: '尸', d: '木', f: '火', g: '土', h: '竹', j: '十', k: '大', l: '中',
  z: '重', x: '難', c: '金', v: '女', b: '月', n: '弓', m: '一',
};
/** Quick candidate bar (quick image coordinates): row center, spacing, glyph size, and where candidate 0 sits next to a code of n roots. */
export const QUICK_BAR = { y: 194, pitch: 80.6, size: 38, h: 52, hit: 76 } as const;
export const quickCenter = (codeLen: number, index: number, scroll: number): number => 68 + 38 * codeLen + QUICK_BAR.pitch * index - scroll;
/** Scroll that puts candidate `index` at image x `at`. */
export const quickScrollFor = (codeLen: number, index: number, at: number): number => quickCenter(codeLen, index, 0) - at;

/** Key labels redrawn when a key is pressed (the screenshot keeps the unpressed picture underneath). */
export const KEY_LABEL: Record<string, string> = { sym: '符號', zh: '中英', enter: '換行', space: '空白', rewrite: '重寫' };

/** Login window of scene 5 (canvas coordinates): window, the two fields and the button. */
export const LOGIN_WIN: R = { x: 210, y: 224, w: 720, h: 500 };
export const LOGIN_FIELDS = {
  account: { x: 266, y: 356, w: 608, h: 64 },
  password: { x: 266, y: 492, w: 608, h: 64 },
  button: { x: 266, y: 604, w: 608, h: 68 },
} as const;

/** Desktop icons and the menu of the trackpad scene (canvas coordinates, centers). */
export const DESKTOP = { cursorStart: { x: 470, y: 380 }, file: { x: 950, y: 235 }, folder: { x: 950, y: 650 } } as const;

/** The context menu of scene 4e. */
export const MENU = { w: 250, h: 232 } as const;
