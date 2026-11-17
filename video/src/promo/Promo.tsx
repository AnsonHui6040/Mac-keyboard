/** PromoFilm: hard cuts, the close-ups, the 3D cuts and the end card, the titles over them with a scrim, the narration and the music underneath. */
import { AbsoluteFill, Audio, Layer, Rect, Sequence, Text, grain, linearGradient, registerFont, staticFile, useCurrentFrame } from '@kinetographdev/core';
import { theme } from '../theme.ts';
import { Headline, arrival } from '../film/Headline.tsx';
import { CloseShot } from './CloseShot.tsx';
import { Hero3, StageShot8, Wide } from './Wide.tsx';
import { cutAt } from './cuts.ts';
import { dbToGain, musicGainDb } from './mix.ts';
import { PROMO_MUSIC } from './music.ts';
import { CARD_X } from '../film/timeline.ts';
import { END_CARD, TITLES, VOICE } from './timeline.ts';

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

export const Promo = () => {
  const f = useCurrentFrame();
  const cut = cutAt(f);
  const close = cut.dev === 'phone' || cut.dev === 'mac' || cut.dev === 'win' || cut.dev === 'linux';
  const title = TITLES.find((t) => f >= t.from && f < t.to);
  const scrim = title && close ? arrival(title, f) : 0;
  return (
    <AbsoluteFill style={{ backgroundColor: '#000000' }}>
      <Layer id="grade" effects={[grain(0.022, { seed: f, size: 1.2 })]}>
        <Rect width={1920} height={1080} fill="#000000" />
        {close ? <CloseShot id={cut.id} f={f} /> : null}
        {cut.dev === 'hero' && <Hero3 f={f} />}
        {cut.dev === 'stage' && <StageShot8 f={f} />}
        {cut.dev === 'wide' && <Wide f={f} />}
        {cut.dev === 'card' && <EndCard f={f} />}
        {scrim > 0 && <Rect id="scrim" width={1920} height={SCRIM_H} opacity={0.85 * scrim} fill={linearGradient(['#000000ff', '#000000b8', '#00000050', '#00000000'], { angle: 180 })} />}
        {TITLES.map((t) => <Headline key={t.id} t={t} f={f} />)}
      </Layer>
      {VOICE.map((v) => (
        <Sequence key={v.id} from={v.from} durationInFrames={v.to - v.from}>
          <Audio src={staticFile(`voice/promo/${v.id}.mp3`)} />
        </Sequence>
      ))}
      {PROMO_MUSIC.map((m) => (
        <Sequence key={m.id} from={m.from} durationInFrames={m.to - m.from}>
          <Audio src={staticFile(m.file)} trimBefore={m.trimBefore} volume={(lf: number) => m.base * dbToGain(musicGainDb(m.from + lf))} />
        </Sequence>
      ))}
    </AbsoluteFill>
  );
};
