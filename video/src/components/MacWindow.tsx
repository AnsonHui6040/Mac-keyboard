import type { ReactNode } from 'react';
import { Ellipse, Layer, Rect, Text, dropShadow } from '@kinetographdev/core';
import type { Rect as Box } from '../screens/geometry.ts';
import { theme } from '../theme.ts';

export const TITLEBAR_H = 56;

/** A browser's address field in the title bar: a pill with the address centered in it. */
const AddressBar = ({ rect, address }: { rect: Box; address: string }) => {
  const w = Math.min(rect.width - 320, 1000);
  const x = rect.x + (rect.width - w) / 2;
  return (
    <Layer id="address-bar">
      <Rect x={x} y={rect.y + 8} width={w} height={40} radius={20} fill="#1b1c20" />
      <Text id="address-text" font={theme.font} weight={500} size={26} color={theme.ink} x={x} y={rect.y + 8 + (40 - 26 * 1.45) / 2} maxWidth={w} align="center">{address}</Text>
    </Layer>
  );
};

/**
 * A macOS window: rounded dark panel with traffic lights and a centered title. Children are drawn in canvas coordinates.
 * A browser window passes `address` instead of a title: the title bar then shows the address field.
 * `shadow` (default true) draws the drop shadow; the product intro turns it off because it bands on its dark desktop.
 */
export const MacWindow = ({ rect, title, address, children, fill = theme.dialog.fill, shadow = true }: { rect: Box; title: string; address?: string; children?: ReactNode; fill?: string; shadow?: boolean }) => (
  <Layer id="mac-window">
    <Layer id="window-frame" effects={shadow ? [dropShadow({ y: 18, blur: 54, color: theme.dialog.shadow })] : []}>
      <Rect x={rect.x} y={rect.y} width={rect.width} height={rect.height} radius={26} fill={fill} stroke={{ color: theme.dialog.edge, width: 2 }} />
    </Layer>
    <Rect x={rect.x + 2} y={rect.y + TITLEBAR_H} width={rect.width - 4} height={2} fill={theme.hairline} />
    {['#ff5f57', '#febc2e', '#28c840'].map((c, i) => (
      <Ellipse key={c} x={rect.x + 26 + i * 32} y={rect.y + 19} width={18} height={18} fill={c} />
    ))}
    {address ? <AddressBar rect={rect} address={address} /> : (
      <Text font={theme.font} weight={500} size={26} color={theme.muted} x={rect.x + 160} y={rect.y + 11} maxWidth={rect.width - 320} align="center">{title}</Text>
    )}
    {children}
  </Layer>
);
