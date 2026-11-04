/** Scene 10: download the IPA on the Mac, compare SHA-256, AirDrop it, save it to Files on the iPhone. */
import type { SceneSpec } from '../../lib/sceneSpec.ts';

export const scene10: SceneSpec = {
  n: 10,
  beats: [
    // 現在到 GitHub 的 Release 頁面下載 IPA，
    { screen: 'ipaDownload', device: 'mac', steps: [{ target: 'ipadl', press: true }] },
    // 核對 SHA-256 完全相同，再用 AirDrop 傳到 iPhone，
    { screen: 'ipaVerify', device: 'mac', steps: [{ target: 'hash' }, { target: 'airdrop', press: true }] },
    // 存到「檔案」。
    { screen: 'ipaSave', device: 'iphone', steps: [{ target: 'save', press: true }] },
  ],
};
