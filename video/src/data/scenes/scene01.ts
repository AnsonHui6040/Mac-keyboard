/** Scene 1: typing on the iPhone shows up on the Mac. No device tag, no pointer. */
import type { SceneSpec } from '../../lib/sceneSpec.ts';

export const scene01: SceneSpec = {
  n: 1,
  beats: [{ screen: 'typing' }, { screen: 'typing' }],
};
