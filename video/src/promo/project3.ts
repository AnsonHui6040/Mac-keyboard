/**
 * The camera maths of the promo's three 3D cuts (1 hero, 8 stage, 9 wide): where the three computers and the phone stand, the
 * cameras, the corner pins of the two extra screens and how bright each computer is. Pure: node can import it.
 */
import { MAC_PLANE, STAGE, bounds, cam21, heroCam, lerp3, planeCorners, type Cam, type Chain, type Corners, type Stage, type V3, LID_POS, LID_ROT, MAC_SCREEN_POS } from '../film/project.ts';
import { padFrame, seg, type SegId } from './timeline.ts';
import type { Host } from './events.ts';

export type Placement = { pos: V3; rot: V3 };

/** Windows: a desk monitor on a stand, 16:9. Linux: a laptop 0.8 the size of the Mac's, 16:10. Local coordinates, y up, +z toward the viewer. */
export const WIN_PLANE = { w: 4.2, h: 4.2 * 9 / 16 } as const;
export const WIN_SCREEN_POS: V3 = [0, 2.2, 0.07];
export const LIN_SCALE = 0.8;
export const LIN_PLANE = { w: MAC_PLANE.w * LIN_SCALE, h: MAC_PLANE.h * LIN_SCALE } as const;

/** Shot 9. The Mac and the phone stand exactly where shot 8 has them; Windows is the biggest and furthest right, Linux the smallest, far left and back. */
export const WIDE: { mac: Placement; win: Placement; linux: Placement; phone: Placement } = {
  mac: { pos: STAGE.macPos, rot: STAGE.macRot },
  phone: { pos: STAGE.phonePos, rot: STAGE.phoneRot },
  win: { pos: [2.35, 0, -2.3], rot: [0, -14, 0] },
  linux: { pos: [-3.7, 0, -1.2], rot: [0, 17, 0] },
};
export const wideStage = (): Stage => ({ macPos: WIDE.mac.pos, macRot: WIDE.mac.rot, phonePos: WIDE.phone.pos, phoneRot: WIDE.phone.rot });

export const winChain = (p: Placement = WIDE.win): Chain => [[p.pos, p.rot], [WIN_SCREEN_POS, [0, 0, 0]]];
export const linuxChain = (p: Placement = WIDE.linux): Chain => {
  const s = LIN_SCALE;
  return [[p.pos, p.rot], [[LID_POS[0] * s, LID_POS[1] * s, LID_POS[2] * s], LID_ROT], [[MAC_SCREEN_POS[0] * s, MAC_SCREEN_POS[1] * s, MAC_SCREEN_POS[2] * s], [0, 0, 0]]];
};
export const winPin = (cam: Cam, p: Placement = WIDE.win, mirror = false): Corners => planeCorners(cam, WIN_PLANE.w, WIN_PLANE.h, winChain(p), mirror);
export const linuxPin = (cam: Cam, p: Placement = WIDE.linux, mirror = false): Corners => planeCorners(cam, LIN_PLANE.w, LIN_PLANE.h, linuxChain(p), mirror);

/** Shot 9: one pull back at one speed, away from a fixed target. */
export const WIDE_CAM = { fov: 30, target: [-0.55, 1.0, 0.2] as V3, dir: [0.02, 0.07, 1] as V3, dist: [9.8, 10.8] as const };
const unit = (v: V3): V3 => { const l = Math.hypot(...v); return [v[0] / l, v[1] / l, v[2] / l]; };
export const wideCam = (frame: number): Cam => {
  const s = seg('9');
  const d = WIDE_CAM.dist[0] + ((WIDE_CAM.dist[1] - WIDE_CAM.dist[0]) * (frame - s.from)) / (s.to - 1 - s.from);
  const u = unit(WIDE_CAM.dir);
  return { fov: WIDE_CAM.fov, target: WIDE_CAM.target, position: [WIDE_CAM.target[0] + u[0] * d, WIDE_CAM.target[1] + u[1] * d, WIDE_CAM.target[2] + u[2] * d] };
};
/** Shot 1: the phone as in HERO; the three computers far behind, none of them in focus. */
export const heroCam3 = (frame: number): Cam => heroCam(frame);
export const FAR: { mac: Placement; win: Placement; linux: Placement } = {
  mac: { pos: [3.6, 0.7, -9.5], rot: [0, -22, 0] },
  win: { pos: [1.0, 0.5, -15], rot: [0, -8, 0] },
  linux: { pos: [-2.0, 0.3, -11], rot: [0, 18, 0] },
};
/** Shot 8: the old shot 21 camera, held at its last frame once the pad has finished. */
export const stageCam = (frame: number): Cam => cam21(Math.min(1229, padFrame(frame)));

/** How bright a computer is in a cut: the Mac is the one in focus; in shots 1 and 9 the other two are dimmed. */
export const brightness = (host: Host, segId: SegId): number => (segId === '1' || segId === '9') && host !== 'Mac' ? 0.45 : 1;

export { bounds, lerp3 };
