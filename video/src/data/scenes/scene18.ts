/** Scene 18: 配對新 iPhone on the Mac, 已配對 Mac and 配對 Mac on the iPhone, the same code on both, 確認 on the Mac and then on the iPhone. */
import type { SceneSpec } from '../../lib/sceneSpec.ts';

export const scene18: SceneSpec = {
  n: 18,
  beats: [
    // 最後是配對。
    { screen: 'pairFlow', device: 'mac' },
    // 在 Mac 面板按「配對新 iPhone」。
    { screen: 'pairFlow', device: 'mac', steps: [{ target: 'pairNew', press: true }] },
    // 在 iPhone 的 App 按「已配對 Mac」，再按「配對 Mac」。
    { screen: 'pairFlow', device: 'iphone', steps: [{ target: 'phoneRow', press: true }, { target: 'pairMac', press: true }] },
    // 兩邊會顯示同一組六位數字，核對完全相同後，
    { screen: 'pairFlow' },
    // 先在 Mac、再在 iPhone 按「確認」。
    { screen: 'pairFlow', device: 'mac', steps: [{ target: 'macConfirm', press: true }, { target: 'phoneConfirm', press: true, device: 'iphone' }] },
  ],
};
