/** Mac pieces of scenes 17 to 19, drawn in canvas pixels: the Bluetooth question, the menu bar, the Receiver panel, the Accessibility list. */
import { Ellipse, Layer, Path, Rect, Text, dropShadow } from '@kinetographdev/core';
import { RkIcon } from '../components/appIcons.tsx';
import { Btn } from '../components/ios.tsx';
import { DialogTitle, MacButton, MacDialog } from '../components/MacDialog.tsx';
import { MacWindow } from '../components/MacWindow.tsx';
import { SkeletonLines } from '../components/SkeletonLines.tsx';
import { theme } from '../theme.ts';
import { CODE_LEFT, FOCUS_LINE, PAIR_CODE, REMAINING_LINE, WAIT_LEFT } from '../data/pairing.ts';
import { DIALOGS, SCREENS, type Rect as Box } from './geometry.ts';
import * as L from './layouts.ts';

const NONE = '#00000000';
const PANEL_FILL = '#2b2c31';
const BTN_FILL = '#3f4046';
const RED = '#ff6b62';
const ORANGE = '#ff9f0a';
const GREEN = '#30d158';


const T = ({ x, y, size = L.PANEL_TEXT, weight = 500, color = theme.ink, w, align, id, lineHeight, children }: { x: number; y: number; size?: number; weight?: 400 | 500 | 700; color?: string; w?: number; align?: 'left' | 'center' | 'right'; id?: string; lineHeight?: number; children: string }) => (
  <Text id={id} font={theme.font} weight={weight} size={size} color={color} x={x} y={y} maxWidth={w} align={align} lineHeight={lineHeight}>{children}</Text>
);
const rel = (r: Box): Box => ({ x: 0, y: 0, width: r.width, height: r.height });
/** Vertical offset that centers one line of `size` in a box of `h`. */
const mid = (h: number, size: number): number => (h - size * 1.45) / 2;

// ------------------------------------------------------------------ Bluetooth question (scene 17, beat 0)

/** 「Remote Keyboard Receiver」想要使用藍牙: 不允許 (neutral) and 允許 (blue). */
export const BluetoothDialog = () => {
  const d = DIALOGS.macBluetooth;
  const b = SCREENS.macBluetooth;
  return (
    <Layer id="screen-macBluetooth">
      <MacDialog rect={d}>
        <RkIcon x={d.x + 40} y={d.y + 40} size={118} />
        <DialogTitle x={d.x + 40} y={d.y + 184}>{'「Remote Keyboard\nReceiver」想要使用藍牙'}</DialogTitle>
        <SkeletonLines x={d.x + 40} y={d.y + 304} widths={[500, 510, 270]} />
        <MacButton target="deny" rect={b.deny} label="不允許" />
        <MacButton target="allow" rect={b.allow} label="允許" blue />
      </MacDialog>
    </Layer>
  );
};

// ------------------------------------------------------------------ menu bar

/** The Mac menu bar across the top. `open` highlights the keyboard icon (the panel is open). */
export const MenuBar = ({ open }: { open: number }) => {
  const i = L.MENU_ICON;
  return (
    <Layer id="menu-bar">
      <Rect x={0} y={0} width={1920} height={L.MENUBAR_H} fill="#202125" />
      <Rect x={0} y={L.MENUBAR_H - 2} width={1920} height={2} fill={theme.hairline} />
      <Ellipse x={30} y={18} width={24} height={24} fill={theme.muted} />
      {[100, 90, 70, 110].map((w, k) => (
        <Rect key={k} x={84 + [0, 130, 250, 350][k]} y={22} width={w} height={16} radius={8} fill={theme.skeleton.color} />
      ))}
      {[1500, 1560, 1620].map((x) => <Ellipse key={x} x={x} y={18} width={24} height={24} fill="#55565c" />)}
      <Rect x={i.x} y={i.y} width={i.width} height={i.height} radius={12} fill="#4a4b50" opacity={open} />
      <Btn target="icon" rect={i}>
        <Rect x={16} y={15} width={40} height={26} radius={6} fill={NONE} stroke={{ color: theme.ink, width: 3 }} />
        {[0, 1].flatMap((r) => [0, 1, 2, 3].map((c) => <Rect key={`${r}-${c}`} x={22 + c * 8} y={20 + r * 7} width={4} height={4} radius={1} fill={theme.ink} />))}
        <Rect x={26} y={34} width={20} height={3} radius={1.5} fill={theme.ink} />
      </Btn>
      <Rect x={1800} y={22} width={90} height={16} radius={8} fill={theme.skeleton.color} />
    </Layer>
  );
};

// ------------------------------------------------------------------ Receiver panel

const PBtn = ({ target, rect, label, blue = false, dim = 1 }: { target?: string; rect: Box; label: string; blue?: boolean; dim?: number }) => {
  const body = (
    <Layer opacity={dim}>
      <Rect width={rect.width} height={rect.height} radius={12} fill={blue ? theme.blue : BTN_FILL} />
      <T x={0} y={mid(rect.height, L.PANEL_TEXT)} w={rect.width} align="center" color={blue ? '#ffffff' : theme.neutralBtn.ink}>{label}</T>
    </Layer>
  );
  return target ? <Btn target={target} rect={rect}>{body}</Btn> : <Layer x={rect.x} y={rect.y}>{body}</Layer>;
};

const Checkbox = ({ x, y }: { x: number; y: number }) => (
  <Layer x={x} y={y}>
    <Rect width={30} height={30} radius={8} fill={theme.blue} />
    <Path d="M7 16 L13 22 L23 9" fill={NONE} stroke={{ color: '#ffffff', width: 4, cap: 'round', join: 'round' }} />
  </Layer>
);

export type PanelState = {
  kind: L.PanelKind;
  /** The link line: not receiving (gray), looking for the iPhone (orange) or connected (green). */
  link: 'idle' | 'searching' | 'ready';
  /** The Accessibility warning is on top, and the focus line cannot be read. */
  access: boolean;
};

const LINK_LABEL = { idle: '尚未開始接收', searching: '未連線，正在尋找 iPhone', ready: '已連線' } as const;
const LINK_DOT = { idle: '#8e8e93', searching: ORANGE, ready: GREEN } as const;

/** The menu bar panel at 2x. `kind` picks the pairing block; the layout comes from `panelLayout`. */
export const ReceiverPanel = ({ layout, state }: { layout: L.PanelLayout; state: PanelState }) => {
  const r = layout.rect;
  const bx = r.x + 24;
  const inner = r.width - 48;
  const b = layout.buttons;
  const { kind } = state;
  const line = (n: number): number => layout.statusY + n * 36;
  const py = layout.pairY;
  return (
    <Layer id="receiver-panel">
      <Layer id="panel-frame" effects={[dropShadow({ y: 18, blur: 54, color: theme.dialog.shadow })]}>
        <Rect x={r.x} y={r.y} width={r.width} height={r.height} radius={24} fill={PANEL_FILL} stroke={{ color: theme.dialog.edge, width: 2 }} />
      </Layer>

      {state.access && layout.warnY !== undefined && (
        <Layer id="panel-warning">
          <T x={bx} y={layout.warnY} w={inner} color={RED}>尚未授權輔助使用，無法輸入文字</T>
          <PBtn rect={b.authorize} label="授權輔助使用" />
          <PBtn target="openSettings" rect={b.openSettings} label="打開輔助使用設定" />
        </Layer>
      )}

      <Ellipse x={bx} y={line(0) + 11} width={14} height={14} fill={LINK_DOT[state.link]} />
      <T x={bx + 26} y={line(0)} w={inner - 26}>{LINK_LABEL[state.link]}</T>
      <T x={bx} y={line(1)} w={inner} size={state.access ? 23 : L.PANEL_TEXT}>{state.access ? '目前欄位：無法讀取（尚未授權輔助使用）' : FOCUS_LINE}</T>
      <T x={bx} y={line(2)} w={inner} color={theme.muted}>{state.link === 'idle' ? '待命' : REMAINING_LINE}</T>
      <PBtn rect={b.start} label="開始接收" />
      <PBtn rect={b.stop} label="停止接收" dim={state.link === 'idle' ? 0.4 : 1} />
      <Rect x={bx} y={layout.dividers[0]} width={inner} height={2} fill={theme.hairline} />

      {(kind === 'access' || kind === 'idle') && (
        <Layer id="pair-idle">
          <T x={bx} y={py} w={inner}>配對：尚未配對</T>
          <PBtn target="pairNew" rect={b.pairNew} label="配對新 iPhone" />
          <PBtn rect={b.unpair} label="解除配對" dim={0.4} />
          {[400, 300, 360].map((w, k) => <Rect key={k} x={bx} y={py + 36 + 12 + 52 + 12 + k * 32 + 6} width={w} height={14} radius={7} fill={theme.skeleton.color} />)}
        </Layer>
      )}
      {kind === 'waiting' && (
        <Layer id="pair-waiting">
          <T x={bx} y={py} w={inner} lineHeight={34 / L.PANEL_TEXT}>{'請在 iPhone 的 Remote Keyboard\n開啟「配對 Mac」'}</T>
          <T x={bx} y={b.cancel.y + mid(b.cancel.height, L.PANEL_TEXT)} color={theme.muted}>{WAIT_LEFT}</T>
          <PBtn target="cancel" rect={b.cancel} label="取消" />
        </Layer>
      )}
      {kind === 'code' && (
        <Layer id="pair-code">
          <T x={bx} y={py} w={inner}>請核對 iPhone 上的配對碼</T>
          <T id="pair-code-text" x={bx} y={py + 36 + 8 - 2} size={56} weight={700} w={inner}>{PAIR_CODE}</T>
          <T x={bx} y={py + 36 + 8 + 64 + 8} w={inner} color={theme.muted}>兩邊相同才按確認</T>
          <PBtn target="macConfirm" rect={b.confirm} label="確認" blue />
          <PBtn rect={b.cancel} label="取消" />
          <T x={bx} y={b.confirm.y + b.confirm.height + 8} w={inner} color={theme.muted}>{CODE_LEFT}</T>
        </Layer>
      )}
      {kind === 'saved' && (
        <Layer id="pair-saved">
          <T x={bx} y={py} w={inner} lineHeight={34 / L.PANEL_TEXT}>{'已儲存。iPhone 也按確認之後，\n再按完成。'}</T>
          <T x={bx} y={b.done.y + mid(b.done.height, L.PANEL_TEXT)} color={theme.muted}>{CODE_LEFT}</T>
          <PBtn target="macDone" rect={b.done} label="完成" />
        </Layer>
      )}
      {kind === 'paired' && (
        <Layer id="pair-paired">
          <T x={bx} y={py} w={inner}>配對：已配對 iPhone</T>
          <T x={bx} y={py + 36} w={inner} color={theme.muted}>配對完成</T>
          <PBtn rect={b.pairNew} label="配對新 iPhone" />
          <PBtn rect={b.unpair} label="解除配對" />
        </Layer>
      )}

      <Rect x={bx} y={layout.dividers[1]} width={inner} height={2} fill={theme.hairline} />
      {['允許觸控板控制', '登入時啟動'].map((label, k) => (
        <Layer key={label}>
          <Checkbox x={bx} y={layout.tailY + k * 44 + 7} />
          <T x={bx + 46} y={layout.tailY + k * 44 + mid(44, L.PANEL_TEXT)} w={inner - 46}>{label}</T>
        </Layer>
      ))}
    </Layer>
  );
};

// ------------------------------------------------------------------ System Settings: the Accessibility list

const W = L.ACCESS_WINDOW;
const PANE_X = W.x + L.ACCESS_SIDEBAR_W + 40;
const PANE_W = W.width - L.ACCESS_SIDEBAR_W - 80;

/** macOS switch: `progress` 0 is off, 1 is on. */
const MacSwitch = ({ rect, progress, id }: { rect: Box; progress: number; id?: string }) => {
  const p = Math.min(1, Math.max(0, progress));
  return (
    <Layer id={id} x={rect.x} y={rect.y}>
      <Rect width={rect.width} height={rect.height} radius={rect.height / 2} fill={p > 0.5 ? theme.blue : '#55565c'} />
      <Ellipse x={4 + (rect.width - rect.height) * p} y={4} width={rect.height - 8} height={rect.height - 8} fill="#ffffff" />
    </Layer>
  );
};

const Sidebar = () => {
  const rowY = (i: number): number => W.y + 160 + i * 56;
  const bars = [120, 150, 100, 140, 0, 130, 110, 150, 120];
  return (
    <Layer id="sidebar">
      <Rect x={W.x + 30} y={W.y + 80} width={220} height={44} radius={22} fill={theme.skeleton.color} />
      {bars.map((w, i) => i === 4 ? (
        <Layer key={i} id="sidebar-selected">
          <Rect x={W.x + 16} y={rowY(i) - 6} width={L.ACCESS_SIDEBAR_W - 32} height={52} radius={14} fill={theme.blue} />
          <Rect x={W.x + 32} y={rowY(i) + 4} width={28} height={28} radius={8} fill="#ffffff55" />
          <T x={W.x + 70} y={rowY(i) + 1} size={26} color="#ffffff">隱私權與安全性</T>
        </Layer>
      ) : (
        <Layer key={i}>
          <Rect x={W.x + 32} y={rowY(i) + 4} width={28} height={28} radius={8} fill={theme.skeleton.color} />
          <Rect x={W.x + 70} y={rowY(i) + 10} width={w} height={theme.skeleton.height} radius={theme.skeleton.radius} fill={theme.skeleton.color} />
        </Layer>
      ))}
    </Layer>
  );
};

/** 隱私權與安全性 > 輔助使用: a list of apps with switches; Remote Keyboard Receiver is the third. `on` (0 to 1) is its switch. */
export const AccessWindow = ({ on }: { on: number }) => {
  const C = L.ACCESS_CARD;
  const widths = [150, 190, 0, 130, 170];
  return (
    <Layer id="screen-macAccess">
      <MacWindow rect={W} title="輔助使用">
        <Rect x={W.x + L.ACCESS_SIDEBAR_W} y={W.y + 58} width={2} height={W.height - 60} fill={theme.hairline} />
        <Sidebar />
        <T x={PANE_X} y={W.y + 84} size={40} weight={700}>輔助使用</T>
        <SkeletonLines x={PANE_X} y={W.y + 152} widths={[PANE_W - 120, PANE_W - 340]} />
        <Rect x={C.x} y={C.y} width={C.width} height={C.height} radius={20} fill="#34363b66" />
        {[0, 1, 2, 3, 4].map((i) => {
          const y = C.y + i * 72;
          const sw = { x: C.x + C.width - 24 - 76, y: y + 13, width: 76, height: 46 };
          return (
            <Layer key={i}>
              {i > 0 && <Rect x={C.x + 24} y={y} width={C.width - 48} height={2} fill={theme.hairline} />}
              {i === 2 ? (
                <Layer>
                  <RkIcon x={C.x + 24} y={y + 14} size={44} />
                  <T x={C.x + 90} y={y + mid(72, 28)} size={28}>Remote Keyboard Receiver.app</T>
                  <Btn target="toggle" rect={sw}>
                    <MacSwitch id="mac-switch" rect={rel(sw)} progress={on} />
                  </Btn>
                </Layer>
              ) : (
                <Layer>
                  <Rect x={C.x + 24} y={y + 14} width={44} height={44} radius={11} fill={theme.skeleton.color} />
                  <Rect x={C.x + 90} y={y + 28} width={widths[i]} height={theme.skeleton.height} radius={theme.skeleton.radius} fill={theme.skeleton.color} />
                  <MacSwitch rect={sw} progress={i === 3 ? 0 : 1} />
                </Layer>
              )}
            </Layer>
          );
        })}
        <Layer id="list-footer">
          <Rect x={C.x} y={C.y + C.height + 12} width={104} height={48} radius={12} fill="#34363b66" />
          <Path d={`M${C.x + 26} ${C.y + C.height + 36} H${C.x + 42} M${C.x + 34} ${C.y + C.height + 28} V${C.y + C.height + 44}`} fill={NONE} stroke={{ color: theme.muted, width: 4, cap: 'round' }} />
          <Path d={`M${C.x + 64} ${C.y + C.height + 36} H${C.x + 80}`} fill={NONE} stroke={{ color: theme.muted, width: 4, cap: 'round' }} />
        </Layer>
      </MacWindow>
    </Layer>
  );
};
