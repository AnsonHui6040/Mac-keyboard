import type { ReactNode } from 'react';
import { Ellipse, Layer, Path, Rect, Text, dropShadow, linearGradient } from '@kinetographdev/core';
import type { Rect as Box } from '../screens/geometry.ts';
import { theme } from '../theme.ts';

/** Dialog panel with its help button. Children are drawn in canvas coordinates on top of it. */
export const MacDialog = ({ rect, children }: { rect: Box; children?: ReactNode }) => (
  <>
    <Layer id="dialog" x={rect.x} y={rect.y} effects={[dropShadow({ y: 18, blur: 54, color: theme.dialog.shadow })]}>
      <Rect width={rect.width} height={rect.height} radius={theme.dialog.radius} fill={theme.dialog.fill} stroke={{ color: theme.dialog.edge, width: 2 }} />
      <Ellipse x={rect.width - 76} y={26} width={48} height={48} fill={theme.neutralBtn.fill} />
      <Text font={theme.font} weight={500} size={28} color={theme.neutralBtn.ink} x={rect.width - 76} y={31} maxWidth={48} align="center">?</Text>
    </Layer>
    {children}
  </>
);

/** Pill button. Neutral by default; pass `blue` for the macOS accent button. Layer id is `btn-<target>`. */
export const MacButton = ({ target, rect, label, blue = false, size = 30 }: { target: string; rect: Box; label: string; blue?: boolean; size?: number }) => (
  <Layer id={`btn-${target}`} x={rect.x} y={rect.y}>
    <Rect width={rect.width} height={rect.height} radius={rect.height / 2} fill={blue ? theme.blue : theme.neutralBtn.fill} />
    <Text font={theme.font} weight={500} size={size} color={blue ? '#ffffff' : theme.neutralBtn.ink} y={(rect.height - size * 1.45) / 2} maxWidth={rect.width} align="center">{label}</Text>
  </Layer>
);

/** Dialog title text, Bold 32, top-left at (x, y). Use \n for the line break. */
export const DialogTitle = ({ x, y, children }: { x: number; y: number; children: string }) => (
  <Text id="dialog-title" font={theme.font} weight={700} size={32} color={theme.dialog.title} x={x} y={y} maxWidth={510} lineHeight={1.35}>{children}</Text>
);

/** Gatekeeper warning icon: gray dial with a yellow warning triangle. Drawn as vectors. (x, y) is its top-left. */
export const GatekeeperIcon = ({ x, y }: { x: number; y: number }) => (
  <Layer id="icon" x={x} y={y}>
    <Rect width={118} height={118} radius={26} fill={linearGradient(['#d9dadd', '#8d8f94'])} />
    <Ellipse x={17} y={17} width={84} height={84} fill="#6f7176" />
    <Ellipse x={31} y={31} width={56} height={56} fill="#b6b8bc" />
    <Ellipse x={49} y={49} width={20} height={20} fill="#55575b" />
    <Path x={70} y={68} d="M32 2 L62 54 Q64 60 57 60 L7 60 Q0 60 2 54 Z" fill="#f4c430" />
    <Rect x={99} y={86} width={6} height={22} radius={3} fill="#3a3320" />
    <Rect x={99} y={112} width={6} height={7} radius={3} fill="#3a3320" />
  </Layer>
);

/** Touch ID icon: gray disc with concentric fingerprint arches. (x, y) is its top-left. */
export const TouchIdIcon = ({ x, y }: { x: number; y: number }) => {
  const c = 59;
  const cy = 50;
  const arch = (r: number, leg: number) => `M${c - r} ${cy + leg} L${c - r} ${cy} A${r} ${r} 0 0 1 ${c + r} ${cy} L${c + r} ${cy + leg}`;
  const arches: [number, number][] = [
    [7, 30],
    [16, 26],
    [25, 22],
    [34, 14],
    [43, 6],
  ];
  return (
    <Layer id="icon" x={x} y={y}>
      <Ellipse width={118} height={118} fill={linearGradient(['#d9dadd', '#8d8f94'])} />
      {arches.map(([r, leg]) => (
        <Path key={r} d={arch(r, leg)} fill="#00000000" stroke={{ color: '#4a4b50', width: 5 }} />
      ))}
    </Layer>
  );
};
