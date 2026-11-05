import { AbsoluteFill, Composition, Layer, Series, registerFont, registerRoot, staticFile, useCurrentFrame } from '@kinetographdev/core';
import { FILM_FRAMES, FPS, HEIGHT, SCENES, WIDTH, sceneFrames, sceneId } from './data/scenes/index.ts';
import { openingFade } from './lib/fade.ts';
import { SceneRunner } from './scenes/SceneRunner.tsx';
import { theme } from './theme.ts';

registerFont({ family: theme.font, weight: 400, path: staticFile('fonts/NotoSansTC-Regular.ttf') });
registerFont({ family: theme.font, weight: 500, path: staticFile('fonts/NotoSansTC-Medium.ttf') });
registerFont({ family: theme.font, weight: 700, path: staticFile('fonts/NotoSansTC-Bold.ttf') });

// One composition per scene (Scene16, ...): the runner draws whichever spec it is given.
const scenes = SCENES.map((spec) => ({ spec, Component: () => <SceneRunner spec={spec} /> }));

// The whole film: the scenes back to back inside Series, each one starting with an 8 frame fade up from the stage color.
// The fade is a layer over the scene, so a scene's own composition (Scene16, ...) stays as it is and no frame is added.
const OpeningFade = ({ children }: { children: React.ReactNode }) => {
  const frame = useCurrentFrame();
  const opacity = openingFade(frame);
  // After the fade there is no wrapper layer at all, so those frames draw exactly as the scene's own composition does.
  return opacity >= 1 ? <>{children}</> : (
    <AbsoluteFill style={{ backgroundColor: theme.stage }}>
      <Layer id="scene-fade" opacity={opacity}>{children}</Layer>
    </AbsoluteFill>
  );
};

const Film = () => (
  <Series>
    {scenes.map(({ spec, Component }) => (
      <Series.Sequence key={spec.n} durationInFrames={sceneFrames(spec.n)}>
        <OpeningFade><Component /></OpeningFade>
      </Series.Sequence>
    ))}
  </Series>
);

registerRoot(() => (
  <>
    <Composition id="Main" component={Film} durationInFrames={FILM_FRAMES} fps={FPS} width={WIDTH} height={HEIGHT} />
    {scenes.map(({ spec, Component }) => (
      <Composition key={spec.n} id={sceneId(spec.n)} component={Component} durationInFrames={sceneFrames(spec.n)} fps={FPS} width={WIDTH} height={HEIGHT} />
    ))}
  </>
));
