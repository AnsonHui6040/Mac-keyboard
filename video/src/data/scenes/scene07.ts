/** Scene 7: LocalDevVPN shows 已連線, open SideStore, sign in. */
import type { SceneSpec } from '../../lib/sceneSpec.ts';

export const scene07: SceneSpec = {
  n: 7,
  beats: [
    // 確認 LocalDevVPN 顯示「已連線」，打開 SideStore，
    { screen: 'signIn', device: 'iphone', steps: [{ target: 'status' }, { target: 'sidestore', press: true }] },
    // 用剛才同一個 Apple 帳號登入。
    { screen: 'signIn', device: 'iphone', steps: [{ target: 'signin', press: true }] },
  ],
};
