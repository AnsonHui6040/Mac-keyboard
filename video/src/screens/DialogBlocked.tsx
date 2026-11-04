import { Layer } from '@kinetographdev/core';
import { MacButton, MacDialog, DialogTitle, GatekeeperIcon } from '../components/MacDialog.tsx';
import { SkeletonLines } from '../components/SkeletonLines.tsx';
import { DIALOGS, SCREENS } from './geometry.ts';

/** 未打開「…」: 完成 (neutral, left) and 丟到垃圾桶 (blue, right). */
export const DialogBlocked = () => {
  const d = DIALOGS.dialogBlocked;
  const b = SCREENS.dialogBlocked;
  return (
    <Layer id="screen-dialogBlocked">
      <MacDialog rect={d}>
        <GatekeeperIcon x={d.x + 40} y={d.y + 40} />
        <DialogTitle x={d.x + 40} y={d.y + 184}>{'未打開「Remote Keyboard\nReceiver.app」'}</DialogTitle>
        <SkeletonLines x={d.x + 40} y={d.y + 304} widths={[500, 510, 270]} />
        <MacButton target="done" rect={b.done} label="完成" />
        <MacButton target="trash" rect={b.trash} label="丟到垃圾桶" blue size={28} />
      </MacDialog>
    </Layer>
  );
};
