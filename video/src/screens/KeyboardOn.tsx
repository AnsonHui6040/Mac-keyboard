import { Layer, Rect, Text } from '@kinetographdev/core';
import { MacWindow } from '../components/MacWindow.tsx';
import { PhoneScreen, fadeIn } from '../components/PhoneScreen.tsx';
import { deviceBrightness } from '../lib/dim.ts';
import { Keyboard, type KeyboardMode } from './Typing.tsx';
import { FieldPage, KeyboardList } from './phonePages3.tsx';
import { PHONE_ORIGIN_RIGHT } from './phone.ts';
import { Btn } from '../components/ios.tsx';
import { CONNECT_AT, TYPED_20, TYPE20_PITCH, TYPE20_START, typed20 } from './typing20.ts';
import * as L from './layouts.ts';
import type { ScreenProps } from './registry.tsx';
import { theme } from '../theme.ts';

const KEY_FLASH = 4;
const NONE = '#00000000';

/**
 * Scene 20. Beat 0: a click in the TextEdit document (the iPhone is dimmed). Beat 1: a tap on an input field brings up the stock keyboard.
 * Beat 2: the globe key opens the keyboard list, Remote Keyboard replaces the keyboard, then 遠端 is chosen. Beat 3: 已連接 turns green and
 * the sentence is typed on the iPhone and appears on the Mac.
 */
export const KeyboardOn = ({ active, prevActive, deviceFrame, beatIndex, beatFrame, stepTimes }: ScreenProps) => {
  const dim = (d: 'mac' | 'iphone') => deviceBrightness(d, { active, prevActive, beatFrame: deviceFrame });
  const clicked = beatIndex > 0 || beatFrame >= (stepTimes[0]?.land ?? Infinity);

  const fieldLand = beatIndex === 1 ? stepTimes[0]?.land ?? Infinity : -Infinity;
  const slide = beatIndex === 0 ? 0 : beatIndex === 1 ? fadeIn(beatFrame, fieldLand, 10) : 1;

  let mode: KeyboardMode = 'system';
  let list = 0;
  if (beatIndex === 2) {
    const [globe, rk, remote] = stepTimes;
    if (beatFrame >= (rk?.land ?? Infinity)) mode = beatFrame >= (remote?.land ?? Infinity) ? 'remote' : 'local';
    else list = fadeIn(beatFrame, globe?.land ?? Infinity, 5);
  } else if (beatIndex === 3) mode = beatFrame >= CONNECT_AT ? 'connected' : 'remote';

  const n = beatIndex === 3 ? typed20(beatFrame) : 0;
  const shown = TYPED_20.slice(0, n);
  const lastAt = TYPE20_START + TYPE20_PITCH * (n - 1);
  const pressedKey = beatIndex === 3 && n > 0 && beatFrame - lastAt < KEY_FLASH ? TYPED_20[n - 1] : undefined;
  const caretOn = Math.floor(beatFrame / 15) % 2 === 0;
  const W = L.TEXTEDIT20;

  return (
    <Layer id="screen-keyboardOn">
      <Layer id="mac-device" opacity={dim('mac')}>
        <MacWindow rect={W} title="未命名">
          <Rect x={W.x + 2} y={W.y + 58} width={W.width - 4} height={W.height - 60} radius={24} fill="#1e1f23" />
          <Btn target="doc" rect={L.DOC_CLICK}>
            <Rect width={L.DOC_CLICK.width} height={L.DOC_CLICK.height} fill={NONE} />
          </Btn>
          {clicked && (
            <Text id="typed" font={theme.font} weight={500} size={52} color={theme.ink} x={W.x + 60} y={W.y + 110} maxWidth={W.width - 120} lineHeight={1.5}
              chars={(_c: string, i: number) => (i === shown.length ? { color: caretOn ? '#2f7bf6' : NONE } : null)}>{shown + '|'}</Text>
          )}
        </MacWindow>
      </Layer>
      <PhoneScreen origin={PHONE_ORIGIN_RIGHT} brightness={dim('iphone')}>
        <FieldPage focused={slide > 0} />
        {slide > 0 && (
          <Layer id="keyboard-slide" y={(1 - slide) * 120} opacity={slide}>
            <Keyboard pressed={pressedKey} mode={mode} />
            <Btn target="globe" rect={L.GLOBE}>
              <Rect width={L.GLOBE.width} height={L.GLOBE.height} fill={NONE} />
            </Btn>
            {mode !== 'system' && (
              <Btn target="remote" rect={L.TB_REMOTE}>
                <Rect width={L.TB_REMOTE.width} height={L.TB_REMOTE.height} fill={NONE} />
              </Btn>
            )}
          </Layer>
        )}
        {list > 0 && <KeyboardList opacity={list} />}
      </PhoneScreen>
    </Layer>
  );
};

