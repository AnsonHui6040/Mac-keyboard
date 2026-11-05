import { AbsoluteFill, Layer, useCurrentFrame } from '@kinetographdev/core';
import { openingFade } from '../lib/fade.ts';
import { theme } from '../theme.ts';
import { Chapter0, Chapter1, Chapter2 } from './Mac.tsx';
import { Phone } from './Phone.tsx';
import { IntroCaption } from './IntroCaption.tsx';
import { captionAt, layerAt } from './timeline.ts';

/** The picture of one chapter: Mac display on the left, phone on the right, both at the chapter's own frame. */
const Picture = ({ chapter, at }: { chapter: 0 | 1 | 2; at: number }) => (
  <Layer id={`chapter-${chapter}`}>
    {chapter === 0 ? <Chapter0 at={at} /> : chapter === 1 ? <Chapter1 at={at} /> : <Chapter2 at={at} />}
    <Phone at={at} chapter={chapter} />
  </Layer>
);

export const ProductIntro = () => {
  const frame = useCurrentFrame();
  const l = layerAt(frame);
  const fade = openingFade(frame);
  const body = (
    <>
      <Layer id="picture" opacity={l.opacity}><Picture chapter={l.chapter} at={l.at} /></Layer>
      <IntroCaption text={captionAt(frame)} />
    </>
  );
  return (
    <AbsoluteFill style={{ backgroundColor: theme.stage }}>
      {fade >= 1 ? body : <Layer id="opening-fade" opacity={fade}>{body}</Layer>}
    </AbsoluteFill>
  );
};
