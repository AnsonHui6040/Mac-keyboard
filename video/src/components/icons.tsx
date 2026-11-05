import { Ellipse, Layer, Path, Rect } from '@kinetographdev/core';

/** All icons are drawn in a 100 x 100 box and scaled to `size`. (x, y) is the top-left. They are simple vector approximations, not the real artwork. */
const Box = ({ id, x, y, size, children }: { id?: string; x: number; y: number; size: number; children: React.ReactNode }) => (
  <Layer id={id} x={x} y={y}>
    <Layer scale={size / 100}>{children}</Layer>
  </Layer>
);

const NONE = '#00000000';
const stroke = (color: string, width: number) => ({ color, width, cap: 'round' as const, join: 'round' as const });

/** LocalDevVPN: dark tile with a green shield and a check mark. */
export const VpnIcon = ({ x, y, size, id }: { x: number; y: number; size: number; id?: string }) => (
  <Box id={id} x={x} y={y} size={size}>
    <Rect width={100} height={100} radius={23} fill="#14231a" />
    <Path d="M50 20 L77 30 V50 C77 67 66 79 50 85 C34 79 23 67 23 50 V30 Z" fill="#1e4a2e" stroke={stroke('#35c46a', 5)} />
    <Path d="M38 51 L47 60 L63 42" fill={NONE} stroke={stroke('#5fdc8f', 6)} />
  </Box>
);

/** SideStore: purple tile with two white bent arrows. */
export const SideStoreIcon = ({ x, y, size, id }: { x: number; y: number; size: number; id?: string }) => (
  <Box id={id} x={x} y={y} size={size}>
    <Rect width={100} height={100} radius={23} fill="#6d3fe8" />
    <Path d="M28 74 V48 Q28 38 38 38 H64" fill={NONE} stroke={stroke('#ffffff', 8)} />
    <Path d="M55 26 L68 38 L55 50" fill={NONE} stroke={stroke('#ffffff', 8)} />
  </Box>
);

/** iloader: dark tile with a green corner bracket and a down arrow. */
export const IloaderIcon = ({ x, y, size, id }: { x: number; y: number; size: number; id?: string }) => (
  <Box id={id} x={x} y={y} size={size}>
    <Rect width={100} height={100} radius={23} fill="#10261a" />
    <Path d="M26 24 V76 H74" fill={NONE} stroke={stroke('#2fd36d', 8)} />
    <Path d="M56 24 V54 M45 44 L56 55 L67 44" fill={NONE} stroke={stroke('#ffffff', 7)} />
  </Box>
);

/** iOS Settings: gray tile with a gear drawn as a ring with eight teeth. */
export const GearIcon = ({ x, y, size, id }: { x: number; y: number; size: number; id?: string }) => (
  <Box id={id} x={x} y={y} size={size}>
    <Rect width={100} height={100} radius={23} fill="#8e8e93" />
    {Array.from({ length: 8 }, (_, i) => (
      <Rect key={i} x={44} y={14} width={12} height={20} radius={4} fill="#e8e8ec" rotation={i * 45} origin={[0.5, 1.8]} />
    ))}
    <Ellipse x={26} y={26} width={48} height={48} fill="#e8e8ec" />
    <Ellipse x={38} y={38} width={24} height={24} fill="#8e8e93" />
  </Box>
);

/** A neutral app tile for the parts of a screen that are not the point. */
export const GrayIcon = ({ x, y, size, tone, id }: { x: number; y: number; size: number; tone: string; id?: string }) => (
  <Box id={id} x={x} y={y} size={size}>
    <Rect width={100} height={100} radius={23} fill={tone} />
  </Box>
);

// ---- line icons for the checklist (stroke only, ink color passed in)

export const PhoneLine = ({ x, y, size, color }: { x: number; y: number; size: number; color: string }) => (
  <Box x={x} y={y} size={size}>
    <Rect x={28} y={8} width={44} height={84} radius={10} fill={NONE} stroke={stroke(color, 5)} />
    <Rect x={42} y={15} width={16} height={5} radius={2.5} fill={color} />
  </Box>
);

export const LaptopLine = ({ x, y, size, color }: { x: number; y: number; size: number; color: string }) => (
  <Box x={x} y={y} size={size}>
    <Rect x={18} y={18} width={64} height={46} radius={6} fill={NONE} stroke={stroke(color, 5)} />
    <Path d="M8 76 H92" fill={NONE} stroke={stroke(color, 5)} />
  </Box>
);

export const CableLine = ({ x, y, size, color }: { x: number; y: number; size: number; color: string }) => (
  <Box x={x} y={y} size={size}>
    <Rect x={10} y={40} width={22} height={20} radius={4} fill={NONE} stroke={stroke(color, 5)} />
    <Path d="M32 50 H62" fill={NONE} stroke={stroke(color, 5)} />
    <Rect x={62} y={36} width={28} height={28} radius={6} fill={NONE} stroke={stroke(color, 5)} />
    <Path d="M70 50 H82" fill={NONE} stroke={stroke(color, 5)} />
  </Box>
);

export const WifiLine = ({ x, y, size, color }: { x: number; y: number; size: number; color: string }) => (
  <Box x={x} y={y} size={size}>
    <Path d="M14 40 Q50 8 86 40" fill={NONE} stroke={stroke(color, 5)} />
    <Path d="M28 55 Q50 36 72 55" fill={NONE} stroke={stroke(color, 5)} />
    <Path d="M40 69 Q50 61 60 69" fill={NONE} stroke={stroke(color, 5)} />
    <Ellipse x={45} y={76} width={10} height={10} fill={color} />
  </Box>
);

export const PersonLine = ({ x, y, size, color }: { x: number; y: number; size: number; color: string }) => (
  <Box x={x} y={y} size={size}>
    <Ellipse x={34} y={14} width={32} height={32} fill={NONE} stroke={stroke(color, 5)} />
    <Path d="M16 88 Q16 56 50 56 Q84 56 84 88" fill={NONE} stroke={stroke(color, 5)} />
  </Box>
);

/** A padlock: body, keyhole and a shackle. */
export const LockIcon = ({ x, y, size, color, accent }: { x: number; y: number; size: number; color: string; accent: string }) => (
  <Box id="lock" x={x} y={y} size={size}>
    <Path d="M28 46 V32 Q28 10 50 10 Q72 10 72 32 V46" fill={NONE} stroke={stroke(color, 8)} />
    <Rect x={16} y={44} width={68} height={48} radius={12} fill={color} />
    <Ellipse x={44} y={58} width={12} height={12} fill={accent} />
    <Rect x={47.5} y={66} width={5} height={14} radius={2.5} fill={accent} />
  </Box>
);

/** A circle with a diagonal bar, for what must not be done. */
export const NoMark = ({ x, y, size, color }: { x: number; y: number; size: number; color: string }) => (
  <Box x={x} y={y} size={size}>
    <Ellipse x={10} y={10} width={80} height={80} fill={NONE} stroke={stroke(color, 8)} />
    <Path d="M24 76 L76 24" fill={NONE} stroke={stroke(color, 8)} />
  </Box>
);
