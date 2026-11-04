import { Composition, registerFont, registerRoot, staticFile } from '@kinetographdev/core';
import { SCENE16_FPS, SCENE16_FRAMES } from './data/scene16.ts';
import { Scene16 } from './scenes/Scene16.tsx';
import { theme } from './theme.ts';

registerFont({ family: theme.font, weight: 400, path: staticFile('fonts/NotoSansTC-Regular.ttf') });
registerFont({ family: theme.font, weight: 500, path: staticFile('fonts/NotoSansTC-Medium.ttf') });
registerFont({ family: theme.font, weight: 700, path: staticFile('fonts/NotoSansTC-Bold.ttf') });

registerRoot(() => (
  <Composition id="Scene16" component={Scene16} durationInFrames={SCENE16_FRAMES} fps={SCENE16_FPS} width={1920} height={1080} />
));
