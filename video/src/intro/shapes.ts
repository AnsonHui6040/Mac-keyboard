/** SVG path helpers for clips and icons. Pure. */
export const roundedRectPath = (x: number, y: number, w: number, h: number, r: number): string =>
  `M${x + r} ${y} H${x + w - r} A${r} ${r} 0 0 1 ${x + w} ${y + r} V${y + h - r} A${r} ${r} 0 0 1 ${x + w - r} ${y + h} H${x + r} A${r} ${r} 0 0 1 ${x} ${y + h - r} V${y + r} A${r} ${r} 0 0 1 ${x + r} ${y} Z`;

/** The keyboard panel of a screenshot: square top below `top`, the big round corners of the phone at the bottom. */
export const panelPath = (top: number, w: number, h: number, r: number): string =>
  `M0 ${top} H${w} V${h - r} A${r} ${r} 0 0 1 ${w - r} ${h} H${r} A${r} ${r} 0 0 1 0 ${h - r} Z`;

export const rectPath = (x: number, y: number, w: number, h: number): string => `M${x} ${y} H${x + w} V${y + h} H${x} Z`;

export const polyline = (pts: readonly (readonly [number, number])[]): string => pts.map(([x, y], i) => `${i === 0 ? 'M' : 'L'}${x.toFixed(1)} ${y.toFixed(1)}`).join(' ');
