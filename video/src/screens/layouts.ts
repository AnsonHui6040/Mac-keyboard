/**
 * Pure layout numbers for scenes 1 to 9. iPhone rects are in the logical 390 x 844 screen; Mac rects are canvas pixels.
 * geometry.ts turns the iPhone rects into canvas rects with phoneRect; the screens draw from the same numbers.
 */
import type { Rect } from './geometry.ts';

const R = (x: number, y: number, width: number, height: number): Rect => ({ x, y, width, height });

/** Smallest text size on an iPhone screen, in logical points: 26 x 0.94 = 24.4 px on the canvas. */
export const PHONE_MIN_TEXT = 26;

// ---------------------------------------------------------------- iOS alerts
export const ALERT_X = 40;
export const ALERT_W = 310;
export const ALERT_BTN_H = 72;
const ALERT_PAD_TOP = 28;
const ALERT_TITLE_LINE = 38;
const ALERT_BODY_GAP = 16;
const ALERT_BODY_H = 54; // two gray lines
const ALERT_BODY_END_GAP = 24;

export type AlertLayout = { card: Rect; buttons: Rect[]; bodyY: number; titleY: number };
/**
 * A centered iOS alert: `titleLines` lines of title, two gray body lines, then buttons side by side (`stacked` false,
 * two buttons) or one above the other.
 */
export function alertLayout(titleLines: number, buttons: number, stacked: boolean, withBody = true): AlertLayout {
  const bodyH = withBody ? ALERT_BODY_GAP + ALERT_BODY_H : 0;
  const head = ALERT_PAD_TOP + titleLines * ALERT_TITLE_LINE + bodyH + ALERT_BODY_END_GAP;
  const foot = stacked ? buttons * ALERT_BTN_H : ALERT_BTN_H;
  const h = head + foot;
  const top = Math.round((844 - h) / 2) - 20;
  const rects: Rect[] = [];
  for (let i = 0; i < buttons; i++) {
    rects.push(stacked ? R(ALERT_X, top + head + i * ALERT_BTN_H, ALERT_W, ALERT_BTN_H) : R(ALERT_X + (i * ALERT_W) / buttons, top + head, ALERT_W / buttons, ALERT_BTN_H));
  }
  return { card: R(ALERT_X, top, ALERT_W, h), buttons: rects, titleY: top + ALERT_PAD_TOP, bodyY: top + ALERT_PAD_TOP + titleLines * ALERT_TITLE_LINE + ALERT_BODY_GAP };
}

export const ALERT_VPN = alertLayout(2, 2, false); // 不允許 | 允許
export const ALERT_TRUST = alertLayout(1, 2, true); // 信任 / 不信任
export const ALERT_RESTART = alertLayout(2, 2, true); // 允許並重新啟動 / 不允許
export const ALERT_DEVMODE = alertLayout(1, 2, false); // 取消 | 開啟
export const ALERT_REFRESH = alertLayout(1, 2, true); // Yes / Refresh Now
export const ALERT_ERROR = alertLayout(3, 1, true, false); // three lines of message, one button

// ---------------------------------------------------------------- iOS home grid
export const HOME_ICON = 66;
export const homeIcon = (col: number, row: number): Rect => R(30 + col * 88, 100 + row * 130, HOME_ICON, HOME_ICON);
export const HOME_SETTINGS = homeIcon(2, 0);
export const HOME_SIDESTORE = homeIcon(1, 1);

// ---------------------------------------------------------------- scene 4, 7: LocalDevVPN
export const APPSTORE_ICON = R(30, 100, 110, 110);
export const APPSTORE_GET = R(156, 190, 130, 60);
export const VPN_CARD_STATUS = R(16, 128, 358, 200);
export const VPN_STATUS = R(150, 196, 206, 84);
export const VPN_CARD_CONNECT = R(16, 344, 358, 170);
export const VPN_CONNECT = R(36, 420, 318, 76);
export const VPN_CARD_INFO = R(16, 534, 358, 200);

// ---------------------------------------------------------------- scene 6: Settings
export const SET_CARD1 = R(16, 150, 358, 144);
export const SET_CARD2 = R(16, 314, 358, 288);
export const SET_CARD3 = R(16, 622, 358, 144);
export const SET_GENERAL = R(16, 458, 358, 72);
export const SET_PRIVACY = R(16, 622, 358, 72);
export const GEN_CARD1 = R(16, 150, 358, 216);
export const GEN_CARD2 = R(16, 386, 358, 216);
export const GEN_VPNMGMT = R(16, 530, 358, 72);
export const VPNMGMT_CARD = R(16, 292, 358, 72);
export const VPNMGMT_ROW = VPNMGMT_CARD;
export const DEVPAGE_TRUST = R(16, 150, 358, 110);
export const PRIVACY_DEVMODE = R(16, 690, 358, 72);
export const KEYPAD = R(45, 250, 300, 463);

// ---------------------------------------------------------------- scene 7: SideStore sign-in
export const SIGNIN_ICON = R(150, 104, 90, 90);
export const SIGNIN_FIELD1 = R(16, 330, 358, 72);
export const SIGNIN_FIELD2 = R(16, 460, 358, 72);
export const SIGNIN_BUTTON = R(16, 580, 358, 80);

// ---------------------------------------------------------------- scene 8: SideStore My Apps
export const TAB_BAR = R(8, 752, 374, 76);
const TAB_SLOT = 54;
const TAB_PILL: Record<number, number> = { 0: 96, 3: 136 };
/** Tab rects (News, Sources, Browse, My Apps, Settings); the selected one is a wide pill with a label. */
export function tabLayout(selected: number): Rect[] {
  const out: Rect[] = [];
  let x = TAB_BAR.x + 8;
  for (let i = 0; i < 5; i++) {
    const w = i === selected ? (TAB_PILL[i] ?? 110) : TAB_SLOT;
    out.push(R(x, TAB_BAR.y + 8, w, TAB_BAR.height - 16));
    x += w;
  }
  return out;
}
export const TAB_MYAPPS = tabLayout(0)[3];
export const MYAPPS_CARD = R(16, 196, 358, 116);
export const MYAPPS_DAYS = R(250, 230, 108, 52);

// ---------------------------------------------------------------- scene 5: iloader (canvas px)
export const ILOADER_WINDOW = R(260, 54, 1120, 780);
export const ILO_LEFT = R(296, 214, 500, 340);
export const ILO_RIGHT = R(844, 214, 500, 340);
export const ILO_ADD = R(324, 448, 444, 72);
export const ILO_DEVICE = R(872, 300, 444, 84);
export const ILO_REFRESH = R(872, 404, 444, 64);
/** Sign-in sheet that opens over the window when Add Account + is pressed. */
export const ILO_SHEET = R(520, 190, 600, 450);
export const ILO_SHEET_FIELD1 = R(552, 304, 536, 64);
export const ILO_SHEET_FIELD2 = R(552, 420, 536, 64);
export const ILO_SIGNIN = R(552, 528, 536, 72);
export const ILO_INSTALLERS = R(296, 578, 1048, 230);
export const ILO_STABLE = R(324, 660, 420, 72);

// ---------------------------------------------------------------- scene 1: typing demo
export const TEXTEDIT_WINDOW = R(120, 110, 1260, 700);

/** Keyboard rows of the iPhone keyboard, in logical px. */
export const KB_TOP = 432;
export const KB_KEY_H = 56;
export const KB_ROWS: string[] = ['qwertyuiop', 'asdfghjkl', 'zxcvbnm'];
export function keyRect(ch: string): Rect | undefined {
  if (ch === ' ') return R(112, KB_TOP + 4 * 66 + 4 + 0, 166, KB_KEY_H);
  const lower = ch.toLowerCase();
  for (let r = 0; r < KB_ROWS.length; r++) {
    const i = KB_ROWS[r].indexOf(lower);
    if (i === -1) continue;
    const pitch = 38.4;
    const rowW = KB_ROWS[r].length * pitch - 4.8;
    const x0 = (390 - rowW) / 2;
    return R(x0 + i * pitch, KB_TOP + 4 + r * 66 + 66, 33.6, KB_KEY_H);
  }
  return undefined;
}
