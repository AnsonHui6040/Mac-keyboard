/** iPhone pages of scenes 10 to 14 (logical 390 x 844, iOS dark). Every text size is at least PHONE_MIN_TEXT; the one exception, the shrunk labels of the App Contains Extensions dialog, lives in extensionDialog.tsx. */
import type { ReactNode } from 'react';
import { Ellipse, Layer, Path, Rect } from '@kinetographdev/core';
import { Alert, BackChevron, BoxText, Btn, Card, Chevron, Group, Hair, HomeGrid, LargeTitle, NavBar, PText, Row, Scrim, Skel, StatusBar, Toggle, ios, LINE } from '../components/ios.tsx';
import { DocIcon, CheckDisc, RkIcon } from '../components/appIcons.tsx';
import { GearIcon, GrayIcon, LaptopLine, PhoneLine, SideStoreIcon } from '../components/icons.tsx';
import { theme } from '../theme.ts';
import * as L from './layouts.ts';
import type { Rect as Box } from './geometry.ts';

const NONE = ios.none;
const local = (r: Box): Box => ({ x: 0, y: 0, width: r.width, height: r.height });

/** Gray list rows with an icon tile, used where only the layout matters. */
const grayRows = (lines: number[], tones: string[] = ['#5b5b60']) => (r: Box, i: number): ReactNode => (
  <Row rect={r} icon={tones[i % tones.length]} line={lines[i % lines.length]} />
);
const plainRows = (lines: number[]) => (r: Box, i: number): ReactNode => <Row rect={r} line={lines[i % lines.length]} />;

// ------------------------------------------------------------------ scene 10: AirDrop arrives, save to Files

export const ShareSheetOverlay = ({ opacity }: { opacity: number }) => {
  const S = L.SAVE_SHEET;
  return (
    <Layer id="share-sheet" opacity={opacity}>
      <Scrim opacity={opacity} />
      <Rect x={S.x} y={S.y} width={S.width} height={S.height} radius={34} fill="#2c2c2e" stroke={{ color: '#48484a', width: 1.5 }} />
      <DocIcon x={30} y={314} size={64} tone="#0a84ff" />
      <Skel x={112} y={324} w={190} />
      <Skel x={112} y={360} w={130} />
      {[0, 1, 2, 3].map((i) => (
        <Layer key={i}>
          <GrayIcon x={30 + i * 88} y={424} size={66} tone={['#3a3a3e', '#47474c', '#2f3a4a', '#4a3f3a'][i]} />
          <Skel x={36 + i * 88} y={500} w={54} />
        </Layer>
      ))}
      <Group rect={L.SAVE_ACTIONS} rows={4} render={(r, i) => i === 1 ? (
        <Btn target="save" rect={r}><Row rect={local(r)} label="儲存到「檔案」" chevron={false} /></Btn>
      ) : plainRows([150, 190, 120])(r, i)} />
    </Layer>
  );
};

// ------------------------------------------------------------------ scene 11: My Apps with the plus, the file picker

export const MyAppsPlusPage = ({ vpn = false }: { vpn?: boolean }) => (
  <Layer id="page-myapps-plus">
    <StatusBar vpn={vpn} />
    <Btn target="plus" rect={L.PLUS}>
      <Ellipse width={64} height={64} fill="#2c2c2e" />
      <Path d="M32 17 V47 M17 32 H47" fill={NONE} stroke={{ color: ios.ink, width: 5, cap: 'round' }} />
    </Btn>
    <LargeTitle y={124}>My Apps</LargeTitle>
    <PText x={24} y={198} size={30} weight={700}>Active</PText>
    <Card rect={L.MYAPPS2_CARD} />
    <SideStoreIcon x={28} y={276} size={60} />
    <PText x={98} y={270} size={28} weight={700}>SideStore</PText>
    <Skel x={98} y={324} w={96} />
    <Rect x={L.MYAPPS2_DAYS.x} y={L.MYAPPS2_DAYS.y} width={L.MYAPPS2_DAYS.width} height={L.MYAPPS2_DAYS.height} radius={26} fill="#2f9e4f" />
    <BoxText box={L.MYAPPS2_DAYS} size={26} weight={700}>7 DAYS</BoxText>
    <PText x={0} y={390} size={26} color={ios.muted} w={390} align="center">5 App IDs Remaining</PText>
  </Layer>
);

/**
 * Scene 11, beat 4: My Apps after the dialog's answer. While `progress` (0 to 1) is below 1 a green bar fills where the new card will be;
 * once `installed` is true Remote Keyboard is in the Active list under SideStore, with its own 7 DAYS (the layout of docs/manual/images/iphone-sidestore-myapps.png).
 */
export const MyAppsInstalledPage = ({ progress, installed }: { progress: number; installed: boolean }) => {
  const C = L.MYAPPS3_CARD;
  return (
    <Layer id="page-myapps-installed">
      <StatusBar vpn />
      <Ellipse x={L.PLUS.x} y={L.PLUS.y} width={64} height={64} fill="#2c2c2e" />
      <Path x={L.PLUS.x} y={L.PLUS.y} d="M32 17 V47 M17 32 H47" fill={NONE} stroke={{ color: ios.ink, width: 5, cap: 'round' }} />
      <LargeTitle y={124}>My Apps</LargeTitle>
      <PText x={24} y={198} size={30} weight={700}>Active</PText>
      <Card rect={L.MYAPPS2_CARD} />
      <SideStoreIcon x={28} y={276} size={60} />
      <PText x={98} y={270} size={28} weight={700}>SideStore</PText>
      <Skel x={98} y={324} w={96} />
      <Rect x={L.MYAPPS2_DAYS.x} y={L.MYAPPS2_DAYS.y} width={L.MYAPPS2_DAYS.width} height={L.MYAPPS2_DAYS.height} radius={26} fill="#2f9e4f" />
      <BoxText box={L.MYAPPS2_DAYS} size={26} weight={700}>7 DAYS</BoxText>
      {installed ? (
        <Layer id="installed-card">
          <Card rect={C} />
          <RkIcon x={28} y={C.y + 28} size={60} />
          <Btn target="rkapp" rect={L.MYAPPS3_ICON} />
          <PText x={98} y={C.y + 12} size={26} weight={700} lineHeight={1.12}>{'Remote\nKeyboard'}</PText>
          <Skel x={98} y={C.y + 84} w={96} />
          <Rect x={L.MYAPPS3_DAYS.x} y={L.MYAPPS3_DAYS.y} width={L.MYAPPS3_DAYS.width} height={L.MYAPPS3_DAYS.height} radius={26} fill="#2f9e4f" />
          <BoxText box={L.MYAPPS3_DAYS} size={26} weight={700}>7 DAYS</BoxText>
        </Layer>
      ) : (
        <Layer id="install-progress">
          <Rect x={C.x} y={C.y + 52} width={C.width} height={12} radius={6} fill="#3a3a3e" />
          <Rect x={C.x} y={C.y + 52} width={Math.max(1, C.width * Math.min(1, Math.max(0, progress)))} height={12} radius={6} fill={ios.green} />
        </Layer>
      )}
      <PText x={0} y={installed ? C.y + C.height + 28 : 390} size={26} color={ios.muted} w={390} align="center">5 App IDs Remaining</PText>
    </Layer>
  );
};

const PICKER_ROW_H = 108;

export const PickerPage = ({ vpn = false }: { vpn?: boolean }) => {
  const R = L.PICKER_ROWS;
  return (
    <Layer id="page-picker">
      <StatusBar vpn={vpn} />
      <Rect x={0} y={56} width={390} height={788} radius={38} fill="#141416" />
      <PText x={24} y={80} size={28} color={ios.blue}>取消</PText>
      <PText x={0} y={80} size={30} weight={700} w={390} align="center">下載項目</PText>
      <Card rect={{ x: 16, y: 140, width: 358, height: 64 }} radius={20} />
      <Skel x={44} y={164} w={120} />
      <Card rect={R} />
      {[0, 1, 2, 3, 4].map((i) => {
        const r = { x: R.x, y: R.y + i * PICKER_ROW_H, width: R.width, height: PICKER_ROW_H };
        return (
          <Layer key={i}>
            {i > 0 && <Hair x={r.x + 20} y={r.y} w={r.width - 20} />}
            {i === 1 ? (
              <Btn target="ipa" rect={r}>
                <DocIcon x={8} y={34} size={40} tone="#0a84ff" />
                <PText x={52} y={10} size={26} weight={500} w={240} lineHeight={1.12}>{'RemoteKeyboard-\nv0.1.0-\nunsigned.ipa'}</PText>
              </Btn>
            ) : (
              <Layer x={r.x} y={r.y}>
                <DocIcon x={8} y={34} size={40} tone={['#5b5b60', '#30d158', '#ff9f0a', '#636366'][i % 4]} />
                <Skel x={52} y={34} w={[170, 0, 210, 140, 190][i]} />
                <Skel x={52} y={72} w={90} />
              </Layer>
            )}
          </Layer>
        );
      })}
    </Layer>
  );
};

// ------------------------------------------------------------------ scene 12: add the keyboard

export const GeneralKbPage = () => (
  <Layer id="page-general-kb">
    <StatusBar />
    <NavBar title="一般" />
    <Group rect={L.GEN_CARD1} rows={3} render={grayRows([130, 170, 110])} />
    <Group rect={L.GEN2_CARD} rows={3} render={(r, i) => i === 0 ? (
      <Btn target="kbmenu" rect={r}><Row rect={local(r)} label="鍵盤" /></Btn>
    ) : grayRows([150, 120])(r, i)} />
  </Layer>
);

export const KeyboardMenuPage = () => (
  <Layer id="page-keyboard-menu">
    <StatusBar />
    <NavBar title="鍵盤" />
    <Group rect={L.KBA_CARD} rows={3} render={(r, i) => i === 0 ? (
      <Btn target="kblist" rect={r}>
        <Row rect={local(r)} label="鍵盤" />
        <PText x={r.width - 78} y={(r.height - 26 * LINE) / 2} size={26} color={ios.muted}>3</PText>
      </Btn>
    ) : plainRows([150, 120])(r, i)} />
  </Layer>
);

const EditLabel = () => <PText x={300} y={66} size={28} color={ios.blue}>編輯</PText>;

export const KeyboardListPage = ({ withRk }: { withRk: boolean }) => {
  const card = withRk ? L.KBL_CARD : L.KBB_CARD;
  const rows = withRk ? 4 : 3;
  const footY = card.y + card.height + 16;
  const add = withRk ? L.KBL_ADD : L.KBB_ADD;
  return (
    <Layer id="page-keyboard-list">
      <StatusBar />
      <NavBar title="鍵盤" />
      <EditLabel />
      <Group rect={card} rows={rows} render={(r, i) => withRk && i === 3 ? (
        <Btn target="rkrow" rect={r}><PText x={20} y={(r.height - 26 * LINE) / 2} size={26}>Remote Keyboard</PText><Chevron x={r.width - 36} y={24} /></Btn>
      ) : plainRows([170, 100, 150])(r, i)} />
      <Skel x={36} y={footY} w={300} />
      <Skel x={36} y={footY + 38} w={190} />
      <Card rect={add} />
      {withRk ? (
        <PText x={add.x + 20} y={add.y + (add.height - 28 * LINE) / 2} size={28} color={ios.blue}>新增鍵盤</PText>
      ) : (
        <Btn target="add" rect={add}>
          <PText x={20} y={(add.height - 28 * LINE) / 2} size={28} color={ios.blue}>新增鍵盤</PText>
        </Btn>
      )}
    </Layer>
  );
};

export const AddKeyboardSheet = () => (
  <Layer id="page-add-keyboard">
    <StatusBar />
    <Rect x={0} y={56} width={390} height={788} radius={38} fill="#141416" />
    <Ellipse x={20} y={74} width={56} height={56} fill="#2c2c2e" />
    <Path x={20} y={74} d="M20 20 L36 36 M36 20 L20 36" fill={NONE} stroke={{ color: ios.ink, width: 4, cap: 'round' }} />
    <PText x={0} y={82} size={30} weight={700} w={390} align="center">新增鍵盤</PText>
    <PText x={36} y={164} size={26} color={ios.muted}>建議的鍵盤</PText>
    <Group rect={L.ADD_SUGGESTED} rows={4} render={plainRows([150, 120, 170, 100])} />
    <PText x={36} y={482} size={26} color={ios.muted}>第三方鍵盤</PText>
    <Card rect={L.ADD_THIRD} />
    <Btn target="rk" rect={L.ADD_THIRD}>
      <PText x={20} y={(L.ADD_THIRD.height - 28 * LINE) / 2} size={28}>Remote Keyboard</PText>
    </Btn>
    <Skel x={36} y={620} w={300} />
    <Skel x={36} y={658} w={200} />
  </Layer>
);

// ------------------------------------------------------------------ scene 13: full access

/** The keyboard's page in Settings: one switch. `on` is 0 (off) to 1 (on). */
export const FullAccessPage = ({ on }: { on: number }) => (
  <Layer id="page-full-access">
    <StatusBar />
    <Ellipse x={20} y={62} width={56} height={56} fill="#2c2c2e" />
    <BackChevron x={38} y={76} />
    <Card rect={L.FA_ROW} />
    <Btn target="toggle" rect={L.FA_ROW}>
      <Rect x={18} y={16} width={40} height={40} radius={10} fill="#3a3a3e" />
      <Rect x={25} y={29} width={26} height={14} radius={3} fill="#9a9ba1" />
      <PText x={74} y={(L.FA_ROW.height - 28 * LINE) / 2} size={28}>允許完整取用</PText>
      <Layer x={L.FA_ROW.width - 16 - 62} y={17}>
        <Toggle x={0} y={0} progress={on} />
      </Layer>
    </Btn>
  </Layer>
);

export const FullAccessAlert = ({ opacity }: { opacity: number }) => (
  <Alert layout={L.ALERT_FULL} title="要允許「Remote Keyboard」鍵盤完整取用嗎？" stacked={false} opacity={opacity}
    buttons={[{ label: '不允許' }, { target: 'allow', label: '允許', weight: 700 }]} />
);

// ------------------------------------------------------------------ scene 14: the app

export const HomeRkPage = () => (
  <Layer id="page-home-rk">
    <StatusBar />
    <HomeGrid
      special={(col, row, x, y) => (col === 3 && row === 1 ? (
        <Layer>
          <Btn target="open" rect={L.HOME_RK}>
            <RkIcon x={0} y={0} size={66} />
          </Btn>
          <PText x={x - 32} y={y + 68} size={26} w={130} align="center" lineHeight={1.12}>{'Remote\nKeyboard'}</PText>
        </Layer>
      ) : undefined)}
    />
  </Layer>
);

const GUIDE_TONES = ['#2c3a55', '#2f4a3c', '#4a3a2c', '#3c2f4a'];

/** One of the four guide pages; `index` 0 to 3. The button reads 下一步, and 完成 on the last page. */
export const GuidePage = ({ index }: { index: number }) => (
  <Layer id="page-guide">
    <StatusBar />
    <PText x={304} y={62} size={26} color={ios.muted}>略過</PText>
    <Rect x={45} y={130} width={300} height={300} radius={44} fill={GUIDE_TONES[index]} />
    {index === 0 && <PhoneLine x={125} y={210} size={140} color={ios.ink} />}
    {index === 1 && <LaptopLine x={125} y={210} size={140} color={ios.ink} />}
    {index === 2 && <GearIcon x={125} y={210} size={140} />}
    {index === 3 && (
      <Layer>
        <Ellipse x={95} y={205} width={130} height={130} fill={NONE} stroke={{ color: ios.ink, width: 6 }} />
        <Ellipse x={165} y={225} width={130} height={130} fill={NONE} stroke={{ color: ios.ink, width: 6 }} />
      </Layer>
    )}
    <Skel x={95} y={474} w={200} />
    <Skel x={65} y={524} w={260} />
    <Skel x={85} y={562} w={220} />
    <Skel x={105} y={600} w={180} />
    {[0, 1, 2, 3].map((i) => (
      <Ellipse key={i} x={156 + i * 26} y={676} width={12} height={12} fill={i === index ? ios.ink : '#5b5b60'} />
    ))}
    <Btn target="next" rect={L.GUIDE_NEXT}>
      <Rect width={L.GUIDE_NEXT.width} height={L.GUIDE_NEXT.height} radius={38} fill={ios.blue} />
      <BoxText box={local(L.GUIDE_NEXT)} size={30} weight={700}>{index === 3 ? '完成' : '下一步'}</BoxText>
    </Btn>
  </Layer>
);

export type MainState = 'initial' | 'open' | 'done';

const MAIN_ROWS = ['藍牙', '已配對 Mac', '加入鍵盤並允許完整取用'];

/** The app's home screen with the 設定進度 card. `open`: the 藍牙 row is expanded with 允許藍牙. `done`: 藍牙 is ticked. */
export const MainPage = ({ state }: { state: MainState }) => {
  const open = state === 'open';
  const shift = open ? 84 : 0;
  const card = open ? L.MAIN_CARD_OPEN : L.MAIN_CARD;
  const rowY = (i: number): number => L.MAIN_CARD.y + i * 72 + (i > 0 ? shift : 0);
  return (
    <Layer id="page-main">
      <StatusBar />
      <LargeTitle y={84}>Remote Keyboard</LargeTitle>
      <PText x={36} y={146} size={26} color={ios.muted}>設定進度</PText>
      <Card rect={card} />
      {MAIN_ROWS.map((label, i) => {
        const r = { x: card.x, y: rowY(i), width: card.width, height: 72 };
        const ticked = state === 'done' && i === 0;
        const content = (
          <Layer>
            {ticked ? <CheckDisc x={20} y={18} size={36} /> : <Ellipse x={20} y={18} width={36} height={36} fill={NONE} stroke={{ color: '#636366', width: 3 }} />}
            <PText x={64} y={(72 - 26 * LINE) / 2} size={26} color={ticked ? ios.green : ios.ink}>{label}</PText>
            {ticked && <PText x={r.width - 24 - 78} y={(72 - 26 * LINE) / 2} size={26} color={ios.muted}>已允許</PText>}
          </Layer>
        );
        return (
          <Layer key={label}>
            {i > 0 && <Hair x={r.x + 20} y={r.y} w={r.width - 20} />}
            {i === 0 ? <Btn target="bt" rect={r}>{content}</Btn> : <Layer x={r.x} y={r.y}>{content}</Layer>}
          </Layer>
        );
      })}
      {open && (
        <Btn target="allowbt" rect={L.MAIN_ALLOWBT}>
          <Rect width={L.MAIN_ALLOWBT.width} height={L.MAIN_ALLOWBT.height} radius={30} fill={ios.blue} />
          <BoxText box={local(L.MAIN_ALLOWBT)} size={28} weight={700}>允許藍牙</BoxText>
        </Btn>
      )}
      <PText x={36} y={430 + shift} size={26} color={ios.muted}>設定</PText>
      <Group rect={{ x: 16, y: 472 + shift, width: 358, height: 216 }} rows={3} render={grayRows([150, 120, 180], ['#8e8e93', '#0a84ff', '#30d158'])} />
    </Layer>
  );
};

export const BluetoothAlert = ({ opacity }: { opacity: number }) => (
  <Alert layout={L.ALERT_BT} title="要允許「Remote Keyboard」使用藍牙嗎？" stacked={false} opacity={opacity}
    buttons={[{ label: '不允許' }, { target: 'allow', label: '允許', weight: 700 }]} />
);

export { theme };
