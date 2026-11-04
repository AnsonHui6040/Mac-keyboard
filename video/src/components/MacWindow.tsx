import type { ReactNode } from 'react';
import { Ellipse, Layer, Rect, Text, dropShadow } from '@kinetographdev/core';
import type { Rect as Box } from '../screens/geometry.ts';
import { theme } from '../theme.ts';

export const TITLEBAR_H = 56;

/** A macOS window: rounded dark panel with traffic lights and a centered title. Children are drawn in canvas coordinates. */
export const MacWindow = ({ rect, title, children, fill = theme.dialog.fill }: { rect: Box; title: string; children?: ReactNode; fill?: string }) => (
  <Layer id="mac-window">
    <Layer id="window-frame" effects={[dropShadow({ y: 18, blur: 54, color: theme.dialog.shadow })]}>
      <Rect x={rect.x} y={rect.y} width={rect.width} height={rect.height} radius={26} fill={fill} stroke={{ color: theme.dialog.edge, width: 2 }} />
    </Layer>
    <Rect x={rect.x + 2} y={rect.y + TITLEBAR_H} width={rect.width - 4} height={2} fill={theme.hairline} />
    {['#ff5f57', '#febc2e', '#28c840'].map((c, i) => (
      <Ellipse key={c} x={rect.x + 26 + i * 32} y={rect.y + 19} width={18} height={18} fill={c} />
    ))}
    <Text font={theme.font} weight={500} size={26} color={theme.muted} x={rect.x + 160} y={rect.y + 11} maxWidth={rect.width - 320} align="center">{title}</Text>
    {children}
  </Layer>
);
