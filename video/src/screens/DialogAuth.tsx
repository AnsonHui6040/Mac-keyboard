import { Layer } from '@kinetographdev/core';
import { MacButton, MacDialog, TouchIdIcon } from '../components/MacDialog.tsx';
import { SkeletonLines } from '../components/SkeletonLines.tsx';
import { DIALOGS, SCREENS } from './geometry.ts';

/** Touch ID prompt: 使用密碼⋯ and 取消. Title and body are gray lines. */
export const DialogAuth = () => {
  const d = DIALOGS.auth;
  const b = SCREENS.auth;
  return (
    <Layer id="screen-auth">
      <MacDialog rect={d}>
        <TouchIdIcon x={d.x + 40} y={d.y + 40} />
        <SkeletonLines x={d.x + 40} y={d.y + 196} widths={[480, 360]} />
        <SkeletonLines x={d.x + 40} y={d.y + 296} widths={[500, 510, 230]} />
        <MacButton target="password" rect={b.password} label="使用密碼⋯" />
        <MacButton target="cancel" rect={b.cancel} label="取消" />
      </MacDialog>
    </Layer>
  );
};
