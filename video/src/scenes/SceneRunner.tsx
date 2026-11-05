import { AbsoluteFill, Layer, interpolate, spring, useCurrentFrame, useVideoConfig } from '@kinetographdev/core';
import { Callout } from '../components/Callout.tsx';
import { DeviceTag } from '../components/DeviceTag.tsx';
import { MacCursor } from '../components/MacCursor.tsx';
import { Subtitle } from '../components/Subtitle.tsx';
import { TapDot } from '../components/TapDot.tsx';
import { compileRegistered } from '../data/scenes/index.ts';
import { pointerAt, type PointerState } from '../lib/pointer.ts';
import { DEFAULT_HEAD, FADE_FRAMES, labelRunStart, type CompiledScene, type Device, type Label, type SceneSpec, type StepTime } from '../lib/sceneSpec.ts';
import { SCREEN_VIEWS } from '../screens/registry.tsx';
import { SCREENS } from '../screens/geometry.ts';
import { theme } from '../theme.ts';

const DEVICE_LABEL: Record<Device, string> = { mac: '在 Mac 上', iphone: '在 iPhone 上' };

const compiled = new Map<number, CompiledScene>();
const compile = (spec: SceneSpec): CompiledScene => {
  let c = compiled.get(spec.n);
  if (!c) {
    c = compileRegistered(spec);
    compiled.set(spec.n, c);
  }
  return c;
};

const HIDDEN: PointerState = { x: 0, y: 0, visible: false, press: 0 };

/** A beat's screen with the callouts it carries. `opacity` is the cross fade factor. */
const BeatContent = ({ spec, index, frame, localFrame, fps, from, opacity, pointer, stepTimes }: { spec: SceneSpec; index: number; frame: number; localFrame: number; fps: number; from: (i: number) => number; opacity: number; pointer: PointerState; stepTimes: StepTime[] }) => {
  const b = spec.beats[index];
  const prev = index > 0 && spec.beats[index - 1].screen === b.screen ? spec.beats[index - 1].device : undefined;
  const rise = (label: Label): number => {
    const start = from(labelRunStart(spec, index, label));
    const s = spring({ frame: frame - start, fps, config: { damping: 30, stiffness: 140 } });
    return Math.min(1, Math.max(0, s));
  };
  return (
    <Layer id={`beat-${index}`} opacity={opacity}>
      {SCREEN_VIEWS[b.screen]({ active: b.device, prevActive: prev, frame, localFrame, beatIndex: index, beatFrame: frame - from(index), pointer, stepTimes })}
      {b.labels?.map((l) => (
        <Layer key={`${l.kind}-${l.target}`} opacity={rise(l)}>
          <Callout id={`callout-${l.target}`} targetRect={SCREENS[b.screen][l.target]}
            color={l.kind === 'bad' ? theme.bad : theme.good.ring} textColor={l.kind === 'bad' ? undefined : theme.good.ink} head={l.head ?? DEFAULT_HEAD[l.kind]} />
        </Layer>
      ))}
    </Layer>
  );
};

/** Draws one registered scene from its data: device tag, screen, callouts, pointer and subtitle for the current frame. */
export const SceneRunner = ({ spec }: { spec: SceneSpec }) => {
  const localFrame = useCurrentFrame();
  const frame = localFrame;
  const { fps } = useVideoConfig();
  const c = compile(spec);
  const i = c.beatAt(frame);
  const from = (k: number): number => c.timeline[k].from;
  const device = c.deviceAt(frame);

  // A screen change takes FADE_FRAMES: the old screen fades out over the first half, the new one in over the second.
  // They never overlap, because the screens share layer ids (btn-open, dialog, icon) and ids must be unique.
  const half = FADE_FRAMES / 2;
  const changing = i > 0 && spec.beats[i - 1].screen !== spec.beats[i].screen;
  const k = frame - c.timeline[i].from;
  const outgoing = changing && k < half ? 1 - (k + 1) / half : 0;
  const incoming = !changing || k >= half ? (changing ? Math.min(1, (k - half + 1) / half) : 1) : 0;

  // The pointer belongs to the run of same-device beats that is on screen; it fades in on the run's first appearance,
  // and fades out when the run ends before the scene does (a device change).
  const run = c.runs.find((r) => frame >= r.cues[0].from && frame < r.to);
  const state = run ? pointerAt(frame, run.cues, fps) : HIDDEN;
  const sceneEnd = c.timeline[c.timeline.length - 1].to;
  const fadeIn = run ? interpolate(frame, [run.cues[0].from, run.cues[0].from + FADE_FRAMES], [0, 1], { extrapolateLeft: 'clamp', extrapolateRight: 'clamp' }) : 0;
  const fadeOut = run && run.to < sceneEnd ? interpolate(frame, [run.to - FADE_FRAMES, run.to], [1, 0], { extrapolateLeft: 'clamp', extrapolateRight: 'clamp' }) : 1;
  const pointerDevice = run?.device ?? device ?? 'mac';

  return (
    <AbsoluteFill style={{ backgroundColor: theme.stage }}>
      <Layer id="stage">
        {device && <DeviceTag label={DEVICE_LABEL[device]} />}
        {outgoing > 0 && <BeatContent spec={spec} index={i - 1} frame={frame} localFrame={localFrame} fps={fps} from={from} opacity={outgoing} pointer={state} stepTimes={c.stepTimes[i - 1]} />}
        {incoming > 0 && <BeatContent spec={spec} index={i} frame={frame} localFrame={localFrame} fps={fps} from={from} opacity={incoming} pointer={state} stepTimes={c.stepTimes[i]} />}
        <Layer id="pointer-fade" opacity={fadeIn * fadeOut * c.pointerHide(frame)}>
          {pointerDevice === 'iphone' ? <TapDot state={state} /> : <MacCursor state={state} />}
        </Layer>
        <Subtitle beat={c.beats[i]} />
      </Layer>
    </AbsoluteFill>
  );
};
