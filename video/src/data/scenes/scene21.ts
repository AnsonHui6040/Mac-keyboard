/** Scene 21: the Mac asks about the local network (允許), a calendar with 7 days marked, SideStore for the refresh, the manual on GitHub, chapters 04b and 04c for Windows and Linux. Only the first beat has a device and a pointer. */
import type { SceneSpec } from '../../lib/sceneSpec.ts';

export const scene21: SceneSpec = {
  n: 21,
  beats: [
    // 第一次用觸控板時，Mac 會詢問區域網路，按「允許」。
    { screen: 'macLan', device: 'mac', steps: [{ target: 'allow', press: true }] },
    // 免費帳號簽署的 App 只有 7 天有效，
    { screen: 'calendar' },
    // 記得在到期前到 SideStore 續簽。
    { screen: 'calendar' },
    // 遇到問題，請看 GitHub 上的使用手冊。
    { screen: 'calendar' },
    // Windows 與 Linux 的接收端，請看手冊第 04b、04c 章。
    { screen: 'calendar' },
  ],
};
