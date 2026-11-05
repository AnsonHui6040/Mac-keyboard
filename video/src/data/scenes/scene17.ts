/** Scene 17: allow Bluetooth, open the panel from the menu bar, 打開輔助使用設定, switch on Remote Keyboard Receiver. */
import type { SceneSpec } from '../../lib/sceneSpec.ts';

export const scene17: SceneSpec = {
  n: 17,
  beats: [
    // 系統詢問藍牙時按「允許」。
    { screen: 'macBluetooth', device: 'mac', steps: [{ target: 'allow', press: true }] },
    // 再點選單列的鍵盤圖示，按「打開輔助使用設定」，
    { screen: 'receiverMenu', device: 'mac', steps: [{ target: 'icon', press: true }, { target: 'openSettings', press: true }] },
    // 在清單裡開啟 Remote Keyboard Receiver。
    { screen: 'macAccess', device: 'mac', steps: [{ target: 'toggle', press: true }] },
  ],
};
