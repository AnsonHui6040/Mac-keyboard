/** Canvas-space geometry of the four scene 16 screens. Pure numbers; the screens draw from these. */

export type Rect = { x: number; y: number; width: number; height: number };
export type ScreenId = string;
export type TargetId = string;

import { PHONE_ORIGIN_RIGHT, phoneRect } from './phone.ts';
import * as L from './layouts.ts';

export { PHONE_LOGICAL, PHONE_ORIGIN, PHONE_ORIGIN_RIGHT, PHONE_SCALE, phoneRect } from './phone.ts';

export const center = (r: Rect): { x: number; y: number } => ({ x: r.x + r.width / 2, y: r.y + r.height / 2 });

/**
 * Where the pointer tip rests on a target: 84% across and 30% down the rect, right of the label
 * and near the top. The tip is always inside the rect. The arrow (about 48 px tall) hangs below
 * the tip, so it stays inside the rect only when the rect is at least about 70 px tall; on a
 * shorter button (the 64 px Settings button) its lower part sticks out below the button.
 */
export const restPoint = (r: Rect): { x: number; y: number } => ({ x: r.x + r.width * 0.84, y: r.y + r.height * 0.3 });

/** Stage height above the subtitle divider; nothing may reach below this. */
export const STAGE_BOTTOM = 884;

// Shared dialog metrics (template numbers).
export const DIALOG_X = 480;
export const DIALOG_W = 590;
export const BTN_INSET = 34;
export const BTN_W = DIALOG_W - BTN_INSET * 2; // 522
export const BTN_H = 72;
export const BTN_STEP = 94; // 72 high plus a 22 gap between stacked buttons

const dialog = (height: number, y: number): Rect => ({ x: DIALOG_X, y, width: DIALOG_W, height });
const centeredY = (height: number): number => Math.round((STAGE_BOTTOM - height) / 2);

// dialogConfirm: the template, top at 54.
const CONFIRM = dialog(796, 54);
const confirmBtn = (relY: number): Rect => ({ x: CONFIRM.x + BTN_INSET, y: CONFIRM.y + relY, width: BTN_W, height: BTN_H });

// dialogBlocked: two buttons side by side along the bottom.
const BLOCKED_H = 560;
const BLOCKED = dialog(BLOCKED_H, centeredY(BLOCKED_H));
const BLOCKED_GAP = 16;
const BLOCKED_BTN_W = (BTN_W - BLOCKED_GAP) / 2; // 253
const blockedBtn = (col: 0 | 1): Rect => ({
  x: BLOCKED.x + BTN_INSET + col * (BLOCKED_BTN_W + BLOCKED_GAP),
  y: BLOCKED.y + BLOCKED_H - BTN_INSET - BTN_H,
  width: BLOCKED_BTN_W,
  height: BTN_H,
});

// auth: two stacked buttons.
const AUTH_H = 630;
const AUTH = dialog(AUTH_H, centeredY(AUTH_H));
const authBtn = (row: 0 | 1): Rect => ({
  x: AUTH.x + BTN_INSET,
  y: AUTH.y + AUTH_H - BTN_INSET - BTN_H - (1 - row) * BTN_STEP,
  width: BTN_W,
  height: BTN_H,
});

// settingsSecurity: a System Settings window fragment.
export const SETTINGS_WINDOW: Rect = { x: 260, y: 54, width: 1200, height: 660 };
export const SETTINGS_SIDEBAR_W = 280;
export const SETTINGS_OPEN: Rect = { x: 1192, y: 455, width: 200, height: 64 };

// Scenes 1 to 9. iPhone targets are logical rects mapped to the canvas; the phone sits alone (PHONE_ORIGIN) unless noted.
const P = (r: Rect): Rect => phoneRect(r);

export const DIALOGS: Record<ScreenId, Rect> = {
  dialogBlocked: BLOCKED,
  macBluetooth: BLOCKED,
  settingsSecurity: SETTINGS_WINDOW,
  dialogConfirm: CONFIRM,
  auth: AUTH,
};

/** Button rects by screen id, then by target id. New scenes add their screens here; both keys are free strings. */
export const SCREENS: Record<ScreenId, Record<TargetId, Rect>> = {
  dialogBlocked: { done: blockedBtn(0), trash: blockedBtn(1) },
  settingsSecurity: { open: SETTINGS_OPEN },
  dialogConfirm: { trash: confirmBtn(502), open: confirmBtn(596), done: confirmBtn(690) },
  auth: { password: authBtn(0), cancel: authBtn(1) },
  typing: {},
  checklist: {},
  reminders: {},
  vpnFlow: { get: P(L.APPSTORE_GET), connect: P(L.VPN_CONNECT), allow: P(L.ALERT_VPN.buttons[1]), status: P(L.VPN_STATUS) },
  // The phone is on the right of the iloader window (PHONE_ORIGIN_RIGHT).
  iloader: {
    trust: phoneRect(L.ALERT_TRUST.buttons[0], PHONE_ORIGIN_RIGHT),
    add: L.ILO_ADD,
    signin: L.ILO_SIGNIN,
    code: L.ILO_CODE,
    idl: L.ILO_DL,
    open: L.ILO_OPEN,
    device: L.ILO_DEVICE,
    stable: L.ILO_STABLE,
  },
  settingsFlow: {
    settings: P(L.HOME_SETTINGS),
    general: P(L.SET_GENERAL),
    vpnmgmt: P(L.GEN_VPNMGMT),
    row: P(L.VPNMGMT_ROW),
    trust: P(L.DEVPAGE_TRUST),
    allow: P(L.ALERT_RESTART.buttons[0]),
    keypad: P(L.KEYPAD),
    privacy: P(L.SET_PRIVACY),
    devmode: P(L.PRIVACY_DEVMODE),
    on: P(L.ALERT_DEVMODE.buttons[1]),
  },
  signIn: { status: P(L.VPN_STATUS), sidestore: P(L.HOME_SIDESTORE), signin: P(L.SIGNIN_BUTTON) },
  myApps: { myapps: P(L.TAB_MYAPPS), days: P(L.MYAPPS_DAYS), refresh: P(L.ALERT_REFRESH.buttons[1]) },
  loginError: {},
  // Scenes 10 to 15. Mac targets are canvas rects; iPhone targets are logical rects mapped with P.
  ipaDownload: { ipadl: L.REL_IPA },
  ipaVerify: { hash: L.TERM_HASH_BOX },
  ipaSend: { airdrop: L.AD_DEVICE, save: P(L.SAVE_ROW) },
  addIpa: { plus: P(L.PLUS), ipa: P(L.PICKER_IPA) },
  extDialog: { keepMain: P(L.extBtn(0)), keepEach: P(L.extBtn(1)), remove: P(L.extBtn(2)), choose: P(L.extBtn(3)), cancel: P(L.extBtn(4)), rkapp: P(L.MYAPPS3_ICON) },
  kbSettings: { settings: P(L.HOME_SETTINGS), general: P(L.SET_GENERAL), kbmenu: P(L.GEN_KBMENU), kblist: P(L.KBA_ROW), add: P(L.KBB_ADD) },
  kbAdd: { rk: P(L.ADD_THIRD) },
  kbList: { rkrow: P(L.KBL_RK) },
  fullAccess: { toggle: P(L.FA_ROW), allow: P(L.ALERT_FULL.buttons[1]) },
  appSetup: { open: P(L.HOME_RK), next: P(L.GUIDE_NEXT), bt: P(L.MAIN_BT), allowbt: P(L.MAIN_ALLOWBT), allow: P(L.ALERT_BT.buttons[1]) },
  zipFlow: { zipdl: L.REL_ZIP, hash: L.TERM_HASH_BOX, zipfile: L.FIN_ZIP, receiver: L.FIN_APP, apps: L.FIN_APPS, rkapp: L.FIN_RKAPP },
  // Scenes 17 to 21. The iPhone of scenes 18 to 20 is on the right of the Mac side (PHONE_ORIGIN_RIGHT).
  macBluetooth: { deny: blockedBtn(0), allow: blockedBtn(1) },
  receiverMenu: { icon: L.MENU_ICON, openSettings: L.PANEL17.buttons.openSettings },
  macAccess: { toggle: L.ACCESS_TOGGLE },
  pairFlow: {
    pairNew: L.PANEL18.idle.buttons.pairNew,
    phoneRow: phoneRect(L.SETUP_ROW_PAIR, PHONE_ORIGIN_RIGHT),
    pairMac: phoneRect(L.PAIRPAGE_ROW, PHONE_ORIGIN_RIGHT),
    macConfirm: L.PANEL18.code.buttons.confirm,
    phoneConfirm: phoneRect(L.PC_CONFIRM, PHONE_ORIGIN_RIGHT),
  },
  pairDone: { macDone: L.PANEL18.saved.buttons.done, phoneDone: phoneRect(L.PS_DONE, PHONE_ORIGIN_RIGHT) },
  keyboardOn: {
    doc: L.DOC_CLICK,
    field: phoneRect(L.FIELD, PHONE_ORIGIN_RIGHT),
    globe: phoneRect(L.GLOBE, PHONE_ORIGIN_RIGHT),
    rk: phoneRect(L.KBPOP_RK, PHONE_ORIGIN_RIGHT),
    remote: phoneRect(L.TB_REMOTE, PHONE_ORIGIN_RIGHT),
  },
  calendar: {},
};
