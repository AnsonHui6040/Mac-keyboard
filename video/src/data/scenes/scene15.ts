/**
 * Scene 15: on the Mac, download the zip, compare SHA-256 in 終端機, double click to unzip, drag the app to 應用程式, then open it from 應用程式.
 * Step weights are the frames each page needs: the terminal page keeps the hash on screen for at least 4 s, so its step gets the longest slot.
 * The drag has no press: the screen draws the icon at the pointer.
 */
import type { SceneSpec } from '../../lib/sceneSpec.ts';

export const scene15: SceneSpec = {
  n: 15,
  beats: [
    // 換到 Mac。
    { screen: 'zipFlow', device: 'mac' },
    // 下載 zip，同樣在「終端機」核對 SHA-256，連按兩下解壓縮，
    {
      screen: 'zipFlow',
      device: 'mac',
      steps: [{ target: 'zipdl', press: true, weight: 50 }, { target: 'hash', weight: 170 }, { target: 'zipfile', press: true, weight: 90 }],
      minSeconds: 10,
    },
    // 把 Receiver 拖到「應用程式」，再從「應用程式」打開它。
    {
      screen: 'zipFlow',
      device: 'mac',
      steps: [{ target: 'receiver', weight: 34 }, { target: 'apps', weight: 34 }, { target: 'apps', press: true, weight: 42 }, { target: 'rkapp', press: true, weight: 80 }],
    },
  ],
};
