/**
 * The Ubuntu screen, 1280 by 800, drawn live: a top bar with 活動 and the time, a dock of four rounded icons on the left, a text
 * editor window with the document. Greyscale only, no company mark and no wallpaper.
 */
import { Ellipse, Layer, Path, Rect, Text } from '@kinetographdev/core';
import { theme } from '../theme.ts';
import { roundedRectPath } from '../intro/shapes.ts';
import { DOC_LINE, MAC } from '../film/layout.ts';
import { LIN_DOCK, LIN_DOC, LIN_TOP } from './cameras.ts';

const NONE = '#00000000';
const WHITE = '#ffffff';
const MUTED = '#b4b5ba';
const DESKTOP = '#26272b';
const BAR = '#101113';
const DOCK = '#18191c';
const WINDOW = '#2e2f34';
const PAPER = '#222327';
const EDGE = '#4a4b50';

const TopBar = () => (
  <Layer>
    <Rect width={MAC.w} height={LIN_TOP} fill={BAR} />
    <Text font={theme.font} weight={500} size={18} color={WHITE} x={20} y={(LIN_TOP - 18 * DOC_LINE) / 2} maxWidth={100}>活動</Text>
    <Text font={theme.font} weight={500} size={18} color={WHITE} x={MAC.w / 2 - 50} y={(LIN_TOP - 18 * DOC_LINE) / 2} maxWidth={100} align="center">10:24</Text>
    {[0, 1, 2].map((i) => <Ellipse key={i} x={MAC.w - 120 + i * 32} y={(LIN_TOP - 14) / 2} width={14} height={14} fill="#8e8f95" />)}
  </Layer>
);

const Dock = () => {
  const icons = ['#a3a4aa', '#7d7e84', '#8e8f95', '#6f7076'];
  return (
    <Layer>
      <Rect y={LIN_TOP} width={LIN_DOCK} height={MAC.h - LIN_TOP} fill={DOCK} />
      {icons.map((c, i) => <Rect key={i} x={12} y={LIN_TOP + 24 + i * 72} width={48} height={48} radius={12} fill={c} />)}
      <Rect x={12} y={MAC.h - 72} width={48} height={48} radius={12} fill="#3a3b40" />
      <Ellipse x={4} y={LIN_TOP + 44} width={6} height={6} fill={WHITE} />
    </Layer>
  );
};

/** The Ubuntu screen at a frame. `lines` is the document, the caret is after the last character. */
export const LinuxScreen = ({ f, lines, caretOn }: { f: number; lines: string[]; caretOn: boolean }) => {
  void f;
  const d = LIN_DOC;
  const top = d.y + d.bar;
  return (
    <Layer>
      <Rect width={MAC.w} height={MAC.h} fill={DESKTOP} />
      <Rect x={d.x} y={d.y} width={d.w} height={d.h} radius={20} fill={WINDOW} stroke={{ color: EDGE, width: 2 }} />
      <Text font={theme.font} weight={700} size={22} color={WHITE} x={d.x + 180} y={d.y + (d.bar - 22 * DOC_LINE) / 2} maxWidth={d.w - 360} align="center">未命名文件</Text>
      <Rect x={d.x + 20} y={d.y + (d.bar - 30) / 2} width={30} height={30} radius={8} fill="#44454a" />
      <Ellipse x={d.x + d.w - 54} y={d.y + (d.bar - 28) / 2} width={28} height={28} fill="#44454a" />
      <Path x={d.x + d.w - 46} y={d.y + (d.bar - 12) / 2} d="M0 0 L12 12 M12 0 L0 12" stroke={{ color: MUTED, width: 2.5 }} />
      <Layer clip={{ kind: 'path', d: roundedRectPath(d.x + 2, top, d.w - 4, d.h - d.bar - 2, 18) }}>
        <Rect x={d.x + 2} y={top} width={d.w - 4} height={d.h - d.bar - 2} fill={PAPER} />
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
      <Dock />
      <TopBar />
    </Layer>
  );
};
