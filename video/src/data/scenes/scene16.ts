/** Scene 16: Gatekeeper blocks the app; open it from Privacy & Security, then confirm. */
import type { SceneSpec } from '../../lib/sceneSpec.ts';

export const scene16: SceneSpec = {
  n: 16,
  beats: [
    { screen: 'dialogBlocked', device: 'mac' },
    { screen: 'dialogBlocked', device: 'mac' },
    { screen: 'dialogBlocked', device: 'mac', steps: [{ target: 'done', press: true }] },
    { screen: 'settingsSecurity', device: 'mac', steps: [{ target: 'open', press: true }] },
    { screen: 'dialogConfirm', device: 'mac', steps: [{ target: 'open' }], labels: [{ target: 'open', kind: 'good' }] },
    {
      screen: 'dialogConfirm',
      device: 'mac',
      steps: [{ target: 'open' }],
      labels: [{ target: 'open', kind: 'good' }, { target: 'trash', kind: 'bad' }],
      minSeconds: 4,
    },
    { screen: 'auth', device: 'mac', steps: [{ target: 'password' }] },
  ],
};
