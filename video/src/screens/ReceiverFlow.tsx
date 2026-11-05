import { Layer } from '@kinetographdev/core';
import { fadeIn } from '../components/PhoneScreen.tsx';
import { AccessWindow, BluetoothDialog, MenuBar, ReceiverPanel } from './macReceiver.tsx';
import { PANEL17 } from './layouts.ts';
import type { ScreenProps } from './registry.tsx';

/**
 * Scene 17, beat 1: the menu bar. A press on the keyboard icon opens the panel under it, whose red line says 尚未授權輔助使用;
 * the second step presses 授權輔助使用. The panel fades in when the first press lands.
 */
export const ReceiverMenu = ({ beatFrame, stepTimes }: ScreenProps) => {
  const open = fadeIn(beatFrame, stepTimes[0]?.land ?? Infinity, 6);
  return (
    <Layer id="screen-receiverMenu">
      <MenuBar open={open} />
      {open > 0 && (
        <Layer id="panel-fade" opacity={open}>
          <ReceiverPanel layout={PANEL17} state={{ kind: 'access', link: 'idle', access: true }} />
        </Layer>
      )}
    </Layer>
  );
};

/** Scene 17, beat 2: the Accessibility list; the switch of Remote Keyboard Receiver turns on when the press lands. */
export const MacAccess = ({ beatFrame, stepTimes }: ScreenProps) => (
  <AccessWindow on={fadeIn(beatFrame, stepTimes[0]?.land ?? Infinity, 5)} />
);

/** Scene 17, beat 0: the system asks about Bluetooth. */
export const MacBluetooth = () => <BluetoothDialog />;
