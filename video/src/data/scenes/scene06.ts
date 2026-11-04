/** Scene 6: trust the developer, allow and restart, then Developer Mode. All on the iPhone. */
import type { SceneSpec } from '../../lib/sceneSpec.ts';

export const scene06: SceneSpec = {
  n: 6,
  beats: [
    // 到「設定」、「一般」、「VPN 與裝置管理」，
    { screen: 'settingsFlow', device: 'iphone', steps: [{ target: 'settings', press: true }, { target: 'general', press: true }, { target: 'vpnmgmt', press: true }] },
    // 信任你的 Apple 帳號，選「允許並重新啟動」，再輸入密碼。
    { screen: 'settingsFlow', device: 'iphone', steps: [{ target: 'row', press: true }, { target: 'trust', press: true }, { target: 'allow', press: true }, { target: 'keypad' }] },
    // 如果 iOS 要求開發者模式，就到「隱私權與安全性」最下方開啟。
    { screen: 'settingsFlow', device: 'iphone', steps: [{ target: 'privacy', press: true }, { target: 'devmode', press: true }] },
    // 手機重新啟動後，在確認視窗選擇開啟，並輸入密碼。
    { screen: 'settingsFlow', device: 'iphone', steps: [{ target: 'on', press: true }, { target: 'keypad' }] },
  ],
};
