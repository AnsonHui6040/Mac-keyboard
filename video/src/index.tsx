import { AbsoluteFill, Composition, Layer, registerFont, registerRoot, staticFile, useCurrentFrame } from '@kinetographdev/core';
import { Callout } from './components/Callout.tsx';
import { DeviceTag } from './components/DeviceTag.tsx';
import { MacCursor } from './components/MacCursor.tsx';
import { Subtitle } from './components/Subtitle.tsx';
import script from './data/script.json';
import { splitBeats } from './lib/captions.ts';
import { DialogAuth } from './screens/DialogAuth.tsx';
import { DialogBlocked } from './screens/DialogBlocked.tsx';
import { DialogConfirm } from './screens/DialogConfirm.tsx';
import { SettingsSecurity } from './screens/SettingsSecurity.tsx';
import { SCREENS, center } from './screens/geometry.ts';
import { theme } from './theme.ts';

registerFont({ family: theme.font, weight: 400, path: staticFile('fonts/NotoSansTC-Regular.ttf') });
registerFont({ family: theme.font, weight: 500, path: staticFile('fonts/NotoSansTC-Medium.ttf') });
registerFont({ family: theme.font, weight: 700, path: staticFile('fonts/NotoSansTC-Bold.ttf') });

const scene16 = script.scenes.find((s) => s.n === 16);
if (!scene16) throw new Error('script.json has no scene 16');
const beats = splitBeats(scene16.caption);
const beat = (i: number): string => beats[Math.min(i, beats.length - 1)];

const Stage = ({ children, beatIndex }: { children: React.ReactNode; beatIndex: number }) => (
  <AbsoluteFill style={{ backgroundColor: theme.stage }}>
    <Layer id="stage">
      <DeviceTag label="在 Mac 上" />
      {children}
      <Subtitle beat={beat(beatIndex)} />
    </Layer>
  </AbsoluteFill>
);

/** One frame per screen, in script order, then the callouts and the pointer on dialogConfirm. */
const Stills16 = () => {
  const frame = useCurrentFrame();
  const open = SCREENS.dialogConfirm.open;
  const trash = SCREENS.dialogConfirm.trash;
  const body =
    frame === 0 ? <DialogBlocked /> :
    frame === 1 ? <SettingsSecurity /> :
    frame === 2 ? <DialogConfirm /> :
    frame === 3 ? <DialogAuth /> :
    (
      <Layer id="annotated">
        <DialogConfirm />
        <Callout id="callout-trash" targetRect={trash} color={theme.bad} head="不要按" />
        <Callout id="callout-open" targetRect={open} color={theme.good.ring} textColor={theme.good.ink} head="按這個" />
        <MacCursor state={{ ...center(open), visible: true, press: 0 }} />
      </Layer>
    );
  return <Stage beatIndex={frame}>{body}</Stage>;
};

registerRoot(() => (
  <Composition id="Stills16" component={Stills16} durationInFrames={5} fps={30} width={1920} height={1080} />
));
