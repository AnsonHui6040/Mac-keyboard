/** Scene 20: click in the TextEdit document, bring up the keyboard on the iPhone, globe key to Remote Keyboard, 遠端, 已連接, type. */
import type { SceneSpec } from '../../lib/sceneSpec.ts';

export const scene20: SceneSpec = {
  n: 20,
  beats: [
    // 先在 Mac 打開「文字編輯」，在文件裡點一下。
    { screen: 'keyboardOn', device: 'mac', steps: [{ target: 'doc', press: true }] },
    // 接著在 iPhone 的任何輸入框叫出鍵盤，
    { screen: 'keyboardOn', device: 'iphone', steps: [{ target: 'field', press: true }] },
    // 按住地球鍵選 Remote Keyboard，再選「遠端」。
    { screen: 'keyboardOn', device: 'iphone', steps: [{ target: 'globe', press: true }, { target: 'rk', press: true }, { target: 'remote', press: true }] },
    // 看到綠色的「已連接」，打字就會出現在 Mac 上。
    { screen: 'keyboardOn' },
  ],
};
