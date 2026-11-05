/** Scene 5: sidestore.io and the iloader download, the cable, 信任 on the iPhone, sign in, the verification code, install Stable SideStore. */
import type { SceneSpec } from '../../lib/sceneSpec.ts';

export const scene05: SceneSpec = {
  n: 5,
  beats: [
    // 接著到 sidestore.io 下載 iloader 並打開，
    { screen: 'iloader', device: 'mac', steps: [{ target: 'idl', press: true }, { target: 'open' }], minSeconds: 4 },
    // 用 USB 線接上 iPhone，在 iPhone 按「信任」。
    { screen: 'iloader', device: 'iphone', steps: [{ target: 'trust', press: true }] },
    // 在 iloader 登入你的 Apple 帳號，如果要驗證碼，
    { screen: 'iloader', device: 'mac', steps: [{ target: 'add', press: true }, { target: 'signin', press: true }] },
    // 輸入 Apple 裝置收到的號碼。
    { screen: 'iloader', device: 'mac', steps: [{ target: 'code' }], minSeconds: 4 },
    // 確認有列出 iPhone，再安裝 Stable SideStore。
    { screen: 'iloader', device: 'mac', steps: [{ target: 'device' }, { target: 'stable', press: true }] },
  ],
};
