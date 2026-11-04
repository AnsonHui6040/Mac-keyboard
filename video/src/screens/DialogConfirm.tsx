import { Layer } from '@kinetographdev/core';
import { MacButton, MacDialog, DialogTitle, GatekeeperIcon } from '../components/MacDialog.tsx';
import { SkeletonLines } from '../components/SkeletonLines.tsx';
import { DIALOGS, SCREENS } from './geometry.ts';

/** 要打開「…」嗎？ with 丟到垃圾桶 (blue), 強制打開, 完成 stacked. */
export const DialogConfirm = () => {
  const d = DIALOGS.dialogConfirm;
  const b = SCREENS.dialogConfirm;
  return (
    <Layer id="screen-dialogConfirm">
      <MacDialog rect={d}>
        <GatekeeperIcon x={d.x + 40} y={d.y + 40} />
        <DialogTitle x={d.x + 40} y={d.y + 184}>{'要打開「Remote Keyboard\nReceiver.app」嗎？'}</DialogTitle>
        <SkeletonLines x={d.x + 40} y={d.y + 304} widths={[500, 510, 470, 270]} />
        <MacButton target="trash" rect={b.trash} label="丟到垃圾桶" blue />
        <MacButton target="open" rect={b.open} label="強制打開" />
        <MacButton target="done" rect={b.done} label="完成" />
      </MacDialog>
    </Layer>
  );
};
