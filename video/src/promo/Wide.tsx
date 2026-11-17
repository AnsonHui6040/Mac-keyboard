/** The three 3D cuts of the v0.2 promo: 1 (the phone in front, three computers out of focus behind), 8 (the stage) and 9 (the wide frame). */
import type { ReactNode } from 'react';
import { Group3D, Layer, Rect, blur, linearGradient, radialGradient } from '@kinetographdev/core';
import { Bodies, LaptopBody, SCREEN_DARK, Scene } from '../film/Stage.tsx';
import { CAM21, heroStage, phonePin } from '../film/project.ts';
import { LinuxBody, LinuxUnit, MacPhone, PromoPhone, WinBody, WinUnit } from './Bodies3.tsx';
import { FAR, WIDE, brightness, heroCam3, stageCam, wideCam, wideStage } from './project3.ts';
import { padFrame } from './timeline.ts';

/** Shot 1: the phone turns front-on in the foreground; the Mac (brightest), the Windows monitor and the Linux laptop are blurred far behind. */
export const Hero3 = ({ f }: { f: number }) => {
  const cam = heroCam3(f);
  const stage = heroStage(f);
  const far = (id: string, host: 'Mac' | 'Windows' | 'Linux', at: { pos: [number, number, number]; rot: [number, number, number] }, body: ReactNode) => (
    <Layer id={id} opacity={brightness(host, '1') * (host === 'Mac' ? 0.9 : 1)} effects={[blur(34)]}>
      <Scene id={`${id}-body`} cam={cam}><Group3D position={at.pos} rotation={at.rot}>{body}</Group3D></Scene>
    </Layer>
  );
  return (
    <Layer id="hero">
      {far('far-win', 'Windows', FAR.win, <WinBody screen="#a4a7b0" />)}
      {far('far-linux', 'Linux', FAR.linux, <LinuxBody screen="#9a9da6" />)}
      {far('far-mac', 'Mac', FAR.mac, <LaptopBody screen="#e4e8f2" />)}
      <Layer id="hero-reflection" opacity={0.12} effects={[blur(6)]}>
        <Scene id="hero-reflect" cam={cam}><Group3D scale={[1, -1, 1]}><Bodies stage={stage} mac={false} /></Group3D></Scene>
        <PromoPhone f={f} pin={phonePin(cam, stage, true)} bg={SCREEN_DARK} />
      </Layer>
      <Scene id="hero-body" cam={cam}><Bodies stage={stage} mac={false} /></Scene>
      <PromoPhone f={f} pin={phonePin(cam, stage)} bg={SCREEN_DARK} />
    </Layer>
  );
};

/** Shot 8: the old shot 21 stage with the promo's trackpad, Mac and phone. */
export const StageShot8 = ({ f }: { f: number }) => {
  const cam = stageCam(f);
  const stage = wideStage();
  const u = Math.min(1, (padFrame(f) - CAM21.at[0]) / (CAM21.at[1] - CAM21.at[0]));
  return (
    <Layer id="stage">
      <MacPhone f={f} cam={cam} stage={stage} />
      <Rect id="sink" x={1280} y={0} width={640} height={720} fill={linearGradient(['#000000ff', '#00000000'], { angle: 180 })} />
      <Rect id="vignette" width={1920} height={1080} opacity={0.6 * u} fill={radialGradient([[0, '#00000000'], [0.5, '#00000000'], [1, '#000000e0']], { cx: 0.5, cy: 0.5, r: 0.8 })} />
    </Layer>
  );
};

/** Shot 9: all three computers and the phone; the Mac at full brightness and typing, the other two dimmed. */
export const Wide = ({ f }: { f: number }) => {
  const cam = wideCam(f);
  return (
    <Layer id="wide">
      <Layer id="wide-win" opacity={brightness('Windows', '9')}><WinUnit f={f} cam={cam} at={WIDE.win} /></Layer>
      <Layer id="wide-linux" opacity={brightness('Linux', '9')}><LinuxUnit f={f} cam={cam} at={WIDE.linux} /></Layer>
      <MacPhone f={f} cam={cam} stage={wideStage()} />
    </Layer>
  );
};
