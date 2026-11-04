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

// ================================================================ scenes 10 to 15
// iPhone rects are logical (390 x 844); Mac rects are canvas pixels.

// ---------------------------------------------------------------- scenes 10 and 15: Release page, terminal, AirDrop, Finder (canvas px)
export const REL_WIN = R(160, 128, 1600, 724);
export const REL_ROW_H = 84;
/** The asset rows of the Release page: the .ipa first, then the .zip. */
export const REL_IPA = R(REL_WIN.x + 80, REL_WIN.y + 350, 1440, REL_ROW_H);
export const REL_ZIP = R(REL_WIN.x + 80, REL_WIN.y + 350 + REL_ROW_H, 1440, REL_ROW_H);

/** Terminal window; text is monospace at TERM_SIZE, so one character is 0.6 x TERM_SIZE wide (64 characters: 1229 px). */
export const TERM_WIN = R(140, 230, 1640, 480);
export const TERM_SIZE = 32;
export const TERM_PITCH = 50;
export const TERM_X = 230;
export const TERM_ROW_CMD = TERM_WIN.y + 86;
export const TERM_ROW_HASH = TERM_WIN.y + 136;
export const TERM_ROW_FILE = TERM_WIN.y + 186;
export const TERM_DIVIDER = TERM_WIN.y + 256;
export const TERM_LABEL = TERM_WIN.y + 276;
export const TERM_ROW_RELEASE = TERM_WIN.y + 336;
/** Both hashes (the shasum output and the Release value): the pointer rests to the right of their ends. */
export const TERM_HASH_BOX = R(TERM_X, TERM_WIN.y + 130, 1500, 260);

export const AD_WIN = R(520, 200, 880, 520);
/** The 我的 iPhone circle with its label. */
export const AD_DEVICE = R(AD_WIN.x + 500, AD_WIN.y + 215, 240, 220);

export const FIN_WIN = R(220, 100, 1480, 700);
export const FIN_SIDEBAR_W = 300;
export const FIN_APPS = R(FIN_WIN.x + 14, FIN_WIN.y + 250, 272, 52);
export const FIN_DOWNLOADS = R(FIN_WIN.x + 14, FIN_WIN.y + 310, 272, 52);
export const FIN_ZIP = R(FIN_WIN.x + 380, FIN_WIN.y + 110, 240, 292);
export const FIN_APP = R(FIN_WIN.x + 680, FIN_WIN.y + 110, 240, 292);

// ---------------------------------------------------------------- scene 10: save to Files (iPhone)
export const SAVE_SHEET = R(8, 290, 374, 550);
export const SAVE_ACTIONS = R(16, 540, 358, 288);
export const SAVE_ROW = R(16, 612, 358, 72);

// ---------------------------------------------------------------- scene 11: My Apps with a plus, file picker, App Contains Extensions
export const PLUS = R(16, 58, 64, 64);
export const MYAPPS2_CARD = R(16, 248, 358, 116);
export const MYAPPS2_DAYS = R(250, 282, 108, 52);
export const PICKER_ROWS = R(16, 236, 358, 540);
export const PICKER_IPA = R(16, 344, 358, 108);

export const EXT_CARD = R(8, 112, 374, 600);
const EXT_HEAD = 160;
const EXT_ROW = 88;
/** Button i (0 to 4) of the dialog. The target is the row inset 12 px top and bottom, so the rings of neighbours stay apart. */
export const extBtn = (i: number): Rect => R(18, EXT_CARD.y + EXT_HEAD + EXT_ROW * i + 12, 354, 64);
export const EXT_TITLE_Y = EXT_CARD.y + 28;
export const EXT_BODY_Y = EXT_CARD.y + 28 + 38 + 16;

// ---------------------------------------------------------------- scene 12: keyboards
export const GEN2_CARD = R(16, 386, 358, 216);
export const GEN_KBMENU = R(16, 386, 358, 72);
export const KBA_CARD = R(16, 150, 358, 216);
export const KBA_ROW = R(16, 150, 358, 72);
export const KBB_CARD = R(16, 150, 358, 216);
export const KBB_ADD = R(16, 462, 358, 72);
export const ADD_SUGGESTED = R(16, 212, 358, 240);
export const ADD_THIRD = R(16, 526, 358, 72);
export const KBL_CARD = R(16, 150, 358, 288);
export const KBL_RK = R(16, 366, 358, 72);
export const KBL_ADD = R(16, 540, 358, 72);

// ---------------------------------------------------------------- scene 13: full access
export const FA_ROW = R(16, 150, 358, 72);
export const ALERT_FULL = alertLayout(3, 2, false); // 不允許 | 允許

// ---------------------------------------------------------------- scene 14: the app
export const HOME_RK = homeIcon(3, 1);
export const GUIDE_NEXT = R(36, 736, 318, 76);
export const MAIN_CARD = R(16, 190, 358, 216);
export const MAIN_CARD_OPEN = R(16, 190, 358, 300);
export const MAIN_BT = R(16, 190, 358, 72);
export const MAIN_ALLOWBT = R(40, 274, 310, 60);
export const ALERT_BT = alertLayout(3, 2, false); // 不允許 | 允許
