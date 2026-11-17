/** PromoFilm (first cut): hard cuts, the close-ups drawn, the titles over them with a scrim, black for the cuts that come later. */
import { AbsoluteFill, Layer, Rect, grain, linearGradient, registerFont, staticFile, useCurrentFrame } from '@kinetographdev/core';
import { theme } from '../theme.ts';
import { Headline, arrival } from '../film/Headline.tsx';
import { CloseShot } from './CloseShot.tsx';
import { cutAt } from './cuts.ts';
import { TITLES } from './timeline.ts';

registerFont({ family: theme.font, weight: 400, path: staticFile('fonts/NotoSansTC-Regular.ttf') });
registerFont({ family: theme.font, weight: 500, path: staticFile('fonts/NotoSansTC-Medium.ttf') });
registerFont({ family: theme.font, weight: 700, path: staticFile('fonts/NotoSansTC-Bold.ttf') });

/** A black to clear fade under a title over a close-up, so the title does not sit on blurred UI. It follows the title's own arrival. */
const SCRIM_H = 280;

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
        {scrim > 0 && <Rect id="scrim" width={1920} height={SCRIM_H} opacity={0.85 * scrim} fill={linearGradient(['#000000ff', '#000000b8', '#00000050', '#00000000'], { angle: 180 })} />}
        {TITLES.map((t) => <Headline key={t.id} t={t} f={f} />)}
      </Layer>
    </AbsoluteFill>
  );
};
