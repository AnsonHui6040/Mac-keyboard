import type { ReactNode } from 'react';
import { Ellipse, Layer, Path, Rect, Text } from '@kinetographdev/core';
import type { Rect as Box } from '../screens/geometry.ts';
import { ALERT_X, ALERT_W, ALERT_BTN_H, PHONE_MIN_TEXT, type AlertLayout } from '../screens/layouts.ts';
import { theme } from '../theme.ts';

/** iOS dark-mode colors for the drawn iPhone screens. */
export const ios = {
  bg: '#000000',
  card: '#1c1c1e',
  card2: '#2c2c2e',
  sep: '#38383a',
  ink: '#ffffff',
  muted: '#98989f',
  blue: '#0a84ff',
  green: '#30d158',
  red: '#ff453a',
  gray: '#3a3a3e',
  none: '#00000000',
} as const;

/** Line height factor of Noto Sans TC: a line box is about 1.45 x the size. */
export const LINE = 1.45;

type TextProps = { id?: string; x: number; y: number; size: number; weight?: 400 | 500 | 700; color?: string; w?: number; align?: 'left' | 'center' | 'right'; lineHeight?: number; chars?: (ch: string, i: number, n: number) => { color?: string } | null; children: string };

/** Text on an iPhone screen. Throws below PHONE_MIN_TEXT so a too-small label cannot be drawn by accident. */
export const PText = ({ size, weight = 500, color = ios.ink, w, align = 'left', children, ...rest }: TextProps) => {
  if (size < PHONE_MIN_TEXT) throw new Error(`iPhone text ${size} is below ${PHONE_MIN_TEXT}: ${children}`);
  return (
    <Text font={theme.font} weight={weight} size={size} color={color} maxWidth={w} align={align} {...rest}>
      {children}
    </Text>
  );
};

/** One line of text centered vertically in `box`, with `padX` on both sides. */
export const BoxText = ({ box, size, weight, color, align = 'center', padX = 0, padRight = 0, children }: { box: Box; size: number; weight?: 400 | 500 | 700; color?: string; align?: 'left' | 'center' | 'right'; padX?: number; padRight?: number; children: string }) => (
  <PText x={box.x + padX} y={box.y + (box.height - size * LINE) / 2} size={size} weight={weight} color={color} w={box.width - padX * 2 - padRight} align={align}>
    {children}
  </PText>
);

/** A tappable target: layer `btn-<target>` whose bounds are exactly `rect`. Children are drawn relative to the rect's top-left. */
export const Btn = ({ target, rect, children }: { target: string; rect: Box; children?: ReactNode }) => (
  <Layer id={`btn-${target}`} x={rect.x} y={rect.y}>
    <Rect width={rect.width} height={rect.height} fill={ios.none} />
    {children}
  </Layer>
);

export const Card = ({ rect, fill = ios.card, radius = 24 }: { rect: Box; fill?: string; radius?: number }) => (
  <Rect x={rect.x} y={rect.y} width={rect.width} height={rect.height} radius={radius} fill={fill} />
);

/** A gray stand-in line for body text that does not matter. */
export const Skel = ({ x, y, w, tone = theme.skeleton.color }: { x: number; y: number; w: number; tone?: string }) => (
  <Rect x={x} y={y} width={w} height={theme.skeleton.height} radius={theme.skeleton.radius} fill={tone} />
);

export const Hair = ({ x, y, w }: { x: number; y: number; w: number }) => <Rect x={x} y={y} width={w} height={1.5} fill={ios.sep} />;

export const Chevron = ({ x, y, color = ios.muted }: { x: number; y: number; color?: string }) => (
  <Path x={x} y={y} d="M0 0 L12 12 L0 24" fill={ios.none} stroke={{ color, width: 4, cap: 'round', join: 'round' }} />
);

export const BackChevron = ({ x, y }: { x: number; y: number }) => (
  <Path x={x} y={y} d="M14 0 L0 14 L14 28" fill={ios.none} stroke={{ color: ios.blue, width: 5, cap: 'round', join: 'round' }} />
);

/** Time, signal bars and battery. Drawn on every screen; the island is added by IPhoneFrame. */
export const StatusBar = () => (
  <Layer id="status-bar">
    <PText x={44} y={12} size={26} weight={700}>9:41</PText>
    {[0, 1, 2, 3].map((i) => (
      <Rect key={i} x={262 + i * 9} y={34 - i * 5} width={6} height={8 + i * 5} radius={2} fill={ios.ink} />
    ))}
    <Rect x={308} y={20} width={44} height={22} radius={7} fill={ios.none} stroke={{ color: '#ffffff80', width: 2 }} />
    <Rect x={311} y={23} width={30} height={16} radius={4.5} fill={ios.ink} />
  </Layer>
);

/** Large left title ("設定") with the status bar above. */
export const LargeTitle = ({ children, y = 70 }: { children: string; y?: number }) => (
  <PText x={24} y={y} size={42} weight={700}>{children}</PText>
);

/** Navigation bar: back chevron on the left, centered title. */
export const NavBar = ({ title }: { title: string }) => (
  <Layer id="navbar">
    <BackChevron x={22} y={70} />
    <PText x={60} y={66} size={30} weight={700} w={270} align="center">{title}</PText>
  </Layer>
);

/** A grouped list row: optional icon tone, `label` (or gray line) and a chevron. */
export const Row = ({ rect, label, icon, line, chevron = true, color = ios.ink, weight = 500 }: { rect: Box; label?: string; icon?: string; line?: number; chevron?: boolean; color?: string; weight?: 400 | 500 | 700 }) => (
  <Layer>
    {icon && <Rect x={rect.x + 18} y={rect.y + 16} width={40} height={40} radius={10} fill={icon} />}
    {label && <PText x={rect.x + (icon ? 74 : 20)} y={rect.y + (rect.height - 28 * LINE) / 2} size={28} weight={weight} color={color}>{label}</PText>}
    {line !== undefined && <Skel x={rect.x + (icon ? 74 : 20)} y={rect.y + (rect.height - theme.skeleton.height) / 2} w={line} />}
    {chevron && <Chevron x={rect.x + rect.width - 36} y={rect.y + 24} />}
  </Layer>
);

/** Rows of a grouped card: draws the card, hairlines between rows, and calls `render(rowRect, index)` for each. */
export const Group = ({ rect, rows, render }: { rect: Box; rows: number; render: (r: Box, i: number) => ReactNode }) => {
  const h = rect.height / rows;
  return (
    <Layer>
      <Card rect={rect} />
      {Array.from({ length: rows }, (_, i) => {
        const r = { x: rect.x, y: rect.y + i * h, width: rect.width, height: h };
        return (
          <Layer key={i}>
            {render(r, i)}
            {i > 0 && <Hair x={rect.x + 20} y={r.y} w={rect.width - 20} />}
          </Layer>
        );
      })}
    </Layer>
  );
};

/** iOS switch. `progress` 0 is off, 1 is on. */
export const Toggle = ({ x, y, progress }: { x: number; y: number; progress: number }) => {
  const p = Math.min(1, Math.max(0, progress));
  return (
    <Layer id="toggle" x={x} y={y}>
      <Rect width={62} height={38} radius={19} fill={p > 0.5 ? ios.green : '#3a3a3e'} />
      <Ellipse x={3 + 24 * p} y={3} width={32} height={32} fill="#ffffff" />
    </Layer>
  );
};

/** Dims the screen behind an alert. `opacity` is the fade factor. */
export const Scrim = ({ opacity }: { opacity: number }) => <Rect id="scrim" x={0} y={0} width={390} height={844} fill="#000000" opacity={0.55 * opacity} />;

export type AlertButton = { target?: string; label: string; weight?: 400 | 500 | 700; color?: string };

/**
 * A centered iOS alert (design: dark material). Title text (or none), two gray body lines, buttons per `layout`.
 * A button with a `target` is a `btn-<target>` layer; the rest are drawn plain.
 */
export const Alert = ({ layout, title, buttons, stacked, body = true, opacity = 1, titleSkel = false, message }: { layout: AlertLayout; title?: string; buttons: AlertButton[]; stacked: boolean; body?: boolean; opacity?: number; titleSkel?: boolean; message?: { text: string; color: string; from: number; codeColor: string } }) => {
  const c = layout.card;
  return (
    <Layer id="alert" opacity={opacity}>
      <Scrim opacity={opacity} />
      <Rect x={c.x} y={c.y} width={c.width} height={c.height} radius={30} fill={ios.card2} stroke={{ color: '#48484a', width: 1.5 }} />
      {title && <PText x={c.x + 24} y={layout.titleY} size={28} weight={700} w={c.width - 48} align="center" lineHeight={1.35}>{title}</PText>}
      {titleSkel && <Skel x={c.x + 75} y={layout.titleY + 12} w={c.width - 150} />}
      {message && (
        <PText x={c.x + 24} y={layout.titleY} size={26} weight={500} w={c.width - 48} align="center" lineHeight={1.46}
          chars={(_ch, i) => (i >= message.from ? { color: message.codeColor } : null)}>{message.text}</PText>
      )}
      {body && (
        <Layer>
          <Skel x={c.x + 40} y={layout.bodyY} w={c.width - 80} />
          <Skel x={c.x + 70} y={layout.bodyY + 38} w={c.width - 140} />
        </Layer>
      )}
      {buttons.map((b, i) => {
        const r = layout.buttons[i];
        const content = <BoxText box={{ x: 0, y: 0, width: r.width, height: r.height }} padRight={stacked ? (b.label.length > 4 ? 70 : 0) : r.width * 0.3} size={28} weight={b.weight ?? 500} color={b.color ?? ios.blue}>{b.label}</BoxText>;
        return (
          <Layer key={i}>
            <Hair x={stacked ? c.x : r.x} y={r.y} w={r.width} />
            {!stacked && i > 0 && <Rect x={r.x} y={r.y} width={1.5} height={ALERT_BTN_H} fill={ios.sep} />}
            {b.target ? <Btn target={b.target} rect={r}>{content}</Btn> : <Layer x={r.x} y={r.y}>{content}</Layer>}
          </Layer>
        );
      })}
    </Layer>
  );
};

export { ALERT_X, ALERT_W };

/** Home screen app grid: gray tiles, the named tiles drawn by the caller through `special`. */
export const HomeGrid = ({ special }: { special: (col: number, row: number, x: number, y: number) => ReactNode | undefined }) => {
  const tones = ['#3a3a3e', '#47474c', '#2f3a4a', '#4a3f3a', '#3a4a3f'];
  const cells: ReactNode[] = [];
  for (let row = 0; row < 5; row++) {
    for (let col = 0; col < 4; col++) {
      const x = 30 + col * 88;
      const y = 100 + row * 130;
      const s = special(col, row, x, y);
      cells.push(
        <Layer key={`${col}-${row}`}>
          {s ?? (
            <Layer>
              <Rect x={x} y={y} width={66} height={66} radius={16} fill={tones[(col * 3 + row * 2) % tones.length]} />
              <Skel x={x + 15} y={y + 78} w={36} />
            </Layer>
          )}
        </Layer>,
      );
    }
  }
  return (
    <Layer id="home-grid">
      {cells}
      <Rect x={16} y={742} width={358} height={90} radius={32} fill="#ffffff22" />
      {[0, 1, 2, 3].map((i) => (
        <Rect key={i} x={30 + i * 88} y={754} width={66} height={66} radius={16} fill={tones[(i + 1) % tones.length]} />
      ))}
    </Layer>
  );
};
