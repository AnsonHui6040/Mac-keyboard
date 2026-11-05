/** Scene 10: the Release page, 終端機 with the command and both hashes, then AirDrop to the iPhone and 存到「檔案」. */
import type { SceneSpec } from '../../lib/sceneSpec.ts';

export const scene10: SceneSpec = {
  n: 10,
  beats: [
    // 現在到 GitHub 的 Release 頁面下載 IPA，
    { screen: 'ipaDownload', device: 'mac', steps: [{ target: 'ipadl', press: true }] },
    // 打開「終端機」輸入指令，核對 SHA-256 完全相同，
    // The command and both hashes stay on screen: 9 s minus the typing leaves about 7.8 s (at least 6 s are required).
    { screen: 'ipaVerify', device: 'mac', steps: [{ target: 'hash' }], minSeconds: 9 },
    // 再用 AirDrop 傳到 iPhone，存到「檔案」。
    { screen: 'ipaSend', device: 'mac', steps: [{ target: 'airdrop', press: true }, { target: 'save', press: true, device: 'iphone' }] },
  ],
};
