/** iPhone pages of scenes 18 to 20 (logical 390 x 844, iOS dark): the app's setup list, the pairing pages, an input field and the keyboard list. Every text size is at least PHONE_MIN_TEXT. */
import type { ReactNode } from 'react';
import { Ellipse, Layer, Path, Rect } from '@kinetographdev/core';
import { BackChevron, BoxText, Btn, Card, Chevron, Group, Hair, LargeTitle, PText, Row, Skel, StatusBar, ios, LINE } from '../components/ios.tsx';
import { CheckDisc } from '../components/appIcons.tsx';
import { theme } from '../theme.ts';
import { CODE_LEFT, PAIR_CODE, WAIT_LEFT } from '../data/pairing.ts';
import * as L from './layouts.ts';
import type { Rect as Box } from './geometry.ts';

const NONE = ios.none;
const local = (r: Box): Box => ({ x: 0, y: 0, width: r.width, height: r.height });

/** A light overlay on a row after it is pressed: `amount` 0 to 1. Corners follow the card when the row is its last. */
const RowPress = ({ rect, amount, last = false }: { rect: Box; amount: number; last?: boolean }) => {
  if (amount <= 0) return null;
  const { x, y, width: w, height: h } = rect;
  return last ? (
    <Path x={x} y={y} d={`M0 0 H${w} V${h - 24} A24 24 0 0 1 ${w - 24} ${h} H24 A24 24 0 0 1 0 ${h - 24} Z`} fill="#ffffff" opacity={0.12 * amount} />
  ) : (
    <Rect x={x} y={y} width={w} height={h} fill="#ffffff" opacity={0.12 * amount} />
  );
};

const BackButton = () => (
  <Layer id="back-button">
    <Ellipse x={20} y={62} width={56} height={56} fill="#2c2c2e" />
    <BackChevron x={38} y={76} />
  </Layer>
);

// ------------------------------------------------------------------ scene 18: Remote Keyboard's home, with 設定進度

/** The app's home: 設定進度 with 藍牙 done and 已配對 Mac not yet. `press` (0 to 1) lights the 已配對 Mac row. */
export const SetupHomePage = ({ press }: { press: number }) => {
  const C = L.MAIN_CARD;
  const rows = [
    { label: '藍牙', detail: '已允許', done: true },
    { label: '已配對 Mac', detail: '尚未配對', done: false },
    { label: '加入鍵盤並允許完整取用', detail: undefined, done: false },
  ];
  return (
    <Layer id="page-setup-home">
      <StatusBar />
      <LargeTitle y={84}>Remote Keyboard</LargeTitle>
      <PText x={36} y={146} size={26} color={ios.muted}>設定進度</PText>
      <Card rect={C} />
      {rows.map((row, i) => {
        const r = { x: C.x, y: C.y + i * 72, width: C.width, height: 72 };
        const content = (
          <Layer>
            {row.done ? <CheckDisc x={20} y={18} size={36} /> : <Ellipse x={20} y={18} width={36} height={36} fill={NONE} stroke={{ color: '#636366', width: 3 }} />}
            <PText x={64} y={(72 - 26 * LINE) / 2} size={26} color={row.done ? ios.green : ios.ink}>{row.label}</PText>
            {row.detail && <PText x={r.width - 24 - 26 * row.detail.length} y={(72 - 26 * LINE) / 2} size={26} color={ios.muted}>{row.detail}</PText>}
          </Layer>
        );
        return (
          <Layer key={row.label}>
            {i > 0 && <Hair x={r.x + 20} y={r.y} w={r.width - 20} />}
            {i === 1 ? (
              <Layer>
                <RowPress rect={r} amount={press} />
                <Btn target="phoneRow" rect={r}>{content}</Btn>
              </Layer>
            ) : (
              <Layer x={r.x} y={r.y}>{content}</Layer>
            )}
          </Layer>
        );
      })}
      <PText x={36} y={430} size={26} color={ios.muted}>設定</PText>
      <Group rect={{ x: 16, y: 472, width: 358, height: 216 }} rows={3} render={(r, i) => <Row rect={r} icon={['#8e8e93', '#0a84ff', '#30d158'][i]} line={[150, 120, 180][i]} />} />
    </Layer>
  );
};

// ------------------------------------------------------------------ the three pages of the pairing flow

const Footer = ({ y }: { y: number }) => (
  <Layer>
    <Skel x={36} y={y} w={310} />
    <Skel x={36} y={y + 38} w={200} />
  </Layer>
);

/** 已配對 Mac: 尚未配對 (or 已配對 Mac), 配對 Mac, and 解除配對 once paired. `press` lights the 配對 Mac row. */
export const PairPage = ({ paired, press }: { paired: boolean; press: number }) => {
  const rows = paired ? 3 : 2;
  const card = { ...L.PAIRPAGE_CARD, height: rows * 72 };
  return (
    <Layer id="page-pair">
      <StatusBar />
      <BackButton />
      <LargeTitle y={124}>已配對 Mac</LargeTitle>
      <Group rect={card} rows={rows} render={(r, i) => {
        const lr = local(r);
        if (i === 0) return <Layer x={r.x} y={r.y}><Row rect={lr} label={paired ? '已配對 Mac' : '尚未配對'} chevron={false} /></Layer>;
        if (i === 1) {
          return (
            <Layer>
              <RowPress rect={r} amount={press} last={!paired} />
              <Btn target="pairMac" rect={r}><Row rect={lr} label="配對 Mac" /></Btn>
            </Layer>
          );
        }
        return <Layer x={r.x} y={r.y}><Row rect={lr} label="解除配對" chevron={false} color={ios.red} /></Layer>;
      }} />
      <Footer y={card.y + card.height + 20} />
    </Layer>
  );
};

/** 配對 Mac while it waits for the Mac: the instruction as gray lines, the countdown, 取消. */
export const PairWaitPage = () => (
  <Layer id="page-pair-wait">
    <StatusBar />
    <BackButton />
    <LargeTitle y={124}>配對 Mac</LargeTitle>
    <Card rect={L.PW_CARD} />
    <Skel x={36} y={L.PW_CARD.y + 30} w={300} />
    <Skel x={36} y={L.PW_CARD.y + 68} w={210} />
    <Hair x={36} y={L.PW_CARD.y + 100} w={338} />
    <PText x={36} y={L.PW_CARD.y + 100 + (70 - 26 * LINE) / 2} size={26} color={ios.muted}>{WAIT_LEFT}</PText>
    <Card rect={L.PW_CANCEL} />
    <PText x={36} y={L.PW_CANCEL.y + (72 - 28 * LINE) / 2} size={28} color={ios.blue}>取消</PText>
  </Layer>
);

/** 配對 Mac with the code: 配對碼, the six digits, the hint, the countdown, then 確認 and 取消. */
export const PairCodePage = ({ press }: { press: number }) => {
  const C = L.PC_CARD;
  return (
    <Layer id="page-pair-code">
      <StatusBar />
      <BackButton />
      <LargeTitle y={124}>配對 Mac</LargeTitle>
      <PText x={36} y={L.PC_HEAD_Y} size={26} color={ios.muted}>配對碼</PText>
      <Card rect={C} />
      <PText id="phone-pair-code" x={36} y={C.y + 14} size={56} weight={700}>{PAIR_CODE}</PText>
      <Hair x={36} y={C.y + 100} w={338} />
      <PText x={36} y={C.y + 100 + (100 - 26 * LINE * 2 * 0.92) / 2} size={26} color={ios.muted} w={318} lineHeight={1.3}>與 Mac 畫面上的數字相同時才按確認。</PText>
      <Hair x={36} y={C.y + 200} w={338} />
      <PText x={36} y={C.y + 200 + (64 - 26 * LINE) / 2} size={26} color={ios.muted}>{CODE_LEFT}</PText>
      <Card rect={{ x: 16, y: L.PC_CONFIRM.y, width: 358, height: 144 }} />
      <Hair x={36} y={L.PC_CANCEL.y} w={338} />
      <RowPress rect={L.PC_CONFIRM} amount={press} />
      <Btn target="phoneConfirm" rect={L.PC_CONFIRM}>
        <PText x={20} y={(72 - 28 * LINE) / 2} size={28} color={ios.blue}>確認</PText>
      </Btn>
      <PText x={36} y={L.PC_CANCEL.y + (72 - 28 * LINE) / 2} size={28} color={ios.blue}>取消</PText>
    </Layer>
  );
};

/** 已儲存 and, after 完成, 已配對 Mac: one list whose 完成 row does not move. */
export const PairSavedPage = ({ paired, press }: { paired: boolean; press: number }) => {
  const C = L.PS_CARD;
  return (
    <Layer id="page-pair-saved">
      <StatusBar />
      <BackButton />
      <LargeTitle y={124}>配對 Mac</LargeTitle>
      <Card rect={C} />
      {paired ? (
        <PText x={36} y={C.y + (100 - 28 * LINE) / 2} size={28}>已配對 Mac</PText>
      ) : (
        <PText x={36} y={C.y + (100 - 26 * LINE * 2 * 0.92) / 2} size={26} w={318} lineHeight={1.3}>已儲存。Mac 也按確認之後，再按完成。</PText>
      )}
      <Hair x={36} y={C.y + 100} w={338} />
      {paired ? <Skel x={36} y={C.y + 100 + 28} w={150} /> : <PText x={36} y={C.y + 100 + (72 - 26 * LINE) / 2} size={26} color={ios.muted}>{CODE_LEFT}</PText>}
      <Hair x={36} y={L.PS_DONE.y} w={338} />
      <RowPress rect={L.PS_DONE} amount={press} last />
      <Btn target="phoneDone" rect={L.PS_DONE}>
        <PText x={20} y={(72 - 28 * LINE) / 2} size={28} color={ios.blue}>完成</PText>
      </Btn>
    </Layer>
  );
};

// ------------------------------------------------------------------ scene 20: an input field and the keyboard list

/** Any app's page with an input field. `focused` draws the field's active outline and a caret. */
export const FieldPage = ({ focused }: { focused: boolean }) => (
  <Layer id="page-field">
    <StatusBar />
    <Rect id="field-outline" x={L.FIELD.x} y={L.FIELD.y} width={L.FIELD.width} height={L.FIELD.height} radius={18} fill={ios.card} stroke={focused ? { color: ios.blue, width: 3 } : undefined} />
    <Btn target="field" rect={L.FIELD}>
      <Skel x={20} y={28} w={160} />
      {focused && <Rect x={20} y={18} width={3} height={36} radius={1.5} fill={ios.blue} />}
    </Btn>
    {[0, 1, 2, 3].map((i) => <Skel key={i} x={36} y={236 + i * 44} w={[300, 240, 280, 180][i]} />)}
  </Layer>
);

/** The list that opens when the globe key is held: two other keyboards as gray lines, then Remote Keyboard. */
export const KeyboardList = ({ opacity }: { opacity: number }): ReactNode => {
  const P = L.KBPOP;
  const rk = L.KBPOP_RK;
  return (
    <Layer id="keyboard-list" opacity={opacity}>
      <Rect x={P.x} y={P.y} width={P.width} height={P.height} radius={22} fill="#3a3a3e" stroke={{ color: '#58585c', width: 1.5 }} />
      <Skel x={P.x + 24} y={P.y + 25} w={150} />
      <Hair x={P.x + 20} y={P.y + 66} w={P.width - 40} />
      <Skel x={P.x + 24} y={P.y + 91} w={110} />
      <Hair x={P.x + 20} y={rk.y} w={P.width - 40} />
      <Btn target="rk" rect={rk}>
        <BoxText box={local(rk)} size={26} weight={700} align="left" padX={24}>Remote Keyboard</BoxText>
      </Btn>
    </Layer>
  );
};

export { theme };
