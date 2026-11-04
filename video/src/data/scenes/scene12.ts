/** Scene 12: Settings > 一般 > 鍵盤 > 鍵盤 > 新增鍵盤 > Remote Keyboard, then the keyboard list row. */
import type { SceneSpec } from '../../lib/sceneSpec.ts';

export const scene12: SceneSpec = {
  n: 12,
  beats: [
    // 到「設定」、「一般」、「鍵盤」、「鍵盤」，按「新增鍵盤」，
    {
      screen: 'kbSettings',
      device: 'iphone',
      steps: [{ target: 'settings', press: true }, { target: 'general', press: true }, { target: 'kbmenu', press: true }, { target: 'kblist', press: true }, { target: 'add', press: true }],
    },
    // 在第三方鍵盤選 Remote Keyboard。
    { screen: 'kbAdd', device: 'iphone', steps: [{ target: 'rk', press: true }] },
    // 回到鍵盤清單，再按一下這一列。
    { screen: 'kbList', device: 'iphone', steps: [{ target: 'rkrow', press: true }] },
  ],
};
