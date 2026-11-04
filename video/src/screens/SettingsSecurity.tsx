import { Layer, Rect, Text, dropShadow } from '@kinetographdev/core';
import { MacButton } from '../components/MacDialog.tsx';
import { SkeletonLines } from '../components/SkeletonLines.tsx';
import { theme } from '../theme.ts';
import { SCREENS, SETTINGS_SIDEBAR_W, SETTINGS_WINDOW } from './geometry.ts';

const W = SETTINGS_WINDOW;
const CARD = `${theme.neutralBtn.fill}66`;
const PANE_X = W.x + SETTINGS_SIDEBAR_W + 40;
const PANE_W = W.width - SETTINGS_SIDEBAR_W - 80;

const Sidebar = () => {
  const rowY = (i: number) => W.y + 120 + i * 56;
  const bars = [120, 150, 100, 140, 0, 130, 110, 150, 120];
  return (
    <Layer id="sidebar">
      <Rect x={W.x + 30} y={W.y + 36} width={220} height={44} radius={22} fill={theme.skeleton.color} />
      {bars.map((w, i) =>
        i === 4 ? (
          <Layer key={i} id="sidebar-selected">
            <Rect x={W.x + 16} y={rowY(i) - 6} width={SETTINGS_SIDEBAR_W - 32} height={52} radius={14} fill={theme.blue} />
            <Rect x={W.x + 32} y={rowY(i) + 4} width={28} height={28} radius={8} fill="#ffffff55" />
            <Text font={theme.font} weight={500} size={26} color="#ffffff" x={W.x + 70} y={rowY(i) + 1}>隱私權與安全性</Text>
          </Layer>
        ) : (
          <Layer key={i}>
            <Rect x={W.x + 32} y={rowY(i) + 4} width={28} height={28} radius={8} fill={theme.skeleton.color} />
            <Rect x={W.x + 70} y={rowY(i) + 10} width={w} height={theme.skeleton.height} radius={theme.skeleton.radius} fill={theme.skeleton.color} />
          </Layer>
        ),
      )}
    </Layer>
  );
};

const Card = ({ y, height }: { y: number; height: number }) => (
  <Rect x={PANE_X} y={y} width={PANE_W} height={height} radius={22} fill={CARD} />
);
const Hair = ({ y }: { y: number }) => <Rect x={PANE_X + 24} y={y} width={PANE_W - 48} height={2} fill={theme.hairline} />;
const Pill = ({ x, y, w }: { x: number; y: number; w: number }) => <Rect x={x} y={y} width={w} height={40} radius={20} fill={theme.skeleton.color} />;

/** System Settings > 隱私權與安全性, scrolled to 安全性 with the blocked-app row and its 強制打開 button. */
export const SettingsSecurity = () => {
  const open = SCREENS.settingsSecurity.open;
  const rowRight = PANE_X + PANE_W - 28;
  const cardBY = 338;
  return (
    <Layer id="screen-settingsSecurity">
      <Layer id="window" x={0} y={0} effects={[dropShadow({ y: 18, blur: 54, color: theme.dialog.shadow })]}>
        <Rect x={W.x} y={W.y} width={W.width} height={W.height} radius={30} fill={theme.dialog.fill} stroke={{ color: theme.dialog.edge, width: 2 }} />
      </Layer>
      <Rect x={W.x + SETTINGS_SIDEBAR_W} y={W.y + 2} width={2} height={W.height - 4} fill={theme.hairline} />
      <Sidebar />

      <Card y={W.y + 40} height={150} />
      <Rect x={PANE_X + 28} y={W.y + 40 + 29} width={300} height={theme.skeleton.height} radius={theme.skeleton.radius} fill={theme.skeleton.color} />
      <Pill x={rowRight - 140} y={W.y + 40 + 17} w={140} />
      <Hair y={W.y + 40 + 75} />
      <Rect x={PANE_X + 28} y={W.y + 40 + 104} width={380} height={theme.skeleton.height} radius={theme.skeleton.radius} fill={theme.skeleton.color} />
      <Pill x={rowRight - 100} y={W.y + 40 + 92} w={100} />

      <Text id="section-title" font={theme.font} weight={700} size={34} color={theme.dialog.title} x={PANE_X} y={274}>安全性</Text>

      <Card y={cardBY} height={322} />
      <Rect x={PANE_X + 28} y={cardBY + 34} width={340} height={theme.skeleton.height} radius={theme.skeleton.radius} fill={theme.skeleton.color} />
      <Pill x={rowRight - 220} y={cardBY + 22} w={220} />
      <Hair y={cardBY + 84} />
      <Text id="blocked-row" font={theme.font} weight={500} size={26} color={theme.dialog.title} x={PANE_X + 28} y={cardBY + 84 + 65 - 36} lineHeight={1.4}>
        {'已阻擋「Remote Keyboard Receiver.app」\n以保護你的Mac。'}
      </Text>
      <MacButton target="open" rect={open} label="強制打開" size={28} />
      <Hair y={cardBY + 214} />
      <SkeletonLines x={PANE_X + 28} y={cardBY + 214 + 26} widths={[700, 420]} />
    </Layer>
  );
};
