/** Scene 14: open the app, the four guide pages, 設定進度 > 藍牙 > 允許藍牙 > 允許. */
import type { SceneSpec } from '../../lib/sceneSpec.ts';

export const scene14: SceneSpec = {
  n: 14,
  beats: [
    // 打開 Remote Keyboard，看完引導後，在「設定進度」按「藍牙」，
    {
      screen: 'appSetup',
      device: 'iphone',
      steps: [
        { target: 'open', press: true },
        { target: 'next', press: true },
        { target: 'next', press: true },
        { target: 'next', press: true },
        { target: 'next', press: true },
        { target: 'bt', press: true },
      ],
    },
    // 再按「允許藍牙」和「允許」。
    { screen: 'appSetup', device: 'iphone', steps: [{ target: 'allowbt', press: true }, { target: 'allow', press: true }] },
    // iPhone 這邊就好了。
    { screen: 'appSetup', device: 'iphone' },
  ],
};
