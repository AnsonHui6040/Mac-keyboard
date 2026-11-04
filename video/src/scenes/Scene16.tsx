import { AbsoluteFill, Layer, interpolate, spring, useCurrentFrame, useVideoConfig } from '@kinetographdev/core';
import { Callout } from '../components/Callout.tsx';
import { DeviceTag } from '../components/DeviceTag.tsx';
import { MacCursor } from '../components/MacCursor.tsx';
import { Subtitle } from '../components/Subtitle.tsx';
import script from '../data/script.json';
import { FADE_FRAMES, SCENE16_BEATS, labelRunStart, scene16Cues, scene16Timeline } from '../data/scene16.ts';
import { splitBeats } from '../lib/captions.ts';
import { pointerAt } from '../lib/pointer.ts';
import { DialogAuth } from '../screens/DialogAuth.tsx';
import { DialogBlocked } from '../screens/DialogBlocked.tsx';
import { DialogConfirm } from '../screens/DialogConfirm.tsx';
import { SettingsSecurity } from '../screens/SettingsSecurity.tsx';
import { SCREENS, type ScreenId } from '../screens/geometry.ts';
import { theme } from '../theme.ts';

const entry = script.scenes.find((s) => s.n === 16);
if (!entry) throw new Error('script.json has no scene 16');
const beats = splitBeats(entry.caption);
if (beats.length !== SCENE16_BEATS.length) throw new Error(`scene 16: ${beats.length} subtitle beats but ${SCENE16_BEATS.length} planned`);
const timeline = scene16Timeline(beats);
const cues = scene16Cues(timeline);

const SCREEN_VIEW: Record<ScreenId, () => React.ReactNode> = {
  dialogBlocked: () => <DialogBlocked />,
  settingsSecurity: () => <SettingsSecurity />,
  dialogConfirm: () => <DialogConfirm />,
  auth: () => <DialogAuth />,
};

const beatAt = (frame: number): number => {
  const i = timeline.findIndex((t) => frame >= t.from && frame < t.to);
  return i === -1 ? timeline.length - 1 : i;
};

/** A beat's screen with the callouts it carries. `opacity` is the cross fade factor. */
const BeatContent = ({ index, frame, fps, opacity }: { index: number; frame: number; fps: number; opacity: number }) => {
  const b = SCENE16_BEATS[index];
  const rise = (label: 'good' | 'bad'): number => {
    const start = timeline[labelRunStart(index, label)].from;
    const s = spring({ frame: frame - start, fps, config: { damping: 30, stiffness: 140 } });
    return Math.min(1, Math.max(0, s));
  };
  return (
    <Layer id={`beat-${index}`} opacity={opacity}>
      {SCREEN_VIEW[b.screen]()}
      {b.labels?.includes('bad') && (
        <Layer opacity={rise('bad')}>
          <Callout id="callout-trash" targetRect={SCREENS.dialogConfirm.trash} color={theme.bad} head="不要按" />
        </Layer>
      )}
      {b.labels?.includes('good') && (
        <Layer opacity={rise('good')}>
          <Callout id="callout-open" targetRect={SCREENS.dialogConfirm.open} color={theme.good.ring} textColor={theme.good.ink} head="按這個" />
        </Layer>
      )}
    </Layer>
  );
};

export const Scene16 = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const i = beatAt(frame);
  // A screen change takes FADE_FRAMES: the old screen fades out over the first half, the new one in over the second.
  // They never overlap, because the screens share layer ids (btn-open, dialog, icon) and ids must be unique.
  const half = FADE_FRAMES / 2;
  const changing = i > 0 && SCENE16_BEATS[i - 1].screen !== SCENE16_BEATS[i].screen;
  const k = frame - timeline[i].from;
  const outgoing = changing && k < half ? 1 - (k + 1) / half : 0;
  const incoming = !changing || k >= half ? (changing ? Math.min(1, (k - half + 1) / half) : 1) : 0;
  const pointer = pointerAt(frame, cues, fps);
  const pointerFade = interpolate(frame, [cues[0].from, cues[0].from + FADE_FRAMES], [0, 1], { extrapolateLeft: 'clamp', extrapolateRight: 'clamp' });

  return (
    <AbsoluteFill style={{ backgroundColor: theme.stage }}>
      <Layer id="stage">
        <DeviceTag label="在 Mac 上" />
        {outgoing > 0 && <BeatContent index={i - 1} frame={frame} fps={fps} opacity={outgoing} />}
        {incoming > 0 && <BeatContent index={i} frame={frame} fps={fps} opacity={incoming} />}
        <Layer id="pointer-fade" opacity={pointerFade}>
          <MacCursor state={pointer} />
        </Layer>
        <Subtitle beat={beats[i]} />
      </Layer>
    </AbsoluteFill>
  );
};
