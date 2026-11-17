/** The close-up cuts of the v0.2 promo: a locked camera on the slab (cameras.ts) and the live screen under it. */
import { Layer } from '@kinetographdev/core';
import { MacScreen } from '../film/MacScreen.tsx';
import { PhoneScreen } from '../film/PhoneScreen.tsx';
import { PhoneRings } from '../film/Fingers.tsx';
import { Slab } from '../film/Slab.tsx';
import { MAC, PHONE_TOP } from '../film/layout.ts';
import { closeCam } from './cameras.ts';
import { INK_FROM } from './events.ts';
import { LinuxScreen } from './LinuxScreen.tsx';
import { WinScreen } from './WinScreen.tsx';
import { docAt, promoFingerAt, promoInkAt, promoMacAt, promoPhoneAt, promoTrackAt } from './state.ts';

const INK = { from: INK_FROM, strokes: promoInkAt };

export const CloseShot = ({ id, f }: { id: string; f: number }) => {
  const c = closeCam(id, f);
  if (c.dev === 'phone') {
    return (
      <Slab w={720} h={755} p={c.p} fx={c.fx} fy={c.fy} sharp={c.sharp}
        overlay={<Layer y={-PHONE_TOP}><PhoneRings f={f} finger={promoFingerAt} pad={promoTrackAt} /></Layer>}>
        <Layer y={-PHONE_TOP}><PhoneScreen state={promoPhoneAt(f)} f={f} ink={INK} /></Layer>
      </Slab>
    );
  }
  return (
    <Slab w={MAC.w} h={MAC.h} p={c.p} fx={c.fx} fy={c.fy} sharp={c.sharp}>
      {c.dev === 'mac' && <MacScreen f={f} state={promoMacAt(f)} />}
      {c.dev === 'win' && <WinScreen f={f} {...docAt('Windows', f)} />}
      {c.dev === 'linux' && <LinuxScreen f={f} {...docAt('Linux', f)} />}
    </Slab>
  );
};
