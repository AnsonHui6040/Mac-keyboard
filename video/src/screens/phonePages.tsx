/** Full iPhone pages (logical 390 x 844, iOS dark) shared by scenes 4 to 9. A page draws its own status bar and its tappable `btn-<target>` layers. */
import type { ReactNode } from 'react';
import { Ellipse, Layer, Path, Rect } from '@kinetographdev/core';
import { Alert, BoxText, Btn, Card, Chevron, Group, HomeGrid, LargeTitle, NavBar, PText, Row, Skel, StatusBar, Toggle, ios, LINE } from '../components/ios.tsx';
import { GearIcon, GrayIcon, SideStoreIcon, VpnIcon } from '../components/icons.tsx';
import { theme } from '../theme.ts';
import * as L from './layouts.ts';
import type { Rect as Box } from './geometry.ts';

const local = (r: Box): Box => ({ x: 0, y: 0, width: r.width, height: r.height });
const NONE = ios.none;
export const EMAIL = 'your.name@example.com';

/** Gray list rows with an icon tile, used where only the layout matters. */
const lineRows = (lines: number[], tones: string[] = ['#5b5b60']) => (r: Box, i: number): ReactNode => (
  <Row rect={r} icon={tones[i % tones.length]} line={lines[i % lines.length]} />
);

// ------------------------------------------------------------------ home

export const HomePage = ({ named }: { named?: 'settings' | 'sidestore' | 'both' }) => (
  <Layer id="page-home">
    <StatusBar />
    <HomeGrid
      special={(col, row, x, y) => {
        if (col === 2 && row === 0 && named !== undefined) {
          return (
            <Layer>
              <Btn target="settings" rect={L.HOME_SETTINGS}>
                <GearIcon x={0} y={0} size={66} />
              </Btn>
              <PText x={x - 20} y={y + 70} size={26} w={106} align="center">設定</PText>
            </Layer>
          );
        }
        if (col === 1 && row === 1 && (named === 'sidestore' || named === 'both')) {
          return (
            <Layer>
              <Btn target="sidestore" rect={L.HOME_SIDESTORE}>
                <SideStoreIcon x={0} y={0} size={66} />
              </Btn>
              <PText x={x - 32} y={y + 70} size={26} w={130} align="center">SideStore</PText>
            </Layer>
          );
        }
        return undefined;
      }}
    />
  </Layer>
);

// ------------------------------------------------------------------ LocalDevVPN

const ShieldDisc = ({ x, y, on }: { x: number; y: number; on: boolean }) => (
  <Layer id="shield" x={x} y={y}>
    <Ellipse width={96} height={96} fill={on ? '#16301f' : '#2a2a2e'} stroke={{ color: on ? '#2d6b43' : '#3a3a3e', width: 6 }} />
    <Path d="M48 22 L68 30 V48 C68 62 59 71 48 76 C37 71 28 62 28 48 V30 Z" fill={on ? '#1f5a35' : '#3a3a3e'} stroke={{ color: on ? ios.green : ios.muted, width: 4, join: 'round' }} />
    {on && <Path d="M38 48 L45 55 L58 40" fill={NONE} stroke={{ color: '#7ae6a0', width: 5, cap: 'round', join: 'round' }} />}
  </Layer>
);

export const VpnPage = ({ connected }: { connected: boolean }) => (
  <Layer id="page-vpn">
    <StatusBar />
    <LargeTitle y={60}>LocalDevVPN</LargeTitle>
    <Card rect={L.VPN_CARD_STATUS} />
    <PText x={36} y={146} size={28} weight={700}>現狀</PText>
    <ShieldDisc x={36} y={188} on={connected} />
    <Btn target="status" rect={L.VPN_STATUS}>
      <BoxText box={local(L.VPN_STATUS)} size={38} weight={700} align="left" padX={20}>{connected ? '已連線' : '未連線'}</BoxText>
    </Btn>
    <Rect x={36} y={296} width={318} height={1.5} fill={ios.sep} />
    <Card rect={L.VPN_CARD_CONNECT} />
    <PText x={36} y={360} size={28} weight={700}>連線</PText>
    <Btn target="connect" rect={L.VPN_CONNECT}>
      <Rect width={L.VPN_CONNECT.width} height={L.VPN_CONNECT.height} radius={38} fill={connected ? '#d6403a' : '#2f9e4f'} />
      <BoxText box={local(L.VPN_CONNECT)} size={30} weight={700}>{connected ? '斷線' : '連線'}</BoxText>
    </Btn>
    <Card rect={L.VPN_CARD_INFO} />
    <Skel x={36} y={560} w={200} />
    <Skel x={36} y={610} w={260} />
    <Skel x={36} y={660} w={160} />
  </Layer>
);

export const AppStorePage = () => (
  <Layer id="page-appstore">
    <StatusBar />
    <VpnIcon x={L.APPSTORE_ICON.x} y={L.APPSTORE_ICON.y} size={L.APPSTORE_ICON.width} />
    <PText x={156} y={98} size={30} weight={700} w={230}>LocalDevVPN</PText>
    <Skel x={156} y={150} w={120} />
    <Btn target="get" rect={L.APPSTORE_GET}>
      <Rect width={L.APPSTORE_GET.width} height={L.APPSTORE_GET.height} radius={30} fill="#2c2c2e" />
      <BoxText box={local(L.APPSTORE_GET)} size={28} weight={700} color={ios.blue} padRight={36}>取得</BoxText>
    </Btn>
    <Rect x={30} y={290} width={160} height={380} radius={22} fill={ios.card} />
    <Rect x={204} y={290} width={160} height={380} radius={22} fill={ios.card} />
    <Skel x={30} y={700} w={320} />
    <Skel x={30} y={740} w={260} />
  </Layer>
);

/** The "add VPN configuration" alert; fades in with `opacity`. */
export const VpnAllowAlert = ({ opacity }: { opacity: number }) => (
  <Alert layout={L.ALERT_VPN} title="「LocalDevVPN」想要加入VPN設定" stacked={false} opacity={opacity}
    buttons={[{ label: '不允許' }, { target: 'allow', label: '允許', weight: 700 }]} />
);

// ------------------------------------------------------------------ Settings

export const SettingsPage = () => (
  <Layer id="page-settings">
    <StatusBar />
    <LargeTitle>設定</LargeTitle>
    <Group rect={L.SET_CARD1} rows={2} render={lineRows([150, 110], ['#0a84ff', '#ff9f0a'])} />
    <Group rect={L.SET_CARD2} rows={4} render={(r, i) => i === 2 ? (
      <Btn target="general" rect={r}><Row rect={local(r)} icon="#8e8e93" label="一般" /></Btn>
    ) : lineRows([130, 170, 100, 140], ['#636366', '#30d158', '#8e8e93', '#5e5ce6'])(r, i)} />
    <Group rect={L.SET_CARD3} rows={2} render={(r, i) => i === 0 ? (
      <Btn target="privacy" rect={r}><Row rect={local(r)} icon="#0a84ff" label="隱私權與安全性" /></Btn>
    ) : lineRows([120], ['#8e8e93'])(r, i)} />
  </Layer>
);

export const GeneralPage = () => (
  <Layer id="page-general">
    <StatusBar />
    <NavBar title="一般" />
    <Group rect={L.GEN_CARD1} rows={3} render={lineRows([130, 170, 110])} />
    <Group rect={L.GEN_CARD2} rows={3} render={(r, i) => i === 2 ? (
      <Btn target="vpnmgmt" rect={r}><Row rect={local(r)} label="VPN與裝置管理" /></Btn>
    ) : lineRows([150, 120])(r, i)} />
  </Layer>
);

export const VpnMgmtPage = () => (
  <Layer id="page-vpnmgmt">
    <StatusBar />
    <NavBar title="VPN與裝置管理" />
    <Group rect={{ x: 16, y: 150, width: 358, height: 72 }} rows={1} render={lineRows([120], ['#0a84ff'])} />
    <PText x={36} y={248} size={26} color={ios.muted}>開發者App</PText>
    <Group rect={L.VPNMGMT_CARD} rows={1} render={(r) => (
      <Btn target="row" rect={r}>
        <PText x={20} y={(r.height - 26 * LINE) / 2} size={26} w={330}>{EMAIL}</PText>
      </Btn>
    )} />
  </Layer>
);

export const DevPage = () => (
  <Layer id="page-dev">
    <StatusBar />
    <NavBar title="" />
    <Card rect={L.DEVPAGE_TRUST} />
    <Btn target="trust" rect={L.DEVPAGE_TRUST}>
      <PText x={20} y={14} size={28} weight={700} color={ios.blue} w={318} lineHeight={1.3}>{'信任「your.name\n@example.com」'}</PText>
    </Btn>
    <Group rect={{ x: 16, y: 290, width: 358, height: 144 }} rows={2} render={lineRows([180, 140], ['#6d3fe8', '#30d158'])} />
  </Layer>
);

export const RestartAlert = ({ opacity }: { opacity: number }) => (
  <Alert layout={L.ALERT_RESTART} title="要允許來自此開發者的App嗎？" stacked opacity={opacity}
    buttons={[{ target: 'allow', label: '允許並重新啟動', weight: 700 }, { label: '不允許' }]} />
);

/** Passcode entry. `dots` is how many of the six dots are filled. */
export const PasscodePage = ({ dots }: { dots: number }) => {
  const keys = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '', '0', ''];
  return (
    <Layer id="page-passcode">
      <StatusBar />
      <PText x={0} y={100} size={34} weight={700} w={390} align="center">輸入密碼</PText>
      {Array.from({ length: 6 }, (_, i) => (
        <Ellipse key={i} x={95 + i * 36} y={178} width={20} height={20} fill={i < dots ? ios.ink : NONE} stroke={{ color: ios.ink, width: 2.5 }} />
      ))}
      <Btn target="keypad" rect={L.KEYPAD}>
        {keys.map((k, i) =>
          k === '' ? null : (
            <Layer key={k}>
              <Ellipse x={(i % 3) * 106} y={Math.floor(i / 3) * 125} width={88} height={88} fill="#2c2c2e" />
              <PText x={(i % 3) * 106} y={Math.floor(i / 3) * 125 + (88 - 40 * LINE) / 2} size={40} weight={500} w={88} align="center">{k}</PText>
            </Layer>
          ),
        )}
      </Btn>
    </Layer>
  );
};

export const PrivacyPage = ({ toggle }: { toggle: number }) => (
  <Layer id="page-privacy">
    <StatusBar />
    <NavBar title="隱私權與安全性" />
    <Group rect={{ x: 16, y: 150, width: 358, height: 288 }} rows={4} render={lineRows([170, 130, 190, 110], ['#0a84ff', '#30d158', '#ff9f0a', '#636366'])} />
    <Group rect={{ x: 16, y: 458, width: 358, height: 216 }} rows={3} render={lineRows([150, 120, 180], ['#8e8e93'])} />
    <Card rect={L.PRIVACY_DEVMODE} />
    <Btn target="devmode" rect={L.PRIVACY_DEVMODE}>
      <PText x={20} y={(L.PRIVACY_DEVMODE.height - 28 * LINE) / 2} size={28} weight={500}>開發者模式</PText>
      <Layer x={L.PRIVACY_DEVMODE.width - 16 - 62} y={17}>
        <Toggle x={0} y={0} progress={toggle} />
      </Layer>
    </Btn>
  </Layer>
);

export const DevModeAlert = ({ opacity }: { opacity: number }) => (
  <Alert layout={L.ALERT_DEVMODE} title="開發者模式" stacked={false} opacity={opacity}
    buttons={[{ label: '取消' }, { target: 'on', label: '開啟', weight: 700 }]} />
);

// ------------------------------------------------------------------ SideStore

export const SignInPage = () => (
  <Layer id="page-signin">
    <StatusBar />
    <SideStoreIcon x={L.SIGNIN_ICON.x} y={L.SIGNIN_ICON.y} size={L.SIGNIN_ICON.width} />
    <PText x={0} y={206} size={40} weight={700} w={390} align="center">Sign In</PText>
    <PText x={36} y={290} size={26} color={ios.muted}>Apple ID</PText>
    <Card rect={L.SIGNIN_FIELD1} radius={18} />
    <PText x={36} y={L.SIGNIN_FIELD1.y + (72 - 26 * LINE) / 2} size={26} w={334}>{EMAIL}</PText>
    <PText x={36} y={420} size={26} color={ios.muted}>Password</PText>
    <Card rect={L.SIGNIN_FIELD2} radius={18} />
    {Array.from({ length: 9 }, (_, i) => (
      <Ellipse key={i} x={38 + i * 24} y={L.SIGNIN_FIELD2.y + 30} width={13} height={13} fill={ios.ink} />
    ))}
    <Btn target="signin" rect={L.SIGNIN_BUTTON}>
      <Rect width={L.SIGNIN_BUTTON.width} height={L.SIGNIN_BUTTON.height} radius={40} fill={ios.blue} />
      <BoxText box={local(L.SIGNIN_BUTTON)} size={30} weight={700}>Sign In</BoxText>
    </Btn>
  </Layer>
);

const TAB_LABELS = ['News', 'Sources', 'Browse', 'My Apps', 'Settings'];

/** SideStore's bottom tab bar. The selected tab is a wide pill with its label; the others are plain glyphs. `tapTarget` wraps one tab in a `btn-` layer. */
export const TabBar = ({ selected, tapTarget }: { selected: number; tapTarget?: { index: number; target: string } }) => {
  const rects = L.tabLayout(selected);
  return (
    <Layer id="tab-bar">
      <Rect x={L.TAB_BAR.x} y={L.TAB_BAR.y} width={L.TAB_BAR.width} height={L.TAB_BAR.height} radius={38} fill="#1c1c1e" stroke={{ color: '#2c2c2e', width: 2 }} />
      {rects.map((r, i) => {
        const isSel = i === selected;
        const inner = isSel ? (
          <Layer>
            <Rect width={r.width} height={r.height} radius={r.height / 2} fill="#3a3a3e" />
            <BoxText box={local(r)} size={26} weight={700}>{TAB_LABELS[i]}</BoxText>
          </Layer>
        ) : (
          <Layer x={(r.width - 30) / 2} y={(r.height - 30) / 2}>
            {i === 4 ? <Ellipse width={30} height={30} fill={NONE} stroke={{ color: ios.muted, width: 3 }} /> : <Rect width={30} height={30} radius={8} fill={NONE} stroke={{ color: ios.muted, width: 3 }} />}
            {i === 1 && <Path d="M7 15 H23 M17 9 L23 15 L17 21" fill={NONE} stroke={{ color: ios.muted, width: 3, cap: 'round', join: 'round' }} />}
          </Layer>
        );
        return tapTarget && tapTarget.index === i ? (
          <Btn key={i} target={tapTarget.target} rect={r}>{inner}</Btn>
        ) : (
          <Layer key={i} x={r.x} y={r.y}>{inner}</Layer>
        );
      })}
    </Layer>
  );
};

export const NewsPage = () => (
  <Layer id="page-news">
    <StatusBar />
    <LargeTitle>News</LargeTitle>
    <Card rect={{ x: 16, y: 140, width: 358, height: 270 }} />
    <Rect x={32} y={156} width={326} height={140} radius={16} fill="#3a3a3e" />
    <Skel x={32} y={320} w={240} />
    <Skel x={32} y={356} w={170} />
    <Card rect={{ x: 16, y: 430, width: 358, height: 270 }} />
    <Rect x={32} y={446} width={326} height={140} radius={16} fill="#3a3a3e" />
    <Skel x={32} y={610} w={260} />
    <Skel x={32} y={646} w={150} />
  </Layer>
);

export const MyAppsPage = () => (
  <Layer id="page-myapps">
    <StatusBar />
    <LargeTitle>My Apps</LargeTitle>
    <PText x={24} y={146} size={30} weight={700}>Active</PText>
    <Card rect={L.MYAPPS_CARD} />
    <SideStoreIcon x={28} y={224} size={60} />
    <PText x={98} y={218} size={28} weight={700}>SideStore</PText>
    <Skel x={98} y={272} w={96} />
    <Btn target="days" rect={L.MYAPPS_DAYS}>
      <Rect width={L.MYAPPS_DAYS.width} height={L.MYAPPS_DAYS.height} radius={26} fill="#2f9e4f" />
      <BoxText box={local(L.MYAPPS_DAYS)} size={26} weight={700}>7 DAYS</BoxText>
    </Btn>
    <PText x={0} y={338} size={26} color={ios.muted} w={390} align="center">5 App IDs Remaining</PText>
  </Layer>
);

export const RefreshAlert = ({ opacity }: { opacity: number }) => (
  <Alert layout={L.ALERT_REFRESH} stacked opacity={opacity} titleSkel
    buttons={[{ label: 'Yes' }, { target: 'refresh', label: 'Refresh Now', weight: 700 }]} />
);

export const ErrorAlert = ({ opacity }: { opacity: number }) => {
  const layout = L.ALERT_ERROR;
  const message = 'This action cannot be completed at this time. (-80045)';
  const codeAt = message.indexOf('(-80045)');
  return (
    <Alert layout={layout} stacked body={false} opacity={opacity}
      message={{ text: message, color: ios.ink, from: codeAt, codeColor: ios.red }}
      buttons={[{ label: 'OK', weight: 700 }]} />
  );
};

export { theme, GrayIcon };
