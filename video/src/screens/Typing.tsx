import { Layer, Path, Rect, Ellipse, Text } from '@kinetographdev/core';
import { MacWindow } from '../components/MacWindow.tsx';
import { PhoneScreen } from '../components/PhoneScreen.tsx';
import { BoxText, Card, PText, Skel, StatusBar, ios } from '../components/ios.tsx';
import { PHONE_ORIGIN_RIGHT } from './phone.ts';
import { KB_KEY_H, KB_ROWS, KB_TOP, TEXTEDIT_WINDOW, keyRect } from './layouts.ts';
import type { Rect as Box } from './geometry.ts';
import type { ScreenProps } from './registry.tsx';
import { theme } from '../theme.ts';

export const TYPED = 'Hello Mac, this is typed on my iPhone';
/** Frame the first letter appears, and frames per letter. */
export const TYPE_START = 12;
export const TYPE_PITCH = 7;
const KEY_FLASH = 5;

const NONE = '#00000000';
const KEY = '#5a5a5f';
const KEY_DARK = '#3c3c40';
const rel = (r: Box): Box => ({ x: 0, y: 0, width: r.width, height: r.height });

/** How many letters of TYPED are on screen at a scene frame. */
export const typedCount = (localFrame: number): number =>
  localFrame < TYPE_START ? 0 : Math.min(TYPED.length, Math.floor((localFrame - TYPE_START) / TYPE_PITCH) + 1);

/** `system`: the stock keyboard, no toolbar. `local` and `remote`: Remote Keyboard with 本機 or 遠端 selected. `connected`: 遠端 and the green 已連接 (scene 1). */
export type KeyboardMode = 'system' | 'local' | 'remote' | 'connected';

export const Keyboard = ({ pressed, mode = 'connected' }: { pressed: string | undefined; mode?: KeyboardMode }) => {
  const rk = mode !== 'system';
  const remote = mode === 'remote' || mode === 'connected';
  const letter = (ch: string) => {
    const r = keyRect(ch)!;
    const on = pressed !== undefined && pressed.toLowerCase() === ch;
    return (
      <Layer key={ch} x={r.x} y={r.y}>
        <Rect width={r.width} height={r.height} radius={9} fill={on ? '#ffffff' : KEY} />
        <BoxText box={rel(r)} size={28} weight={400} color={on ? '#000000' : ios.ink}>{ch}</BoxText>
      </Layer>
    );
  };
  const y4 = KB_TOP + 4 + 3 * 66 + 66;
  const space = keyRect(' ')!;
  const spaceOn = pressed === ' ';
  return (
    <Layer id="keyboard">
      <Rect x={0} y={KB_TOP - 6} width={390} height={844 - KB_TOP + 6} fill="#1d1d1f" />
      {/* toolbar: 本機 | 遠端, 已連接, 觸控板 */}
      {rk && (
        <Layer id="toolbar">
          <Rect x={12} y={KB_TOP + 2} width={130} height={54} radius={14} fill="#2c2c2e" />
          <Rect x={remote ? 77 : 15} y={KB_TOP + 5} width={62} height={48} radius={11} fill="#ffffff" />
          <PText x={12} y={KB_TOP + 2 + (54 - 26 * 1.45) / 2} size={26} weight={remote ? undefined : 700} color={remote ? ios.muted : '#000000'} w={65} align="center">本機</PText>
          <PText x={77} y={KB_TOP + 2 + (54 - 26 * 1.45) / 2} size={26} weight={remote ? 700 : undefined} color={remote ? '#000000' : ios.muted} w={62} align="center">遠端</PText>
          {mode === 'connected' && <PText x={156} y={KB_TOP + 2 + (54 - 26 * 1.45) / 2} size={26} weight={700} color={ios.green} w={90} align="center">已連接</PText>}
          <Rect x={262} y={KB_TOP + 2} width={116} height={54} radius={14} fill="#3a3a3e" />
          <PText x={262} y={KB_TOP + 2 + (54 - 26 * 1.45) / 2} size={26} w={116} align="center">觸控板</PText>
        </Layer>
      )}
      {KB_ROWS.flatMap((row) => row.split('')).map(letter)}
      {/* shift and delete */}
      <Rect x={6} y={KB_TOP + 4 + 2 * 66 + 66} width={51} height={KB_KEY_H} radius={9} fill={KEY_DARK} />
      <Path x={19} y={KB_TOP + 4 + 2 * 66 + 66 + 14} d="M12 0 L24 14 H17 V28 H7 V14 H0 Z" fill={NONE} stroke={{ color: ios.ink, width: 3, join: 'round' }} />
      <Rect x={333} y={KB_TOP + 4 + 2 * 66 + 66} width={51} height={KB_KEY_H} radius={9} fill={KEY_DARK} />
      <Path x={345} y={KB_TOP + 4 + 2 * 66 + 66 + 14} d="M8 0 H28 V28 H8 L0 14 Z M13 8 L23 20 M23 8 L13 20" fill={NONE} stroke={{ color: ios.ink, width: 3, join: 'round', cap: 'round' }} />
      {/* bottom row */}
      <Rect x={6} y={y4} width={96} height={KB_KEY_H} radius={9} fill={KEY_DARK} />
      <PText x={6} y={y4 + (KB_KEY_H - 26 * 1.45) / 2} size={26} w={96} align="center">{rk ? '符號' : '123'}</PText>
      <Layer x={space.x} y={space.y}>
        <Rect width={space.width} height={space.height} radius={9} fill={spaceOn ? '#ffffff' : KEY} />
        <BoxText box={rel(space)} size={28} weight={400} color={spaceOn ? '#000000' : ios.ink}>{rk ? '空白' : 'space'}</BoxText>
      </Layer>
      <Rect x={288} y={y4} width={96} height={KB_KEY_H} radius={9} fill={KEY_DARK} />
      <PText x={288} y={y4 + (KB_KEY_H - 26 * 1.45) / 2} size={26} w={96} align="center">{rk ? '換行' : 'return'}</PText>
      {/* globe and microphone */}
      <Ellipse x={22} y={782} width={40} height={40} fill={NONE} stroke={{ color: ios.ink, width: 3 }} />
      <Path x={22} y={782} d="M20 0 V40 M0 20 H40 M20 0 Q6 20 20 40 M20 0 Q34 20 20 40" fill={NONE} stroke={{ color: ios.ink, width: 2 }} />
      <Rect x={346} y={778} width={20} height={32} radius={10} fill={NONE} stroke={{ color: ios.ink, width: 3 }} />
      <Path x={338} y={790} d="M0 6 Q0 28 18 28 Q36 28 36 6 M18 28 V40" fill={NONE} stroke={{ color: ios.ink, width: 3, cap: 'round' }} />
    </Layer>
  );
};

/** Scene 1: letters typed on the iPhone keyboard appear in a TextEdit window on the Mac. No pointer; the text follows the scene frame. */
export const Typing = ({ localFrame }: ScreenProps) => {
  const n = typedCount(localFrame);
  const shown = TYPED.slice(0, n);
  const lastAt = TYPE_START + TYPE_PITCH * (n - 1);
  const pressed = n > 0 && localFrame - lastAt < KEY_FLASH ? TYPED[n - 1] : undefined;
  const W = TEXTEDIT_WINDOW;
  const caretOn = Math.floor(localFrame / 15) % 2 === 0;
  return (
    <Layer id="screen-typing">
      <MacWindow rect={W} title="未命名">
        <Rect x={W.x + 2} y={W.y + 58} width={W.width - 4} height={W.height - 60} radius={24} fill="#1e1f23" />
        <Text id="typed" font={theme.font} weight={500} size={52} color={theme.ink} x={W.x + 60} y={W.y + 110} maxWidth={W.width - 120} lineHeight={1.5}
          chars={(_c: string, i: number) => (i === shown.length ? { color: caretOn ? '#2f7bf6' : NONE } : null)}>{shown + '|'}</Text>
      </MacWindow>
      <PhoneScreen origin={PHONE_ORIGIN_RIGHT}>
        <StatusBar />
        <Card rect={{ x: 24, y: 112, width: 342, height: 72 }} radius={18} />
        <Skel x={44} y={140} w={160} />
        <Keyboard pressed={pressed} />
      </PhoneScreen>
    </Layer>
  );
};
