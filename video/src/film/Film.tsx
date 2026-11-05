/** ProductFilm: the shot of a frame, hard cuts only, the titles over it, a little grain on all of it. */
import { AbsoluteFill, Audio, Layer, Rect, Sequence, Text, grain, linearGradient, radialGradient, registerFont, staticFile, useCurrentFrame } from '@kinetographdev/core';
import { MUSIC, musicGain } from './music.ts';
import { theme } from '../theme.ts';
import { Headline, arrival } from './Headline.tsx';
import { CloseShot } from './shots.tsx';
import { Hero, SCREEN_DARK, StageShot } from './Stage.tsx';
import { STAGE, cam21, cam30 } from './project.ts';
import { END_CARD, CARD_X, TITLES, shotAt } from './timeline.ts';

registerFont({ family: theme.font, weight: 400, path: staticFile('fonts/NotoSansTC-Regular.ttf') });
registerFont({ family: theme.font, weight: 500, path: staticFile('fonts/NotoSansTC-Medium.ttf') });
registerFont({ family: theme.font, weight: 700, path: staticFile('fonts/NotoSansTC-Bold.ttf') });

/** A black to clear fade under a title over a close-up, so the title does not sit on blurred UI. It follows the title's own arrival. */
const SCRIM_H = 280;

const EndCard = ({ f }: { f: number }) => (
  <Layer id="end-card">
    {END_CARD.filter((c) => f >= c.at).map((c) => (
      <Text key={c.text} font={theme.font} weight={c.weight} size={c.size} color={c.color} x={CARD_X} y={c.y} maxWidth={1600}>{c.text}</Text>
    ))}
  </Layer>
);

export const Film = () => {
  const f = useCurrentFrame();
  const shot = shotAt(f);
  const title = TITLES.find((t) => f >= t.from && f < t.to);
  const scrim = title && (shot.kind === 'phone' || shot.kind === 'mac') ? arrival(title, f) : 0;
  return (
    <AbsoluteFill style={{ backgroundColor: '#000000' }}>
      <Layer id="grade" effects={[grain(0.022, { seed: f, size: 1.2 })]}>
        <Rect width={1920} height={1080} fill="#000000" />
        {shot.kind === 'phone' || (shot.kind === 'mac') ? <CloseShot id={shot.id} f={f} /> : null}
        {shot.kind === 'hero' && <Hero f={f} />}
        {shot.kind === 'stage' && shot.id !== '30' && <StageShot f={f} cam={cam21(f)} stage={STAGE} />}
        {shot.kind === 'stage' && shot.id !== '30' && <Rect id="vignette" width={1920} height={1080} opacity={0.6 * Math.min(1, (f - 849) / 381)} fill={radialGradient([[0, '#00000000'], [0.5, '#00000000'], [1, '#000000e0']], { cx: 0.5, cy: 0.5, r: 0.8 })} />}
        {shot.id === '30' && <StageShot f={f} cam={cam30(f)} stage={STAGE} sink={false} phoneBg={SCREEN_DARK} />}
        {shot.kind === 'card' && <EndCard f={f} />}
        {scrim > 0 && <Rect id="scrim" width={1920} height={SCRIM_H} opacity={0.85 * scrim} fill={linearGradient(['#000000ff', '#000000b8', '#00000050', '#00000000'], { angle: 180 })} />}
        {TITLES.map((t) => <Headline key={t.id} t={t} f={f} />)}
      </Layer>
      {MUSIC.map((m) => (
        <Sequence key={m.id} from={m.from} durationInFrames={m.to - m.from}>
          <Audio src={staticFile(m.file)} trimBefore={m.trimBefore} volume={(lf: number) => musicGain(m.from + lf)} />
        </Sequence>
      ))}
    </AbsoluteFill>
  );
};
