/** Scene 11: My Apps +, pick the IPA, then the App Contains Extensions dialog: the second option is the right one, Remove is not. The dialog is never pressed. */
import type { SceneSpec } from '../../lib/sceneSpec.ts';

export const scene11: SceneSpec = {
  n: 11,
  beats: [
    // 開著 LocalDevVPN，在 My Apps 按左上角的加號，選這個 IPA。
    { screen: 'addIpa', device: 'iphone', steps: [{ target: 'plus', press: true }, { target: 'ipa', press: true }] },
    // 詢問 Extension 時，選第二個，
    { screen: 'extDialog', device: 'iphone', steps: [{ target: 'keepEach' }], labels: [{ target: 'keepEach', kind: 'good' }] },
    // Register App ID for Each Extension。
    { screen: 'extDialog', device: 'iphone', steps: [{ target: 'keepEach' }], labels: [{ target: 'keepEach', kind: 'good' }] },
    // 千萬不要選 Remove，否則就沒有鍵盤了。 Both callouts together for at least 3 seconds.
    {
      screen: 'extDialog',
      device: 'iphone',
      steps: [{ target: 'keepEach' }],
      labels: [{ target: 'keepEach', kind: 'good' }, { target: 'remove', kind: 'bad' }],
      minSeconds: 3.5,
    },
  ],
};
