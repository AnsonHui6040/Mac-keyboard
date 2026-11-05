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
/** The six-digit field of the verification code sheet (it replaces the sign-in sheet's fields). */
export const ILO_CODE = R(552, 400, 536, 80);
/** The browser page of scene 5 beat 0: the iloader download button, and the header of the iloader window the pointer visits next. */
export const ILO_DL = R(320, 430, 440, 84);
export const ILO_OPEN = R(296, 112, 300, 84);
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
/** The command line, for a click into the terminal; the pointer rests right of the command. */
export const TERM_CMD_BOX = R(TERM_X, TERM_ROW_CMD - 6, 1500, 60);
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
/** Remote Keyboard Receiver in the 應用程式 folder: the third of four apps. */
export const FIN_RKAPP = R(FIN_WIN.x + 980, FIN_WIN.y + 110, 240, 292);

// ---------------------------------------------------------------- scene 10: save to Files (iPhone)
export const SAVE_SHEET = R(8, 290, 374, 550);
export const SAVE_ACTIONS = R(16, 540, 358, 288);
export const SAVE_ROW = R(16, 612, 358, 72);

// ---------------------------------------------------------------- scene 11: My Apps with a plus, file picker, App Contains Extensions
export const PLUS = R(16, 58, 64, 64);
export const MYAPPS2_CARD = R(16, 248, 358, 116);
export const MYAPPS2_DAYS = R(250, 282, 108, 52);
/** Scene 11 beat 4: My Apps after the install; Remote Keyboard is the second card of the Active list. */
export const MYAPPS3_CARD = R(16, 380, 358, 116);
export const MYAPPS3_DAYS = R(250, 414, 108, 52);
/** The left strip of the Remote Keyboard card: the pointer rests on its icon, clear of the name. */
export const MYAPPS3_ICON = R(16, 380, 54, 116);
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

// ================================================================ scenes 17 to 21
// Mac rects are canvas pixels; iPhone rects are logical (390 x 844). The iPhone sits on the right (PHONE_ORIGIN_RIGHT) in scenes 18 to 20.

// ---------------------------------------------------------------- scene 17: menu bar, Receiver panel, Accessibility list
export const MENUBAR_H = 60;
/** The keyboard icon in the menu bar; a click opens the panel under it. */
export const MENU_ICON = R(1700, 2, 72, 56);

export type PanelKind = 'access' | 'idle' | 'waiting' | 'code' | 'saved' | 'paired';
export const PANEL_W = 560;
const PANEL_PAD = 24;
const PANEL_LINE = 36;
const PANEL_BTN_H = 52;
const PANEL_GAP = 12;
const PANEL_SEP = 42; // gap, hairline, gap between sections
export const PANEL_TEXT = 24;

export type PanelLayout = {
  rect: Rect;
  /** Top of each section. `warnY` exists only for kind `access`. */
  warnY?: number;
  statusY: number;
  startY: number;
  pairY: number;
  tailY: number;
  /** Hairlines between sections. */
  dividers: number[];
  /** Button rects by name: authorize, openSettings (access); start, stop; pairNew, unpair (idle, access, paired); cancel (waiting, code); confirm (code); done (saved). */
  buttons: Record<string, Rect>;
};

const pairHeight = (kind: PanelKind): number => {
  switch (kind) {
    case 'access':
    case 'idle':
      return PANEL_LINE + PANEL_GAP + PANEL_BTN_H + PANEL_GAP + 3 * 32;
    case 'waiting':
    case 'saved':
      return 2 * 34 + PANEL_GAP + PANEL_BTN_H;
    case 'code':
      return PANEL_LINE + 8 + 64 + 8 + PANEL_LINE + PANEL_GAP + PANEL_BTN_H + 8 + PANEL_LINE;
    case 'paired':
      return PANEL_LINE + 34 + PANEL_GAP + PANEL_BTN_H;
  }
};

/** The Receiver menu bar panel with its top-left at (x, y); every number follows from the section heights. */
export function panelLayout(kind: PanelKind, x: number, y: number): PanelLayout {
  const bx = x + PANEL_PAD;
  const buttons: Record<string, Rect> = {};
  let cy = y + PANEL_PAD;
  let warnY: number | undefined;
  if (kind === 'access') {
    warnY = cy;
    buttons.authorize = R(bx, cy + PANEL_LINE + PANEL_GAP, 220, PANEL_BTN_H);
    buttons.openSettings = R(bx + 220 + 12, cy + PANEL_LINE + PANEL_GAP, 236, PANEL_BTN_H);
    cy += PANEL_LINE + PANEL_GAP + PANEL_BTN_H + 20;
  }
  const statusY = cy;
  cy += 3 * PANEL_LINE + 12;
  const startY = cy;
  buttons.start = R(bx, cy, 140, PANEL_BTN_H);
  buttons.stop = R(bx + 152, cy, 140, PANEL_BTN_H);
  cy += PANEL_BTN_H;
  const dividers = [cy + 20];
  cy += PANEL_SEP;
  const pairY = cy;
  const by = (offset: number): number => pairY + offset;
  if (kind === 'access' || kind === 'idle') {
    buttons.pairNew = R(bx, by(PANEL_LINE + PANEL_GAP), 250, PANEL_BTN_H);
    buttons.unpair = R(bx + 250 + 12, by(PANEL_LINE + PANEL_GAP), 140, PANEL_BTN_H);
  } else if (kind === 'waiting') {
    buttons.cancel = R(x + PANEL_W - PANEL_PAD - 92, by(2 * 34 + PANEL_GAP), 92, PANEL_BTN_H);
  } else if (kind === 'code') {
    const row = by(PANEL_LINE + 8 + 64 + 8 + PANEL_LINE + PANEL_GAP);
    buttons.confirm = R(bx, row, 92, PANEL_BTN_H);
    buttons.cancel = R(bx + 104, row, 92, PANEL_BTN_H);
  } else if (kind === 'saved') {
    buttons.done = R(x + PANEL_W - PANEL_PAD - 92, by(2 * 34 + PANEL_GAP), 92, PANEL_BTN_H);
  } else {
    buttons.pairNew = R(bx, by(PANEL_LINE + 34 + PANEL_GAP), 250, PANEL_BTN_H);
    buttons.unpair = R(bx + 250 + 12, by(PANEL_LINE + 34 + PANEL_GAP), 140, PANEL_BTN_H);
  }
  cy += pairHeight(kind);
  dividers.push(cy + 20);
  cy += PANEL_SEP;
  const tailY = cy;
  cy += 2 * 44 + PANEL_PAD;
  return { rect: R(x, y, PANEL_W, cy - y), warnY, statusY, startY, pairY, tailY, dividers, buttons };
}

/** Scene 17: the panel hangs from the menu bar icon, its right edge 28 px right of the icon's. */
export const PANEL17 = panelLayout('access', MENU_ICON.x + MENU_ICON.width + 28 - PANEL_W, MENUBAR_H + 8);
/** Scenes 18 and 19: the panel floats on the Mac side, left of the iPhone. */
export const PANEL_X2 = 640;
export const PANEL_Y2 = 70;
export const PANEL18 = {
  idle: panelLayout('idle', PANEL_X2, PANEL_Y2),
  waiting: panelLayout('waiting', PANEL_X2, PANEL_Y2),
  code: panelLayout('code', PANEL_X2, PANEL_Y2),
  saved: panelLayout('saved', PANEL_X2, PANEL_Y2),
  paired: panelLayout('paired', PANEL_X2, PANEL_Y2),
};

/** Scene 17 beat 2: the System Settings window with the Accessibility list. */
export const ACCESS_WINDOW = R(360, 90, 1200, 700);
export const ACCESS_SIDEBAR_W = 280;
export const ACCESS_CARD = R(ACCESS_WINDOW.x + ACCESS_SIDEBAR_W + 40, ACCESS_WINDOW.y + 210, ACCESS_WINDOW.width - ACCESS_SIDEBAR_W - 80, 5 * 72);
/** The row of Remote Keyboard Receiver is the third of five. */
export const ACCESS_ROW = R(ACCESS_CARD.x, ACCESS_CARD.y + 2 * 72, ACCESS_CARD.width, 72);
export const ACCESS_TOGGLE = R(ACCESS_CARD.x + ACCESS_CARD.width - 24 - 76, ACCESS_ROW.y + 13, 76, 46);

// ---------------------------------------------------------------- scenes 18 and 19: the iPhone pages of pairing (logical)
/** 設定進度 card on the app's home: three rows of 72; the second is 已配對 Mac. */
export const SETUP_ROW_PAIR = R(MAIN_CARD.x, MAIN_CARD.y + 72, MAIN_CARD.width, 72);
/** 已配對 Mac page (not paired yet): two rows, the second is 配對 Mac. */
export const PAIRPAGE_CARD = R(16, 200, 358, 144);
export const PAIRPAGE_ROW = R(16, 272, 358, 72);
/** 配對 Mac while it waits for the Mac. */
export const PW_CARD = R(16, 200, 358, 170);
export const PW_CANCEL = R(16, 390, 358, 72);
/** 配對 Mac with the code: header at y 186, the card, then 確認 and 取消. */
export const PC_HEAD_Y = 186;
export const PC_CARD = R(16, 226, 358, 264);
export const PC_CONFIRM = R(16, 514, 358, 72);
export const PC_CANCEL = R(16, 586, 358, 72);
/** 已儲存: a text row, a countdown row, 完成. After 完成 the page says 已配對 Mac with 完成 at the same place. */
export const PS_CARD = R(16, 200, 358, 244);
export const PS_DONE = R(16, 372, 358, 72);

// ---------------------------------------------------------------- scene 20: TextEdit and the keyboard switch
/** The TextEdit window of scene 20: lower than scene 1's, so the device tag at the top left stays clear of it. */
export const TEXTEDIT20 = R(120, 150, 1260, 680);
/** Where a click goes in the TextEdit document. */
export const DOC_CLICK = R(TEXTEDIT20.x + 60, TEXTEDIT20.y + 110, 1140, 300);
/** An input field on the iPhone, the page the keyboard comes up on. */
export const FIELD = R(24, 112, 342, 72);
export const GLOBE = R(10, 770, 64, 64);
/** The keyboard list that opens above the globe key: two gray rows, then Remote Keyboard. */
export const KBPOP = R(12, 560, 300, 198);
export const KBPOP_RK = R(12, 560 + 132, 300, 66);
/** 遠端 half of the 本機 | 遠端 switch on the Remote Keyboard toolbar. */
export const TB_REMOTE = R(77, KB_TOP + 5, 62, 48);
export const TB_LOCAL = R(15, KB_TOP + 5, 62, 48);
