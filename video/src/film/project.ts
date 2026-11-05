/**
 * The camera maths of the 3D shots. A live 2D layer is corner-pinned to the projected corners of the screen plane, so the maths
 * here is the engine's own: Rx * Ry * Rz for an object, the camera looking down its own -z, vertical fov. Pure: node can import it.
 */
export type V3 = [number, number, number];
export type Cam = { fov: number; position: V3; target: V3 };
export type Pt = [number, number];
export type Corners = { topLeft: Pt; topRight: Pt; bottomRight: Pt; bottomLeft: Pt };

export const W = 1920;
export const H = 1080;
const add = (a: V3, b: V3): V3 => [a[0] + b[0], a[1] + b[1], a[2] + b[2]];
const sub = (a: V3, b: V3): V3 => [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
const dot = (a: V3, b: V3): number => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
const cross = (a: V3, b: V3): V3 => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
const norm = (a: V3): V3 => { const l = Math.hypot(...a); return [a[0] / l, a[1] / l, a[2] / l]; };
const rad = (d: number): number => (d * Math.PI) / 180;
const lerp = (a: number, b: number, u: number): number => a + (b - a) * u;
export const lerp3 = (a: V3, b: V3, u: number): V3 => [lerp(a[0], b[0], u), lerp(a[1], b[1], u), lerp(a[2], b[2], u)];

/** Rx * Ry * Rz, as the engine composes an object's rotation. */
export const rotate = (p: V3, [rx, ry, rz]: V3): V3 => {
  let [x, y, z] = p;
  [x, y] = [x * Math.cos(rad(rz)) - y * Math.sin(rad(rz)), x * Math.sin(rad(rz)) + y * Math.cos(rad(rz))];
  [x, z] = [x * Math.cos(rad(ry)) + z * Math.sin(rad(ry)), -x * Math.sin(rad(ry)) + z * Math.cos(rad(ry))];
  [y, z] = [y * Math.cos(rad(rx)) - z * Math.sin(rad(rx)), y * Math.sin(rad(rx)) + z * Math.cos(rad(rx))];
  return [x, y, z];
};

export const forward = (cam: Cam): V3 => norm(sub(cam.target, cam.position));
/** A world point on the 1920 by 1080 frame. */
export const project = (cam: Cam, p: V3): Pt => {
  const f = forward(cam);
  const r = norm(cross(f, [0, 1, 0]));
  const u = cross(r, f);
  const d = sub(p, cam.position);
  const focal = H / 2 / Math.tan(rad(cam.fov) / 2);
  const z = dot(d, f);
  return [W / 2 + (focal * dot(d, r)) / z, H / 2 - (focal * dot(d, u)) / z];
};

/** A chain of [position, rotation] parents, outermost first. */
export type Chain = [V3, V3][];
export const toWorld = (chain: Chain, p: V3, mirror = false): V3 => {
  const w = chain.reduceRight<V3>((q, [pos, rot]) => add(rotate(q, rot), pos), p);
  return mirror ? [w[0], -w[1], w[2]] : w;
};
/** Frame corners of a plane of w by h whose centre is the origin of the chain. `mirror` is the reflection in the floor (y = 0). */
export const planeCorners = (cam: Cam, w: number, h: number, chain: Chain, mirror = false): Corners => {
  const at = (x: number, y: number): Pt => project(cam, toWorld(chain, [x, y, 0], mirror));
  return { topLeft: at(-w / 2, h / 2), topRight: at(w / 2, h / 2), bottomRight: at(w / 2, -h / 2), bottomLeft: at(-w / 2, -h / 2) };
};
export const bounds = (c: Corners): { x0: number; y0: number; x1: number; y1: number } => {
  const xs = [c.topLeft[0], c.topRight[0], c.bottomRight[0], c.bottomLeft[0]];
  const ys = [c.topLeft[1], c.topRight[1], c.bottomRight[1], c.bottomLeft[1]];
  return { x0: Math.min(...xs), x1: Math.max(...xs), y0: Math.min(...ys), y1: Math.max(...ys) };
};

// --- the two devices (scene units; the laptop screen is 3.04 by 1.9, the phone body 0.74 by 1.58) ---
export const MAC_POS: V3 = [-1.05, 0, -0.2];
export const MAC_ROT: V3 = [0, 7, 0];
export const LID_POS: V3 = [0, 0.08, -1.1];
export const LID_ROT: V3 = [-9, 0, 0];
export const MAC_SCREEN_POS: V3 = [0, 1.07, 0.034];
export const MAC_PLANE = { w: 3.04, h: 1.9 } as const;
export const PHONE_BODY = { w: 0.74, h: 1.58 } as const;
export const PHONE_PLANE = { w: 0.725, h: 0.725 * (1076 / 498) } as const;
export const PHONE_SCREEN_POS: V3 = [0, 0.79, 0.042];

export type Stage = { macPos: V3; macRot: V3; phonePos: V3; phoneRot: V3 };
export const STAGE: Stage = { macPos: MAC_POS, macRot: MAC_ROT, phonePos: [0.19, 0.02, 2.06], phoneRot: [1, -10, 0] };

export const macChain = (s: Stage): Chain => [[s.macPos, s.macRot], [LID_POS, LID_ROT], [MAC_SCREEN_POS, [0, 0, 0]]];
export const phoneChain = (s: Stage): Chain => [[s.phonePos, s.phoneRot], [PHONE_SCREEN_POS, [0, 0, 0]]];
export const macPin = (cam: Cam, s: Stage, mirror = false): Corners => planeCorners(cam, MAC_PLANE.w, MAC_PLANE.h, macChain(s), mirror);
export const phonePin = (cam: Cam, s: Stage, mirror = false): Corners => planeCorners(cam, PHONE_PLANE.w, PHONE_PLANE.h, phoneChain(s), mirror);
/** The front face of the phone's body, for the framing of shot 21. */
export const phoneBody = (cam: Cam, s: Stage): Corners => planeCorners(cam, PHONE_BODY.w, PHONE_BODY.h, [[s.phonePos, s.phoneRot], [[0, PHONE_BODY.h / 2, 0.05], [0, 0, 0]]]);

/** Box the phone screen is drawn in before it is pinned: 498 by 1076, the 720 wide phone scaled by PIN_K, the keyboard at the bottom. */
export const PIN_BOX = { w: 498, h: 1076, k: 498 / 720 } as const;
/** A point of the phone (local coordinates: 720 wide, bottom edge at y 864) on the frame. */
export const phonePoint = (cam: Cam, s: Stage, x: number, y: number): Pt => {
  const bx = x * PIN_BOX.k;
  const by = (y - 864) * PIN_BOX.k + PIN_BOX.h;
  return project(cam, toWorld(phoneChain(s), [(bx / PIN_BOX.w - 0.5) * PHONE_PLANE.w, (0.5 - by / PIN_BOX.h) * PHONE_PLANE.h, 0]));
};
/** A point of the Mac screen (1280 by 800) on the frame. */
export const macPoint = (cam: Cam, s: Stage, x: number, y: number): Pt =>
  project(cam, toWorld(macChain(s), [(x / 1280 - 0.5) * MAC_PLANE.w, (0.5 - y / 800) * MAC_PLANE.h, 0]));

// --- shot 21: the same frame as the storyboard, the camera drifting at one speed (a push of 2 %, 0.6 deg of yaw, 13 px of pan) ---
export const CAM21 = {
  from: { fov: 23, position: [-1.6258, 0.306, 6.2878], target: [-0.703, 1.014, 0.453] } as Cam,
  to: { fov: 23, position: [-1.5082, 0.32, 6.1722], target: [-0.663, 1.014, 0.453] } as Cam,
  at: [849, 1230] as const,
};
const between = (a: Cam, b: Cam, u: number): Cam => ({ fov: lerp(a.fov, b.fov, u), position: lerp3(a.position, b.position, u), target: lerp3(a.target, b.target, u) });
export const cam21 = (frame: number): Cam => between(CAM21.from, CAM21.to, (frame - CAM21.at[0]) / (CAM21.at[1] - 1 - CAM21.at[0]));

// --- shot 30: the only pull back of the film. The camera moves away along the shot 21 axis and rises, so the laptop deck is a surface with keys ---
export const CAM30 = { dolly: [1.1, 1.45] as const, height: [1.25, 1.75] as const, aimY: 0.9, at: [1230, 1335] as const };
export const cam30 = (frame: number): Cam => {
  const e = CAM21.to;
  const u = (frame - CAM30.at[0]) / (CAM30.at[1] - 1 - CAM30.at[0]);
  const k = lerp(CAM30.dolly[0], CAM30.dolly[1], u);
  return { fov: e.fov, target: [e.target[0], CAM30.aimY, e.target[2]], position: [e.target[0] + (e.position[0] - e.target[0]) * k, lerp(CAM30.height[0], CAM30.height[1], u), e.target[2] + (e.position[2] - e.target[2]) * k] };
};

// --- shot 1: the phone turns from the side to face the camera and the camera comes in; the Mac is a bright blur far behind ---
/** The yaw lands on exactly 0 at frame `settle` and stays there. The camera looks along -z at the height of the phone's middle. */
export const HERO = { frames: 90, settle: 70, yaw: [-68, 0] as const, phonePos: [-0.9, 0.02, 0] as V3, aim: [0.3, 0.02 + PHONE_SCREEN_POS[1]] as const, farMac: { pos: [4.0, 0.7, -10] as V3, rot: [0, -22, 0] as V3 } };
const SETTLE_K = 6;
/** The critically damped arrival of Headline.tsx, scaled so that it ends on exactly 1. */
const landing = (u: number): number => {
  const t = Math.min(1, Math.max(0, u));
  const at = (x: number): number => 1 - (1 + SETTLE_K * x) * Math.exp(-SETTLE_K * x);
  return t >= 1 ? 1 : at(t) / at(1);
};
export const heroStage = (frame: number): Stage => ({ ...STAGE, phonePos: HERO.phonePos, phoneRot: [0, lerp(HERO.yaw[0], HERO.yaw[1], landing(frame / HERO.settle)), 0] });
export const heroCam = (frame: number): Cam => ({ fov: 24, position: [HERO.aim[0], HERO.aim[1], 5.4 - frame * 0.011], target: [HERO.aim[0], HERO.aim[1], 0] });
