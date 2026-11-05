/** Scene 8: My Apps, 7 DAYS, the refresh question. */
import type { SceneSpec } from '../../lib/sceneSpec.ts';

export const scene08: SceneSpec = {
  n: 8,
  beats: [
    // 登入後到 My Apps，
    { screen: 'myApps', device: 'iphone', steps: [{ target: 'myapps', press: true }] },
    // 按 SideStore 旁邊的「7 DAYS」完成第一次續簽。
    { screen: 'myApps', device: 'iphone', steps: [{ target: 'days', press: true }] },
    // 如果跳出詢問，按 Yes 或 Refresh Now。
    { screen: 'myApps', device: 'iphone', steps: [{ target: 'refresh', press: true }] },
    // 做完才能安裝其他 App。
    { screen: 'myApps', device: 'iphone', steps: [{ target: 'days' }] },
  ],
};
