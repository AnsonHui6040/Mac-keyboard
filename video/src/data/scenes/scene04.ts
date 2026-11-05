/** Scene 4: install LocalDevVPN from the App Store, connect, allow, and read 已連線. */
import type { SceneSpec } from '../../lib/sceneSpec.ts';

export const scene04: SceneSpec = {
  n: 4,
  beats: [
    // 第一步，在 iPhone 的 App Store 安裝 LocalDevVPN。
    { screen: 'vpnFlow', device: 'iphone', steps: [{ target: 'get', press: true }] },
    // 打開後按連線，再按「允許」，看到「已連線」就可以了。
    { screen: 'vpnFlow', device: 'iphone', steps: [{ target: 'connect', press: true }, { target: 'allow', press: true }, { target: 'status' }] },
  ],
};
