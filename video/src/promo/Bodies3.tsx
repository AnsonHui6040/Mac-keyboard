/** The bodies and corner-pinned screens of the promo's 3D cuts: the desk monitor, the dark Linux laptop, and the promo's own Mac and phone screens. */
import { Extrude, Group3D, Layer, Mesh, Rect, blur } from '@kinetographdev/core';
import { MacScreen } from '../film/MacScreen.tsx';
import { PhoneScreen } from '../film/PhoneScreen.tsx';
import { PhoneRings } from '../film/Fingers.tsx';
import type { ReactNode } from 'react';
import { Bodies, Pinned, Scene } from '../film/Stage.tsx';
import { LID_POS, LID_ROT, MAC_PLANE, PIN_BOX, macPin, phonePin, type Cam, type Stage } from '../film/project.ts';
import { LinuxScreen } from './LinuxScreen.tsx';
import { WinScreen } from './WinScreen.tsx';
import { LIN_SCALE, WIN_PLANE, WIN_SCREEN_POS, linuxPin, winPin, type Placement } from './project3.ts';
import { docAt, promoFingerAt, promoMacAt, promoPhoneAt, promoTrackAt } from './state.ts';

const rr = (w: number, h: number, r: number): string => `M${r} 0 H${w - r} A${r} ${r} 0 0 1 ${w} ${r} V${h - r} A${r} ${r} 0 0 1 ${w - r} ${h} H${r} A${r} ${r} 0 0 1 0 ${h - r} V${r} A${r} ${r} 0 0 1 ${r} 0 Z`;
const GLASS = { color: '#08080a', metallic: 0.2, roughness: 0.2, doubleSided: true };
const KEYS = { color: '#0e0e10', roughness: 0.55, doubleSided: true };
const KEY_GRID: [number, number][] = [0, 1, 2, 3, 4].flatMap((r) => Array.from({ length: 14 }, (_, c) => [r, c] as [number, number]));

/** The Windows desk monitor: a plain dark bezel, a neck and a flat base. The screen plane sits at WIN_SCREEN_POS. */
export const WinBody = ({ screen }: { screen?: string }) => (
  <>
    <Extrude path={rr(440, 258, 10)} size={4.4} depth={0.1} bevel={{ thickness: 0.01, size: 0.01, segments: 3 }} position={[0, WIN_SCREEN_POS[1], -0.06]} material={{ color: '#2b2c30', metallic: 0.8, roughness: 0.45, doubleSided: true }} />
    <Extrude path={rr(432, 250, 8)} size={4.32} depth={0.03} position={[0, WIN_SCREEN_POS[1], 0.045]} material={GLASS} />
    {screen && <Mesh geometry={{ kind: 'plane', width: WIN_PLANE.w, height: WIN_PLANE.h }} position={WIN_SCREEN_POS} material={{ color: screen, unlit: true, doubleSided: true }} />}
    <Mesh geometry={{ kind: 'box', width: 0.34, height: 0.95, depth: 0.14 }} position={[0, 0.52, -0.12]} material={{ color: '#6b6d73', metallic: 1, roughness: 0.5, doubleSided: true }} />
    <Mesh geometry={{ kind: 'box', width: 1.7, height: 0.05, depth: 0.95 }} position={[0, 0.025, -0.05]} material={{ color: '#6b6d73', metallic: 1, roughness: 0.5, doubleSided: true }} />
  </>
);

/** The Linux laptop: the Mac's proportions at LIN_SCALE, a darker shell (#3a3b40). */
export const LinuxBody = ({ screen }: { screen?: string }) => (
  <Group3D scale={[LIN_SCALE, LIN_SCALE, LIN_SCALE]}>
    <Extrude path={rr(320, 224, 12)} size={3.2} depth={0.07} bevel={{ thickness: 0.012, size: 0.012, segments: 3 }} rotation={[-90, 0, 0]} position={[0, 0.042, 0]} material={{ color: '#3a3b40', metallic: 1, roughness: 0.5, doubleSided: true }} />
    {KEY_GRID.map(([r, c]) => <Mesh key={`${r}-${c}`} geometry={{ kind: 'box', width: 0.17, height: 0.008, depth: 0.17 }} position={[-1.235 + c * 0.19, 0.094, -0.74 + r * 0.19]} material={KEYS} />)}
    <Mesh geometry={{ kind: 'box', width: 1.15, height: 0.004, depth: 0.62 }} position={[0, 0.092, 0.66]} material={{ color: '#2e2f33', metallic: 1, roughness: 0.5, doubleSided: true }} />
    <Group3D position={LID_POS} rotation={LID_ROT}>
      <Extrude path={rr(320, 214, 12)} size={3.2} depth={0.035} bevel={{ thickness: 0.008, size: 0.01, segments: 3 }} position={[0, 1.07, 0]} material={{ color: '#34353a', metallic: 1, roughness: 0.5, doubleSided: true }} />
      <Extrude path={rr(318, 212, 11)} size={3.17} depth={0.03} position={[0, 1.07, 0.012]} material={GLASS} />
      {screen && <Mesh geometry={{ kind: 'plane', width: MAC_PLANE.w, height: MAC_PLANE.h }} position={[0, 1.07, 0.034]} material={{ color: screen, unlit: true, doubleSided: true }} />}
    </Group3D>
  </Group3D>
);

/** The Windows desk monitor at a placement, with its live screen pinned to it. The 1280 by 800 screen is stretched to the 16:9 plane. */
export const WinUnit = ({ f, cam, at, mirror = false }: { f: number; cam: Cam; at: Placement; mirror?: boolean }) => (
  <>
    <Scene3DSlot cam={cam} id={mirror ? 'win-mirror' : 'win-body'} mirror={mirror}><Group3D position={at.pos} rotation={at.rot}><WinBody /></Group3D></Scene3DSlot>
    <Pinned w={1280} h={800} pin={winPin(cam, at, mirror)}><WinScreen f={f} {...docAt('Windows', f)} /></Pinned>
  </>
);
export const LinuxUnit = ({ f, cam, at, mirror = false }: { f: number; cam: Cam; at: Placement; mirror?: boolean }) => (
  <>
    <Scene3DSlot cam={cam} id={mirror ? 'lin-mirror' : 'lin-body'} mirror={mirror}><Group3D position={at.pos} rotation={at.rot}><LinuxBody /></Group3D></Scene3DSlot>
    <Pinned w={1280} h={800} pin={linuxPin(cam, at, mirror)}><LinuxScreen f={f} {...docAt('Linux', f)} /></Pinned>
  </>
);

const Scene3DSlot = ({ cam, id, mirror, children }: { cam: Cam; id: string; mirror: boolean; children: ReactNode }) => (
  <Scene id={id} cam={cam}>{mirror ? <Group3D scale={[1, -1, 1]}>{children}</Group3D> : children}</Scene>
);

/** The phone's screen for the promo: the promo's phone state, finger and pad fingers. */
export const PromoPhone = ({ f, pin, bg = '#000000' }: { f: number; pin: Parameters<typeof Pinned>[0]['pin']; bg?: string }) => {
  const k = PIN_BOX.k;
  return (
    <Pinned w={PIN_BOX.w} h={PIN_BOX.h} pin={pin} round={58}>
      <Rect width={PIN_BOX.w} height={PIN_BOX.h} fill={bg} />
      <Layer y={PIN_BOX.h - 864 * k} scale={k}>
        <PhoneScreen state={promoPhoneAt(f)} f={f} />
        <PhoneRings f={f} size={106} line={8} finger={promoFingerAt} pad={promoTrackAt} />
      </Layer>
    </Pinned>
  );
};
export const PromoMac = ({ f, pin }: { f: number; pin: Parameters<typeof Pinned>[0]['pin'] }) => (
  <Pinned w={1280} h={800} pin={pin}><MacScreen f={f} stage state={promoMacAt(f)} /></Pinned>
);

/** The Mac and the phone of the stage, reflection included. */
export const MacPhone = ({ f, cam, stage, phoneBg }: { f: number; cam: Cam; stage: Stage; phoneBg?: string }) => (
  <Layer>
    <Layer id="reflection" opacity={0.12} effects={[blur(6)]}>
      <Scene id="reflection-bodies" cam={cam}><Group3D scale={[1, -1, 1]}><Bodies stage={stage} /></Group3D></Scene>
      <PromoMac f={f} pin={macPin(cam, stage, true)} />
      <PromoPhone f={f} pin={phonePin(cam, stage, true)} bg={phoneBg} />
    </Layer>
    <Scene id="bodies" cam={cam}><Bodies stage={stage} /></Scene>
    <PromoMac f={f} pin={macPin(cam, stage)} />
    <PromoPhone f={f} pin={phonePin(cam, stage)} bg={phoneBg} />
  </Layer>
);
