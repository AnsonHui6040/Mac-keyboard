import { Composition, registerFont, registerRoot, staticFile } from '@kinetographdev/core';
import { FPS, HEIGHT, SCENES, WIDTH, sceneFrames, sceneId } from './data/scenes/index.ts';
import { SceneRunner } from './scenes/SceneRunner.tsx';
import { theme } from './theme.ts';

registerFont({ family: theme.font, weight: 400, path: staticFile('fonts/NotoSansTC-Regular.ttf') });
registerFont({ family: theme.font, weight: 500, path: staticFile('fonts/NotoSansTC-Medium.ttf') });
registerFont({ family: theme.font, weight: 700, path: staticFile('fonts/NotoSansTC-Bold.ttf') });

// One composition per scene (Scene16, ...): the runner draws whichever spec it is given.
const scenes = SCENES.map((spec) => ({ spec, Component: () => <SceneRunner spec={spec} /> }));

registerRoot(() => (
  <>
    {scenes.map(({ spec, Component }) => (
      <Composition key={spec.n} id={sceneId(spec.n)} component={Component} durationInFrames={sceneFrames(spec.n)} fps={FPS} width={WIDTH} height={HEIGHT} />
    ))}
  </>
));
