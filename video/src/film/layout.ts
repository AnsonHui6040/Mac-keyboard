/**
 * Geometry shared by the pictures and the timetable. The phone is 720 wide (the real screenshots 1:1) with its bottom edge at y 864,
 * so every keyboard page sits bottom aligned and a key is where intro/layout.ts measured it. The Mac screen is 1280 by 800.
 * Pure numbers: node can import this.
 */
import { HW_CAND, KB, QUICK_BAR, draftField, modeToggle, quickCenter, type KbName, type R } from '../intro/layout.ts';

export type { KbName, R };
export const PHONE = { w: 720, bottom: 864 } as const;
export const kbTop = (kb: KbName): number => PHONE.bottom - KB[kb].h;
/** A rectangle of a screenshot (image pixels) on the phone. */
export const onPhone = (kb: KbName, r: R): R => ({ x: r.x, y: kbTop(kb) + r.y, w: r.w, h: r.h });
export const keyRect = (kb: KbName, key: string): R => {
  const r = KB[kb].keys[key];
  if (!r) throw new Error(`no key ${key} on ${kb}`);
  return onPhone(kb, r);
};
export const centerOf = (r: R): { x: number; y: number } => ({ x: r.x + r.w / 2, y: r.y + r.h / 2 });
export const toggleRect = (kb: KbName, side: 'live' | 'draft'): R => onPhone(kb, modeToggle(kb, side));
export const draftRect = (kb: KbName): R => onPhone(kb, draftField(kb));
export const hwCandidateRect = (kb: KbName, i: number): R => onPhone(kb, { x: HW_CAND.xs[i] - 60, y: HW_CAND.y - 26, w: 120, h: 52 });
export const quickCandidateRect = (kb: KbName, codeLen: number, i: number, scroll: number): R =>
  onPhone(kb, { x: quickCenter(codeLen, i, scroll) - QUICK_BAR.hit / 2, y: QUICK_BAR.y - QUICK_BAR.h / 2, w: QUICK_BAR.hit, h: QUICK_BAR.h });
/** The grey pad of the trackpad page on the phone. */
export const PAD: R = onPhone('trackpad', KB.trackpad.keys.pad);

// --- the Mac screen ---
export const MAC = { w: 1280, h: 800, menuH: 40 } as const;
export const DOC = { x: 40, y: 72, w: 840, h: 690, bar: 56, textX: 96, textY: 168, size: 52, pitch: 52 * 1.45 } as const;
/** Desktop icons, centers. The file is dropped into the folder. */
export const ICON = { file: { x: 980, y: 200 }, folder: { x: 980, y: 500 } } as const;
/** The pointer arrow is 34 units tall; it is drawn at CLOSE times that in the close-ups and at STAGE times in the 3D shots, where it is at least 44 px on the frame. */
export const CURSOR = { arrowH: 34, close: 1.53, stage: 1.8 } as const;
export const CURSOR_START = { x: 600, y: 560 } as const;
export const MENU = { w: 250, h: 232, offset: { x: 14, y: 8 }, itemH: 54, pad: 8, items: ['打開', '取得資訊', '重新命名', '丟到垃圾桶'] } as const;
/** Where the cursor tip goes to press 打開, relative to the menu's top left. */
export const MENU_OPEN_TIP = { x: 96, y: MENU.pad + MENU.itemH / 2 } as const;
export const FOLDER_WIN = { x: 400, y: 110, w: 760, h: 600, bar: 56, row: 84, pad: 18 } as const;
export const FOLDER_ITEMS = ['行程', '住宿', '交通', '地圖', '美食', '景點', '預算', '票券', '備忘', '照片', '清單', '證件', '購物', '天氣'] as const;
export const LOGIN_WIN = { x: 280, y: 150, w: 720, h: 480 } as const;
export const LOGIN_FIELDS = { account: { x: 340, y: 262, w: 600, h: 64 }, password: { x: 340, y: 380, w: 600, h: 64 }, button: { x: 340, y: 486, w: 600, h: 68 } } as const;
export const REMOTE_WIN = { x: 120, y: 80, w: 1040, h: 640, bar: 56 } as const;
export const REMOTE_FIELD = { x: 400, y: 392, w: 480, h: 72 } as const;
