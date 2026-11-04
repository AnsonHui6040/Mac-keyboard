import { Ellipse, Layer, Path, Rect, Text } from '@kinetographdev/core';
import { MacWindow } from '../components/MacWindow.tsx';
import { PhoneScreen, clamp01, fadeIn } from '../components/PhoneScreen.tsx';
import { Alert } from '../components/ios.tsx';
import { IloaderIcon } from '../components/icons.tsx';
import { HomePage, EMAIL } from './phonePages.tsx';
import { deviceBrightness } from '../lib/dim.ts';
import { PHONE_ORIGIN_RIGHT, phoneRect } from './phone.ts';
import * as L from './layouts.ts';
import type { Rect as Box } from './geometry.ts';
import type { ScreenProps } from './registry.tsx';
import { theme } from '../theme.ts';

const PANEL = '#2d2e33';
const PILL = '#3b3c41';
const BLUE = '#2f9bff';
const NONE = '#00000000';

const T = ({ x, y, size, weight = 500, color = theme.ink, w, align, children }: { x: number; y: number; size: number; weight?: 400 | 500 | 700; color?: string; w?: number; align?: 'left' | 'center' | 'right'; children: string }) => (
  <Text font={theme.font} weight={weight} size={size} color={color} x={x} y={y} maxWidth={w} align={align}>{children}</Text>
);
const rel = (r: Box): Box => ({ x: 0, y: 0, width: r.width, height: r.height });
/** Text centered in a rect, for buttons. */
const BtnText = ({ r, size, weight = 700, color = '#ffffff', children }: { r: Box; size: number; weight?: 400 | 500 | 700; color?: string; children: string }) => (
  <T x={0} y={(r.height - size * 1.45) / 2} size={size} weight={weight} color={color} w={r.width} align="center">{children}</T>
);
const Line = ({ x, y, w }: { x: number; y: number; w: number }) => <Rect x={x} y={y} width={w} height={16} radius={8} fill={theme.skeleton.color} />;
const Tap = ({ target, rect, children }: { target: string; rect: Box; children: React.ReactNode }) => (
  <Layer id={`btn-${target}`} x={rect.x} y={rect.y}>
    <Rect width={rect.width} height={rect.height} fill={NONE} />
    {children}
  </Layer>
);

/** The cable from the Mac window to the iPhone: it grows from the window's edge to the plug. */
const Cable = ({ progress }: { progress: number }) => {
  const w = 60 * progress;
  return (
    <Layer id="usb-cable">
      {w > 0 && <Rect x={1380} y={440} width={w} height={8} radius={4} fill="#9a9ba1" />}
      {progress >= 1 && <Rect x={1440} y={428} width={46} height={32} radius={8} fill="#6b6c72" />}
    </Layer>
  );
};

const Card = ({ r }: { r: Box }) => <Rect x={r.x} y={r.y} width={r.width} height={r.height} radius={26} fill={PANEL} stroke={{ color: '#3f4046', width: 2 }} />;

const Window = ({ loggedIn, deviceListed, toast, installing }: { loggedIn: boolean; deviceListed: boolean; toast: number; installing: number }) => {
  const W = L.ILOADER_WINDOW;
  const left = L.ILO_LEFT;
  const right = L.ILO_RIGHT;
  const dev = L.ILO_DEVICE;
  const add = L.ILO_ADD;
  const stable = L.ILO_STABLE;
  const ins = L.ILO_INSTALLERS;
  return (
    <MacWindow rect={W} title="iloader">
      <IloaderIcon x={296} y={130} size={64} />
      <T x={380} y={126} size={40} weight={700}>iloader</T>
      <Line x={380} y={182} w={200} />
      <Rect x={1030} y={136} width={150} height={52} radius={26} fill={PILL} />
      <Rect x={1196} y={136} width={148} height={52} radius={26} fill={PILL} />

      <Card r={left} />
      <T x={left.x + 28} y={left.y + 22} size={38} weight={700}>Apple ID</T>
      <T x={left.x + 28} y={left.y + 76} size={28} color={theme.muted}>Saved Logins</T>
      {loggedIn ? (
        <Layer id="saved-login">
          <Rect x={left.x + 28} y={left.y + 122} width={444} height={106} radius={18} fill="#25262a" stroke={{ color: '#3f4046', width: 2 }} />
          <T x={left.x + 46} y={left.y + 132} size={28}>{EMAIL}</T>
          <Rect x={left.x + 46} y={left.y + 172} width={190} height={46} radius={12} fill="#0a84ff" />
          <T x={left.x + 46} y={left.y + 172 + (46 - 26 * 1.45) / 2} size={26} weight={700} w={190} align="center">Sign in</T>
          <Rect x={left.x + 262} y={left.y + 172} width={190} height={46} radius={12} fill="#4a2a2a" stroke={{ color: '#b5453f', width: 2 }} />
          <T x={left.x + 262} y={left.y + 172 + (46 - 26 * 1.45) / 2} size={26} weight={700} color="#ff6b62" w={190} align="center">Delete</T>
        </Layer>
      ) : (
        <Rect x={left.x + 28} y={left.y + 122} width={444} height={106} radius={18} fill="#25262a" stroke={{ color: '#3f4046', width: 2 }} />
      )}
      <Rect x={add.x} y={add.y} width={add.width} height={add.height} radius={36} fill={NONE} stroke={{ color: '#4a4b50', width: 2 }} />
      <Tap target="add" rect={add}>
        <Rect width={add.width} height={add.height} radius={36} fill="#35363b" />
        <BtnText r={add} size={30} color={BLUE}>Add Account +</BtnText>
      </Tap>

      <Card r={right} />
      <T x={right.x + 28} y={right.y + 22} size={38} weight={700}>iDevice</T>
      {deviceListed && <Rect x={dev.x} y={dev.y} width={dev.width} height={dev.height} radius={18} fill={NONE} stroke={{ color: '#2f6fd0', width: 3 }} />}
      {deviceListed ? (
        <Tap target="device" rect={dev}>
          <Rect width={dev.width} height={dev.height} radius={18} fill="#1f3150" />
          <T x={26} y={(dev.height - 30 * 1.45) / 2} size={30} weight={700}>我的 iPhone</T>
          <Rect x={dev.width - 26 - 140} y={20} width={140} height={44} radius={22} fill="#3b3c41" />
          <T x={dev.width - 26 - 140} y={20 + (44 - 24 * 1.45) / 2} size={24} weight={700} w={140} align="center">Selected</T>
        </Tap>
      ) : (
        <Rect x={dev.x} y={dev.y} width={dev.width} height={dev.height} radius={18} fill="#25262a" stroke={{ color: '#3f4046', width: 2 }} />
      )}
      <Rect x={L.ILO_REFRESH.x} y={L.ILO_REFRESH.y} width={L.ILO_REFRESH.width} height={L.ILO_REFRESH.height} radius={18} fill={NONE} stroke={{ color: '#4a4b50', width: 2 }} />
      <T x={L.ILO_REFRESH.x} y={L.ILO_REFRESH.y + (64 - 28 * 1.45) / 2} size={28} weight={700} w={L.ILO_REFRESH.width} align="center">Refresh</T>

      <Card r={ins} />
      <T x={ins.x + 28} y={ins.y + 22} size={34} weight={700}>Installers</T>
      <Tap target="stable" rect={stable}>
        <Rect width={stable.width} height={stable.height} radius={20} fill="#0a84ff" />
        <BtnText r={stable} size={30}>Stable SideStore</BtnText>
      </Tap>
      <Rect x={770} y={stable.y} width={270} height={72} radius={20} fill={PILL} />
      <Rect x={1064} y={stable.y} width={252} height={72} radius={20} fill={PILL} />
      <Rect x={324} y={756} width={992} height={14} radius={7} fill="#3b3c41" />
      {installing > 0 && <Rect x={324} y={756} width={992 * installing} height={14} radius={7} fill="#2fd36d" />}

      {toast > 0 && (
        <Layer id="toast" opacity={toast}>
          <Rect x={1040} y={738} width={296} height={64} radius={14} fill="#e8f8ee" />
          <Ellipse x={1060} y={758} width={24} height={24} fill="#1a8f45" />
          <Path d="M1066 770 L1071 775 L1079 765" fill={NONE} stroke={{ color: '#ffffff', width: 3, cap: 'round', join: 'round' }} />
          <T x={1100} y={738 + (64 - 26 * 1.45) / 2} size={26} weight={700} color="#146c36">Found device</T>
        </Layer>
      )}
    </MacWindow>
  );
};

/**
 * Scene 5: the iloader window on the left and the iPhone on the right, one of them dimmed.
 * Beat 0: cable connects. Beat 1: 信任這部電腦？ on the iPhone. Beat 2: the account is added, the iPhone is listed. Beat 3: install Stable SideStore.
 */
export const Iloader = ({ active, prevActive, beatIndex, beatFrame, stepTimes }: ScreenProps) => {
  const dim = (d: 'mac' | 'iphone') => deviceBrightness(d, { active, prevActive, beatFrame });
  const cable = beatIndex > 0 ? 1 : clamp01((beatFrame - 20) / 30);
  const addLand = stepTimes[0]?.land ?? Infinity;
  const loggedIn = beatIndex === 2 ? beatFrame >= addLand : beatIndex > 2;
  const deviceListed = beatIndex >= 2;
  const toast = beatIndex === 2 ? fadeIn(beatFrame, 0, 8) * (1 - fadeIn(beatFrame, 70, 10)) : 0;
  const installing = beatIndex === 3 ? clamp01((beatFrame - (stepTimes[0]?.land ?? Infinity)) / 50) : 0;
  const trust = L.ALERT_TRUST;
  return (
    <Layer id="screen-iloader">
      <Layer id="mac-device" opacity={dim('mac')}>
        <Window loggedIn={loggedIn} deviceListed={deviceListed} toast={toast} installing={installing} />
      </Layer>
      <Cable progress={cable} />
      <PhoneScreen origin={PHONE_ORIGIN_RIGHT} brightness={dim('iphone')}>
        <HomePage />
        {beatIndex === 1 && (
          <Alert layout={trust} title="信任這部電腦？" stacked opacity={fadeIn(beatFrame, 0, 8)}
            buttons={[{ target: 'trust', label: '信任', weight: 700 }, { label: '不信任' }]} />
        )}
      </PhoneScreen>
    </Layer>
  );
};

export { phoneRect };
