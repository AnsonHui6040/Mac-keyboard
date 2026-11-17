/**
 * The Windows screen, 1280 by 800, drawn live: a dark desktop, a Notepad window with the document, the taskbar with five plain
 * icons. Greyscale only, no company mark and no wallpaper; the start key is a plain rounded square.
 */
import { Layer, Path, Rect, Text } from '@kinetographdev/core';
import { theme } from '../theme.ts';
import { roundedRectPath } from '../intro/shapes.ts';
import { DOC_LINE, MAC } from '../film/layout.ts';
import { WIN_DOC, WIN_TASKBAR } from './cameras.ts';

const NONE = '#00000000';
const WHITE = '#ffffff';
const MUTED = '#b4b5ba';
const DESKTOP = '#202226';
const TASKBAR = '#141518';
const WINDOW = '#2b2c31';
const PAPER = '#1f2024';
const EDGE = '#4a4b50';
const MENU_ITEMS = ['檔案', '編輯', '格式', '檢視', '說明'] as const;

const Caption = ({ x, y, w, h }: { x: number; y: number; w: number; h: number }) => (
  <Layer>
    <Path x={x + w - 168} y={y + h / 2} d="M0 0 H18" stroke={{ color: MUTED, width: 2.5 }} />
    <Rect x={x + w - 112} y={y + h / 2 - 9} width={18} height={18} fill={NONE} stroke={{ color: MUTED, width: 2.5 }} />
    <Path x={x + w - 56} y={y + h / 2 - 10} d="M0 0 L20 20 M20 0 L0 20" stroke={{ color: MUTED, width: 2.5 }} />
  </Layer>
);

const Taskbar = () => {
  const icons = ['#8e8f95', '#6f7076', '#a3a4aa', '#5d5e64', '#7d7e84'];
  const size = 32;
  const gap = 24;
  const total = 6 * size + 5 * gap;
  const x0 = (MAC.w - total) / 2;
  const y = WIN_TASKBAR.y + (WIN_TASKBAR.h - size) / 2;
  return (
    <Layer>
      <Rect y={WIN_TASKBAR.y} width={MAC.w} height={WIN_TASKBAR.h} fill={TASKBAR} />
      <Rect y={WIN_TASKBAR.y} width={MAC.w} height={2} fill="#2a2b30" />
      <Rect x={x0} y={y} width={size} height={size} radius={9} fill="#d9dadf" />
      {icons.map((c, i) => <Rect key={i} x={x0 + (i + 1) * (size + gap)} y={y} width={size} height={size} radius={9} fill={c} />)}
      <Rect x={x0 + 2 * (size + gap)} y={WIN_TASKBAR.y + WIN_TASKBAR.h - 6} width={size} height={4} radius={2} fill={WHITE} />
    </Layer>
  );
};

/** The Windows screen at a frame. `lines` is the document, the caret is after the last character. */
export const WinScreen = ({ f, lines, caretOn }: { f: number; lines: string[]; caretOn: boolean }) => {
  void f;
  const d = WIN_DOC;
  const top = d.y + d.bar + d.menu;
  let mx = d.x + 24;
  return (
    <Layer>
      <Rect width={MAC.w} height={MAC.h} fill={DESKTOP} />
      <Rect x={d.x} y={d.y} width={d.w} height={d.h} radius={14} fill={WINDOW} stroke={{ color: EDGE, width: 2 }} />
      <Rect x={d.x + 22} y={d.y + (d.bar - 22) / 2} width={22} height={22} radius={5} fill="#6f7076" />
      <Text font={theme.font} weight={400} size={22} color={WHITE} x={d.x + 62} y={d.y + (d.bar - 22 * DOC_LINE) / 2} maxWidth={500}>未命名 - 記事本</Text>
      <Caption x={d.x} y={d.y} w={d.w} h={d.bar} />
      {MENU_ITEMS.map((t) => {
        const el = <Text key={t} font={theme.font} weight={400} size={22} color={MUTED} x={mx} y={d.y + d.bar + (d.menu - 22 * DOC_LINE) / 2} maxWidth={90}>{t}</Text>;
        mx += 22 * [...t].length + 36;
        return el;
      })}
      <Layer clip={{ kind: 'path', d: roundedRectPath(d.x + 2, top, d.w - 4, d.h - d.bar - d.menu - 2, 12) }}>
        <Rect x={d.x + 2} y={top} width={d.w - 4} height={d.h - d.bar - d.menu - 2} fill={PAPER} />
        {lines.map((l, i) => {
          const last = i === lines.length - 1;
          const shown = last ? `${l}|` : l;
          if (shown === '') return null;
          return (
            <Text key={i} font={theme.font} weight={500} size={d.size} color={WHITE} x={d.textX} y={d.textY + i * d.size * DOC_LINE} maxWidth={d.w - 120}
              chars={(_c: string, k: number) => (last && k === l.length ? { color: caretOn ? WHITE : NONE } : null)}>{shown}</Text>
          );
        })}
      </Layer>
      <Taskbar />
    </Layer>
  );
};
