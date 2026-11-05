/** The finger rings. A ring is a white circle; it shrinks and sends out a second ring while it presses, and fills in when it carries something. */
import { Ellipse, Layer } from '@kinetographdev/core';
import { fingerAt } from './state.ts';
import { trackAt } from './trackpad.ts';

const NONE = '#00000000';

export const Ring = ({ x, y, press, solid = 0, opacity = 1, size, line }: { x: number; y: number; press: number; solid?: number; opacity?: number; size: number; line: number }) => (
  <Layer x={x} y={y} opacity={opacity}>
    <Ellipse x={-size * 0.66} y={-size * 0.66} width={size * 1.32} height={size * 1.32} fill={NONE} stroke={{ color: '#ffffff', width: line, }} opacity={press * 0.7} scale={0.6 + 0.4 * press} origin="center" />
    <Ellipse x={-size / 2} y={-size / 2} width={size} height={size} fill={solid > 0 ? '#ffffff59' : NONE} stroke={{ color: '#ffffff', width: line }} scale={1 - 0.12 * press} origin="center" />
  </Layer>
);

/** The rings on the phone at a frame, local phone coordinates: the keyboard finger, or the pad fingers of shot 21. */
export const PhoneRings = ({ f, size = 60, line = 5, dy = 0 }: { f: number; size?: number; line?: number; dy?: number }) => {
  const t = f >= 849 && f < 1230 ? trackAt(f) : null;
  const k = fingerAt(f);
  return (
    <Layer>
      {k.visible && <Ring x={k.x} y={k.y + dy} press={k.press} opacity={k.opacity} size={size} line={line} />}
      {t && t.fingers.map((g, i) => <Ring key={i} x={g.x} y={g.y + dy} press={g.down ? 1 : 0} solid={t.ringSolid} opacity={t.fingerOpacity} size={size} line={line} />)}
    </Layer>
  );
};
