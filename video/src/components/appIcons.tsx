import { Ellipse, Layer, Path, Rect } from '@kinetographdev/core';

/** Vector approximations drawn in a 100 x 100 box and scaled to `size`; (x, y) is the top-left. Not the real artwork. */
const Box = ({ id, x, y, size, opacity, children }: { id?: string; x: number; y: number; size: number; opacity?: number; children: React.ReactNode }) => (
  <Layer id={id} x={x} y={y} opacity={opacity}>
    <Layer scale={size / 100}>{children}</Layer>
  </Layer>
);

const NONE = '#00000000';
const arc = (color: string, width: number) => ({ color, width, cap: 'round' as const, join: 'round' as const });

/** Remote Keyboard (iPhone app and Mac Receiver): dark tile, a white rounded rectangle and three radio arcs. */
export const RkIcon = ({ x, y, size, id, opacity }: { x: number; y: number; size: number; id?: string; opacity?: number }) => (
  <Box id={id} x={x} y={y} size={size} opacity={opacity}>
    <Rect width={100} height={100} radius={23} fill="#4a4a4f" />
    <Rect x={20} y={46} width={46} height={32} radius={8} fill="#ffffff" />
    <Path d="M58 30 Q76 30 76 48" fill={NONE} stroke={arc('#ffffff', 5)} />
    <Path d="M58 19 Q87 19 87 48" fill={NONE} stroke={arc('#ffffff', 5)} />
  </Box>
);

/** A .zip file: a light page with a zipper down the middle. */
export const ZipIcon = ({ x, y, size, id, opacity }: { x: number; y: number; size: number; id?: string; opacity?: number }) => (
  <Box id={id} x={x} y={y} size={size} opacity={opacity}>
    <Path d="M20 6 H62 L82 26 V92 Q82 96 78 96 H24 Q20 96 20 92 Z" fill="#d9dadd" stroke={arc('#8d8f94', 3)} />
    <Path d="M62 6 V26 H82" fill="#b9bbc0" stroke={arc('#8d8f94', 3)} />
    {[0, 1, 2, 3, 4, 5].map((i) => (
      <Rect key={i} x={i % 2 === 0 ? 45 : 51} y={14 + i * 10} width={6} height={7} fill="#55575b" />
    ))}
    <Rect x={42} y={70} width={18} height={14} radius={4} fill="#55575b" />
  </Box>
);

/** A plain document with a folded corner and a label tile; `tone` colors the tile. */
export const DocIcon = ({ x, y, size, tone = '#0a84ff', id, opacity }: { x: number; y: number; size: number; tone?: string; id?: string; opacity?: number }) => (
  <Box id={id} x={x} y={y} size={size} opacity={opacity}>
    <Path d="M20 6 H62 L82 26 V92 Q82 96 78 96 H24 Q20 96 20 92 Z" fill="#e8e8ec" stroke={arc('#9a9ba1', 3)} />
    <Path d="M62 6 V26 H82" fill="#c8c8cc" stroke={arc('#9a9ba1', 3)} />
    <Rect x={30} y={52} width={42} height={28} radius={6} fill={tone} />
  </Box>
);

/** A small blue folder for the Finder sidebar. */
export const FolderIcon = ({ x, y, size, id }: { x: number; y: number; size: number; id?: string }) => (
  <Box id={id} x={x} y={y} size={size}>
    <Path d="M6 24 Q6 16 14 16 H38 L46 26 H86 Q94 26 94 34 V76 Q94 84 86 84 H14 Q6 84 6 76 Z" fill="#4aa3ff" />
    <Path d="M6 36 H94" fill={NONE} stroke={arc('#8cc4ff', 3)} />
  </Box>
);

/** A white check mark on a green disc. */
export const CheckDisc = ({ x, y, size, id, opacity }: { x: number; y: number; size: number; id?: string; opacity?: number }) => (
  <Box id={id} x={x} y={y} size={size} opacity={opacity}>
    <Ellipse width={100} height={100} fill="#30d158" />
    <Path d="M28 52 L44 68 L74 34" fill={NONE} stroke={arc('#ffffff', 10)} />
  </Box>
);
