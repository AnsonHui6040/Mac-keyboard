/** Scene 19: 已儲存 on both, 完成 on the Mac and then on the iPhone. */
import type { SceneSpec } from '../../lib/sceneSpec.ts';

export const scene19: SceneSpec = {
  n: 19,
  beats: [
    // 兩邊都確認之後，再各按一次「完成」，配對就好了。
    { screen: 'pairDone', device: 'mac', steps: [{ target: 'macDone', press: true }, { target: 'phoneDone', press: true, device: 'iphone' }] },
  ],
};
