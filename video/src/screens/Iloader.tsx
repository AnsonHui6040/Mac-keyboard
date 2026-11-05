import { Ellipse, Layer, Path, Rect, Text } from '@kinetographdev/core';
import { MacWindow } from '../components/MacWindow.tsx';
import { PhoneScreen, clamp01, fadeIn } from '../components/PhoneScreen.tsx';
import { Alert } from '../components/ios.tsx';
import { IloaderIcon } from '../components/icons.tsx';
import { SIGNIN_CODE } from '../data/artifacts.ts';
import { HomePage, EMAIL } from './phonePages.tsx';
import { SideStoreSite } from './macPages.tsx';
import { CODE_LENGTH, typedDigits } from './signinCode.ts';
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

/** Sign-in sheet: the fictional account, a masked password, and the Sign in button. */
const SignInSheet = ({ opacity }: { opacity: number }) => {
  const s = L.ILO_SHEET;
  const f1 = L.ILO_SHEET_FIELD1;
  const f2 = L.ILO_SHEET_FIELD2;
  const b = L.ILO_SIGNIN;
  const W = L.ILOADER_WINDOW;
  return (
    <Layer id="signin-sheet" opacity={opacity}>
      <Rect x={W.x + 2} y={W.y + 58} width={W.width - 4} height={W.height - 60} radius={24} fill="#000000" opacity={0.5} />
      <Rect x={s.x} y={s.y} width={s.width} height={s.height} radius={26} fill="#2b2c31" stroke={{ color: '#4a4b50', width: 2 }} />
      <T x={s.x + 32} y={s.y + 28} size={36} weight={700}>Apple ID</T>
      <T x={f1.x} y={f1.y - 40} size={24} color={theme.muted}>Email</T>
      <Rect x={f1.x} y={f1.y} width={f1.width} height={f1.height} radius={14} fill="#1f2024" stroke={{ color: '#4a4b50', width: 2 }} />
      <T x={f1.x + 20} y={f1.y + (f1.height - 28 * 1.45) / 2} size={28}>{EMAIL}</T>
      <T x={f2.x} y={f2.y - 40} size={24} color={theme.muted}>Password</T>
      <Rect x={f2.x} y={f2.y} width={f2.width} height={f2.height} radius={14} fill="#1f2024" stroke={{ color: '#4a4b50', width: 2 }} />
      {Array.from({ length: 9 }, (_, i) => (
        <Ellipse key={i} x={f2.x + 22 + i * 28} y={f2.y + 24} width={16} height={16} fill={theme.ink} />
      ))}
      <Tap target="signin" rect={b}>
        <Rect width={b.width} height={b.height} radius={20} fill="#0a84ff" />
        <BtnText r={b} size={30}>Sign in</BtnText>
      </Tap>
    </Layer>
  );
};

/** Verification code sheet: the six-digit field fills one digit at a time (`digits` of them are typed), the rest show as dashes. */
const CodeSheet = ({ opacity, digits }: { opacity: number; digits: number }) => {
  const s = L.ILO_SHEET;
  const f = L.ILO_CODE;
  const W = L.ILOADER_WINDOW;
  return (
    <Layer id="code-sheet" opacity={opacity}>
      <Rect x={W.x + 2} y={W.y + 58} width={W.width - 4} height={W.height - 60} radius={24} fill="#000000" opacity={0.5} />
      <Rect x={s.x} y={s.y} width={s.width} height={s.height} radius={26} fill="#2b2c31" stroke={{ color: '#4a4b50', width: 2 }} />
      <T x={s.x + 32} y={s.y + 28} size={36} weight={700}>Verification Code</T>
      <Line x={s.x + 32} y={s.y + 108} w={480} />
      <Line x={s.x + 32} y={s.y + 146} w={360} />
      <Tap target="code" rect={f}>
        <Rect x={1.5} y={1.5} width={f.width - 3} height={f.height - 3} radius={16} fill="#1f2024" stroke={{ color: BLUE, width: 3 }} />
        {Array.from({ length: CODE_LENGTH }, (_, i) => i < digits ? (
          <T key={i} x={30 + i * 52} y={(f.height - 48 * 1.45) / 2} size={48} weight={700}>{SIGNIN_CODE[i]}</T>
        ) : (
          <Rect key={i} x={32 + i * 52} y={f.height / 2 + 4} width={26} height={5} radius={2.5} fill="#5b5c62" />
        ))}
      </Tap>
      <Line x={s.x + 32} y={f.y + f.height + 44} w={150} />
    </Layer>
  );
};

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

const Window = ({ loggedIn, deviceListed, toast, installing, signinSheet, codeSheet, digits }: { loggedIn: boolean; deviceListed: boolean; toast: number; installing: number; signinSheet: number; codeSheet: number; digits: number }) => {
  const W = L.ILOADER_WINDOW;
  const left = L.ILO_LEFT;
  const right = L.ILO_RIGHT;
  const dev = L.ILO_DEVICE;
  const add = L.ILO_ADD;
  const stable = L.ILO_STABLE;
  const ins = L.ILO_INSTALLERS;
  return (
    <MacWindow rect={W} title="iloader">
      <Tap target="open" rect={L.ILO_OPEN}>
        <IloaderIcon x={0} y={18} size={64} />
        <T x={84} y={14} size={40} weight={700}>iloader</T>
      </Tap>
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

      {signinSheet > 0 && <SignInSheet opacity={signinSheet} />}
      {codeSheet > 0 && <CodeSheet opacity={codeSheet} digits={digits} />}

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
 * Beat 0, two steps: sidestore.io with the iloader download button (pressed), then the iloader window (the pointer goes to its header).
 * Beat 1: the cable, then 信任這部電腦？ on the iPhone. Beat 2: Add Account + opens the sign-in sheet and Sign in is pressed; the next beat opens the verification code sheet.
 * Beat 3: the six digits of the fictional code are typed. Beat 4: the sheet closes, the account and the iPhone are listed, Stable SideStore is installed.
 */
export const Iloader = ({ active, prevActive, beatIndex, beatFrame, stepTimes }: ScreenProps) => {
  const dim = (d: 'mac' | 'iphone') => deviceBrightness(d, { active, prevActive, beatFrame });
  const land = (k: number): number => stepTimes[k]?.land ?? Infinity;
  const openStart = stepTimes[1]?.start ?? Infinity;
  const siteOpacity = beatIndex === 0 && beatFrame < openStart ? 1 - fadeIn(beatFrame, openStart - 4, 4) : 0;
  const windowOpacity = beatIndex === 0 ? fadeIn(beatFrame, openStart, 5) : 1;
  const cable = beatIndex === 0 ? 0 : beatIndex === 1 ? clamp01((beatFrame - 2) / 14) : 1;
  const loggedIn = beatIndex >= 4;
  // The sign-in sheet stays through beat 2 (its Sign in button is the last press); at the start of beat 3 the code sheet takes its place (a cut, so the two never overlap).
  const signinSheet = beatIndex === 2 ? fadeIn(beatFrame, land(0), 6) : 0;
  const codeSheet = beatIndex === 3 ? 1 : beatIndex === 4 ? 1 - fadeIn(beatFrame, 0, 6) : 0;
  const typed = beatIndex >= 4 ? CODE_LENGTH : beatIndex === 3 ? typedDigits(beatFrame - land(0)) : 0;
  const toast = beatIndex === 4 ? fadeIn(beatFrame, 6, 8) * (1 - fadeIn(beatFrame, 70, 10)) : 0;
  const installing = beatIndex === 4 ? clamp01((beatFrame - land(1)) / 50) : 0;
  const trust = L.ALERT_TRUST;
  return (
    <Layer id="screen-iloader">
      <Layer id="mac-device" opacity={dim('mac')}>
        {siteOpacity > 0 && (
          <Layer id="site-fade" opacity={siteOpacity}>
            <SideStoreSite hover={fadeIn(beatFrame, land(0) - 4, 6)} downloaded={fadeIn(beatFrame, land(0) + 4, 8)} />
          </Layer>
        )}
        {windowOpacity > 0 && (
          <Layer id="window-fade" opacity={windowOpacity}>
            <Window loggedIn={loggedIn} deviceListed={loggedIn} toast={toast} installing={installing} signinSheet={signinSheet} codeSheet={codeSheet} digits={typed} />
          </Layer>
        )}
      </Layer>
      <Cable progress={cable} />
      <PhoneScreen origin={PHONE_ORIGIN_RIGHT} brightness={dim('iphone')}>
        <HomePage />
        {beatIndex === 1 && (
          <Alert layout={trust} title="信任這部電腦？" stacked opacity={fadeIn(beatFrame, 14, 8)}
            buttons={[{ target: 'trust', label: '信任', weight: 700 }, { label: '不信任' }]} />
        )}
      </PhoneScreen>
    </Layer>
  );
};

export { phoneRect };
