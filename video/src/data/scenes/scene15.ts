/** Scene 15: on the Mac, download the zip, compare SHA-256, double click to unzip, drag the app to 應用程式. The drag has no press: the screen draws the icon at the pointer. */
import type { SceneSpec } from '../../lib/sceneSpec.ts';

export const scene15: SceneSpec = {
  n: 15,
  beats: [
    // 換到 Mac。
    { screen: 'zipFlow', device: 'mac' },
    // 下載 zip，同樣核對 SHA-256，連按兩下解壓縮，
    { screen: 'zipFlow', device: 'mac', steps: [{ target: 'zipdl', press: true }, { target: 'hash' }, { target: 'zipfile', press: true }] },
    // 把 Receiver 拖到「應用程式」。
    { screen: 'zipFlow', device: 'mac', steps: [{ target: 'receiver' }, { target: 'apps' }] },
  ],
};
