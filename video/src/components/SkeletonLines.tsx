import { Layer, Rect } from '@kinetographdev/core';
import { theme } from '../theme.ts';

/** Gray placeholder lines standing in for body text. (x, y) is the top-left of the first line. */
export const SkeletonLines = ({ x, y, widths, id }: { x: number; y: number; widths: number[]; id?: string }) => (
  <Layer id={id} x={x} y={y}>
    {widths.map((w, i) => (
      <Rect key={i} y={i * theme.skeleton.pitch} width={w} height={theme.skeleton.height} radius={theme.skeleton.radius} fill={theme.skeleton.color} />
    ))}
  </Layer>
);
