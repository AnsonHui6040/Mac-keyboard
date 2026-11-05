/**
 * The 3D shots (1, 21, 30). The bodies are real 3D; the two screens are live 2D layers corner-pinned to the projected corners of
 * the screen planes, so cursor, rings and text stay exact while the camera moves. A dim blurred copy under the floor line is the reflection.
 */
import { AmbientLight, Camera3D, DirectionalLight, Extrude, Group3D, Layer, Mesh, PointLight, Rect, Scene3D, blur, cornerPin, linearGradient, staticFile } from '@kinetographdev/core';
import type { ReactNode } from 'react';
import { roundedRectPath } from '../intro/shapes.ts';
import { MacScreen } from './MacScreen.tsx';
import { PhoneScreen } from './PhoneScreen.tsx';
import { PhoneRings } from './Fingers.tsx';
import { phoneAt } from './state.ts';
import { HERO, LID_POS, LID_ROT, MAC_PLANE, PHONE_SCREEN_POS, PIN_BOX, heroCam, heroStage, macPin, phonePin, type Cam, type Corners, type Stage } from './project.ts';

/** The screen above the keyboard in shots 1 and 30: a very dark grey, so the phone does not look switched off. */
export const SCREEN_DARK = '#161618';
const abs = { position: 'absolute' as const };
const rr = (w: number, h: number, r: number): string => `M${r} 0 H${w - r} A${r} ${r} 0 0 1 ${w} ${r} V${h - r} A${r} ${r} 0 0 1 ${w - r} ${h} H${r} A${r} ${r} 0 0 1 0 ${h - r} V${r} A${r} ${r} 0 0 1 ${r} 0 Z`;
const GLASS = { color: '#08080a', metallic: 0.2, roughness: 0.2, doubleSided: true };
const RIM = { color: '#4d4f55', metallic: 1, roughness: 0.5, doubleSided: true };
const DECK = { color: '#6b6d73', metallic: 1, roughness: 0.5, doubleSided: true };
const KEY_GRID: [number, number][] = [0, 1, 2, 3, 4].flatMap((r) => Array.from({ length: 14 }, (_, c) => [r, c] as [number, number]));

const Pinned = ({ w, h, pin, round = 0, children }: { w: number; h: number; pin: Corners; round?: number; children: ReactNode }) => (
  <Layer layout={{ width: w, height: h }} effects={[cornerPin(pin)]}>
    <Layer layoutItem={abs} clip={round > 0 ? { kind: 'path', d: roundedRectPath(0, 0, w, h, round) } : undefined}>{children}</Layer>
  </Layer>
);

export const PhoneBody = () => (
  <>
    <Extrude path={rr(74, 158, 12)} size={1.58} depth={0.05} bevel={{ thickness: 0.01, size: 0.01, segments: 4 }} position={[0, PHONE_SCREEN_POS[1], -0.004]} material={RIM} />
    <Extrude path={rr(72, 156, 11)} size={1.56} depth={0.05} position={[0, PHONE_SCREEN_POS[1], 0.012]} material={GLASS} />
    <Mesh geometry={{ kind: 'box', width: 0.012, height: 0.22, depth: 0.03 }} position={[0.378, 1.1, 0]} material={RIM} />
  </>
);
export const LaptopBody = ({ screen }: { screen?: string }) => (
  <>
    <Extrude path={rr(320, 224, 12)} size={3.2} depth={0.07} bevel={{ thickness: 0.012, size: 0.012, segments: 3 }} rotation={[-90, 0, 0]} position={[0, 0.042, 0]} material={DECK} />
    {KEY_GRID.map(([r, c]) => <Mesh key={`${r}-${c}`} geometry={{ kind: 'box', width: 0.17, height: 0.008, depth: 0.17 }} position={[-1.235 + c * 0.19, 0.094, -0.74 + r * 0.19]} material={{ color: '#121214', roughness: 0.55, doubleSided: true }} />)}
    <Mesh geometry={{ kind: 'box', width: 1.15, height: 0.004, depth: 0.62 }} position={[0, 0.092, 0.66]} material={{ color: '#5d5f64', metallic: 1, roughness: 0.5, doubleSided: true }} />
    <Group3D position={LID_POS} rotation={LID_ROT}>
      <Extrude path={rr(320, 214, 12)} size={3.2} depth={0.035} bevel={{ thickness: 0.008, size: 0.01, segments: 3 }} position={[0, 1.07, 0]} material={RIM} />
      <Extrude path={rr(318, 212, 11)} size={3.17} depth={0.03} position={[0, 1.07, 0.012]} material={GLASS} />
      {screen && <Mesh geometry={{ kind: 'plane', width: MAC_PLANE.w, height: MAC_PLANE.h }} position={[0, 1.07, 0.034]} material={{ color: screen, unlit: true, doubleSided: true }} />}
    </Group3D>
  </>
);

const Lights = () => (
  <>
    <AmbientLight intensity={0.04} />
    <DirectionalLight direction={[0.9, -0.15, -0.5]} intensity={1.0} />
    <DirectionalLight direction={[-0.9, -0.2, -0.45]} intensity={0.8} />
    <PointLight position={[0, 2.8, 2.2]} intensity={1.1} range={7} />
  </>
);

const Bodies = ({ stage, mac = true, phone = true, macScreen }: { stage: Stage; mac?: boolean; phone?: boolean; macScreen?: string }) => (
  <>
    {mac && <Group3D position={stage.macPos} rotation={stage.macRot}><LaptopBody screen={macScreen} /></Group3D>}
    {phone && <Group3D position={stage.phonePos} rotation={stage.phoneRot}><PhoneBody /></Group3D>}
  </>
);

const Scene = ({ id, cam, children }: { id: string; cam: Cam; children: ReactNode }) => (
  <Scene3D id={id} width={1920} height={1080} msaa={4} environment={{ src: staticFile('film/env.png'), intensity: 0.45 }}>
    <Camera3D fov={cam.fov} position={cam.position} target={cam.target} far={80} />
    <Lights />
    {children}
  </Scene3D>
);

/** The phone's screen layer: black glass, the keyboard page at the bottom, the finger rings. Ring size is 106 for 64 px in shot 21. */
export const PinnedPhone = ({ f, pin, bg = '#000000' }: { f: number; pin: Corners; bg?: string }) => {
  const k = PIN_BOX.k;
  return (
    <Pinned w={PIN_BOX.w} h={PIN_BOX.h} pin={pin} round={58}>
      <Rect width={PIN_BOX.w} height={PIN_BOX.h} fill={bg} />
      <Layer y={PIN_BOX.h - 864 * k} scale={k}>
        <PhoneScreen state={phoneAt(f)} f={f} />
        <PhoneRings f={f} size={106} line={8} />
      </Layer>
    </Pinned>
  );
};
const PinnedMac = ({ f, pin }: { f: number; pin: Corners }) => (
  <Pinned w={1280} h={800} pin={pin}>
    <MacScreen f={f} stage />
  </Pinned>
);

/** Mac and phone side by side (shots 21 and 30). */
/** `sink` fades the top of the phone into black (shot 21); `phoneBg` is the colour of the screen above the keyboard. */
export const StageShot = ({ f, cam, stage, sink = true, phoneBg }: { f: number; cam: Cam; stage: Stage; sink?: boolean; phoneBg?: string }) => (
  <Layer id="stage">
    <Layer id="reflection" opacity={0.12} effects={[blur(6)]}>
      <Scene id="reflection-bodies" cam={cam}><Group3D scale={[1, -1, 1]}><Bodies stage={stage} /></Group3D></Scene>
      <PinnedMac f={f} pin={macPin(cam, stage, true)} />
      <PinnedPhone f={f} pin={phonePin(cam, stage, true)} bg={phoneBg} />
    </Layer>
    <Scene id="bodies" cam={cam}><Bodies stage={stage} /></Scene>
    <PinnedMac f={f} pin={macPin(cam, stage)} />
    <PinnedPhone f={f} pin={phonePin(cam, stage)} bg={phoneBg} />
    {sink && <Rect x={1280} y={0} width={640} height={720} fill={linearGradient(['#000000ff', '#00000000'], { angle: 180 })} />}
  </Layer>
);

/** Shot 1: the phone alone, turning, with the Mac a bright out-of-focus block far behind it. */
export const Hero = ({ f }: { f: number }) => {
  const cam = heroCam(f);
  const stage = heroStage(f);
  return (
    <Layer id="hero">
      <Layer id="far-mac" opacity={0.7} effects={[blur(34)]}>
        <Scene id="far-mac-body" cam={cam}>
          <Group3D position={HERO.farMac.pos} rotation={HERO.farMac.rot}><LaptopBody screen="#e4e8f2" /></Group3D>
        </Scene>
      </Layer>
      <Layer id="hero-reflection" opacity={0.12} effects={[blur(6)]}>
        <Scene id="hero-reflect" cam={cam}><Group3D scale={[1, -1, 1]}><Bodies stage={stage} mac={false} /></Group3D></Scene>
        <PinnedPhone f={f} pin={phonePin(cam, stage, true)} bg={SCREEN_DARK} />
      </Layer>
      <Scene id="hero-body" cam={cam}><Bodies stage={stage} mac={false} /></Scene>
      <PinnedPhone f={f} pin={phonePin(cam, stage)} bg={SCREEN_DARK} />
    </Layer>
  );
};
