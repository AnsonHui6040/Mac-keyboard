/** Scene 13: the 允許完整取用 switch, the warning, 允許. */
import type { SceneSpec } from '../../lib/sceneSpec.ts';

export const scene13: SceneSpec = {
  n: 13,
  beats: [
    // 開啟「允許完整取用」，出現警告時按「允許」。
    { screen: 'fullAccess', device: 'iphone', steps: [{ target: 'toggle', press: true }, { target: 'allow', press: true }] },
    // 遠端打字和手寫都需要這項權限。
    { screen: 'fullAccess', device: 'iphone', hidePointer: true },
  ],
};
