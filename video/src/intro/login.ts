/** The Mac pointer of scene 5: it appears at 1334, travels to the password field from 1340 to 1356, presses at 1358. Pure. */
import { LOGIN } from './script.ts';
import { LOGIN_FIELDS } from './layout.ts';

export const LOGIN_START = { x: 770, y: 700 };
/** The pointer is drawn from this frame (it fades in over 4 frames). */
export const LOGIN_CURSOR_SHOWN = LOGIN.cursorFrom - 6;
export const LOGIN_TARGET = { x: LOGIN_FIELDS.password.x + 300, y: LOGIN_FIELDS.password.y + 32 };
const smooth = (u: number): number => (u <= 0 ? 0 : u >= 1 ? 1 : u * u * (3 - 2 * u));

export const loginCursorAt = (frame: number): { x: number; y: number; visible: boolean; press: number } => {
  const u = smooth((frame - LOGIN.cursorFrom) / (LOGIN.arrive - LOGIN.cursorFrom));
  const p = frame - LOGIN.click;
  const press = p >= 0 && p < 6 ? 1 - p / 6 : 0;
  return {
    x: LOGIN_START.x + (LOGIN_TARGET.x - LOGIN_START.x) * u,
    y: LOGIN_START.y + (LOGIN_TARGET.y - LOGIN_START.y) * u,
    visible: frame >= LOGIN_CURSOR_SHOWN,
    press,
  };
};
/** The field has the blue outline and the blinking caret from the click. */
export const loginFocused = (frame: number): boolean => frame >= LOGIN.click;
