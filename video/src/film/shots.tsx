/** The close-up shots: a locked camera on the slab (cameras.ts) and the live screen under it. The 3D shots are Stage.tsx. */
import { Layer } from '@kinetographdev/core';
import { MacScreen } from './MacScreen.tsx';
import { PhoneScreen } from './PhoneScreen.tsx';
import { PhoneRings } from './Fingers.tsx';
import { Slab } from './Slab.tsx';
import { closeCam } from './cameras.ts';
import { MAC, PHONE_TOP } from './layout.ts';
import { phoneAt } from './state.ts';

export const CloseShot = ({ id, f }: { id: string; f: number }) => {
  const c = closeCam(id, f);
  if (c.dev === 'phone') {
    return (
      <Slab w={720} h={755} p={c.p} fx={c.fx} fy={c.fy} sharp={c.sharp}
        overlay={<Layer y={-PHONE_TOP}><PhoneRings f={f} /></Layer>}>
        <Layer y={-PHONE_TOP}><PhoneScreen state={phoneAt(f)} f={f} /></Layer>
      </Slab>
    );
  }
  return (
    <Slab w={MAC.w} h={MAC.h} p={c.p} fx={c.fx} fy={c.fy} sharp={c.sharp}>
      <MacScreen f={f} />
    </Slab>
  );
};
