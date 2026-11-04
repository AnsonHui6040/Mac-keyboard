/** Scene 5: iloader on the Mac, the cable, 信任 on the iPhone, add the account, install Stable SideStore. */
import type { SceneSpec } from '../../lib/sceneSpec.ts';

export const scene05: SceneSpec = {
  n: 5,
  beats: [
    // 接著在 Mac 下載 iloader，用 USB 線接上 iPhone，
    { screen: 'iloader', device: 'mac' },
    // 在 iPhone 按「信任」。
    { screen: 'iloader', device: 'iphone', steps: [{ target: 'trust', press: true }] },
    // 在 iloader 登入你的 Apple 帳號，確認有列出 iPhone，
    { screen: 'iloader', device: 'mac', steps: [{ target: 'add', press: true }, { target: 'device' }] },
    // 再安裝 Stable SideStore。
    { screen: 'iloader', device: 'mac', steps: [{ target: 'stable', press: true }] },
  ],
};
