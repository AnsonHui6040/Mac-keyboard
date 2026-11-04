/** Canvas-space geometry of the four scene 16 screens. Pure numbers; the screens draw from these. */

export type Rect = { x: number; y: number; width: number; height: number };
export type ScreenId = 'dialogBlocked' | 'settingsSecurity' | 'dialogConfirm' | 'auth';
export type TargetId = 'done' | 'open' | 'trash' | 'password' | 'cancel';

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

export const DIALOGS: Record<ScreenId, Rect> = {
  dialogBlocked: BLOCKED,
  settingsSecurity: SETTINGS_WINDOW,
  dialogConfirm: CONFIRM,
  auth: AUTH,
};

export const SCREENS = {
  dialogBlocked: { done: blockedBtn(0), trash: blockedBtn(1) },
  settingsSecurity: { open: SETTINGS_OPEN },
  dialogConfirm: { trash: confirmBtn(502), open: confirmBtn(596), done: confirmBtn(690) },
  auth: { password: authBtn(0), cancel: authBtn(1) },
} satisfies Record<ScreenId, Partial<Record<TargetId, Rect>>>;
