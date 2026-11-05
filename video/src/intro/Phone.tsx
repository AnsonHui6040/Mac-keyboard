import { Image, Layer, Path, Rect, Text, staticFile } from '@kinetographdev/core';
import { Card, Skel, ios } from '../components/ios.tsx';
import { TapDot } from '../components/TapDot.tsx';
import { theme } from '../theme.ts';
import { COLORS, HW_CAND, KB, KEY_LABEL, PHONE, QUICK_BAR, QUICK_ROOT, draftField, kbTop, quickCenter, type KbName, type R } from './layout.ts';
import { INK_WIDTH, STROKES, partialStroke, strokeSchedule } from './ink.ts';
import { PRESSES, chapterOfPress, fingerAt, phoneAt, type Press, type PhoneState } from './script.ts';
import { fingerSource } from './fingers.ts';
import { trackpadState } from './trackpad.ts';
import { panelPath, polyline, rectPath, roundedRectPath } from './shapes.ts';
import type { Chapter } from './timeline.ts';

const NONE = '#00000000';
const LINE = 1.45;
const SCREEN_TOP = -200;
const BOTTOM_RADIUS = 110;
const LETTERS = 'qwertyuiopasdfghjklzxcvbnm'.split('');

/** White (or any color) text centered in a rect of the keyboard image. */
const Glyph = ({ r, text, size, color = '#ffffff', weight = 400 }: { r: R; text: string; size: number; color?: string; weight?: 400 | 500 | 700 }) => (
  <Text font={theme.font} weight={weight} size={size} color={color} x={r.x} y={r.y + (r.h - size * LINE) / 2} maxWidth={r.w} align="center">{text}</Text>
);

const inset = (r: R, d: number): R => ({ x: r.x + d, y: r.y + d, w: r.w - 2 * d, h: r.h - 2 * d });

const ShiftIcon = ({ r, color }: { r: R; color: string }) => (
  <Path x={r.x + r.w / 2 - 17} y={r.y + r.h / 2 - 17} d="M17 0 L34 18 H24 V34 H10 V18 H0 Z" fill={NONE} stroke={{ color, width: 3.5, join: 'round' }} />
);

/** The label drawn on a pressed function key. */
const functionLabel = (key: string, r: R, color: string) => {
  if (key === 'shift') return <ShiftIcon r={r} color={color} />;
  if (key === 'space') return <Glyph r={r} text="空白" size={36} color={color} />;
  const text = KEY_LABEL[key];
  return text ? <Glyph r={r} text={text} size={28} color={color} /> : null;
};

/** What the keyboard picture does while a key is down: a letter key goes dark with a white label, a function key gets lighter. */
const Pressed = ({ kb, press }: { kb: KbName; press: Press }) => {
  const k = KB[kb];
  const r = k.keys[press.key];
  if (!r) return null;
  const fx = press.fx;
  const letterKey = fx.k === 'char' || fx.k === 'code' || fx.k === 'blockedkey';
  if (letterKey) {
    const ch = fx.k === 'char' ? fx.c : press.key;
    const quick = kb === 'quick';
    return (
      <Layer>
        <Rect x={r.x} y={r.y} width={r.w} height={r.h} radius={11} fill={COLORS.func} />
        {press.key === 'space' ? functionLabel('space', r, '#ffffff') : quick ? (
          <Layer>
            <Glyph r={r} text={QUICK_ROOT[press.key] ?? ch} size={44} />
            <Text font={theme.font} weight={500} size={20} color="#ffffffcc" x={r.x + r.w - 26} y={r.y + 6} maxWidth={20} align="center">{press.key.toUpperCase()}</Text>
          </Layer>
        ) : <Glyph r={r} text={ch} size={46} />}
      </Layer>
    );
  }
  if (fx.k === 'pad') {
    return (
      <Layer>
        <Rect x={r.x} y={r.y} width={r.w} height={r.h} radius={11} fill={COLORS.letter} />
        <Glyph r={r} text="觸控板" size={28} />
      </Layer>
    );
  }
  if (fx.k === 'enter') {
    return (
      <Layer>
        <Rect x={r.x} y={r.y} width={r.w} height={r.h} radius={11} fill={COLORS.letter} />
        {functionLabel('enter', r, '#ffffff')}
      </Layer>
    );
  }
  return null;
};

const ShiftOn = ({ kb }: { kb: KbName }) => {
  const sh = KB[kb].keys.shift;
  return (
    <Layer>
      <Rect x={sh.x} y={sh.y} width={sh.w} height={sh.h} radius={11} fill={COLORS.letter} />
      <ShiftIcon r={sh} color="#ffffff" />
      {LETTERS.map((c) => {
        const r = KB[kb].keys[c];
        return (
          <Layer key={c}>
            <Rect x={r.x + 1} y={r.y + 1} width={r.w - 2} height={r.h - 2} radius={10} fill={COLORS.letter} />
            <Glyph r={r} text={c.toUpperCase()} size={46} />
          </Layer>
        );
      })}
    </Layer>
  );
};

/** Draft row: the typed text in the field, the blue 傳送 key, and a new line shown as the return mark. */
const DraftRow = ({ kb, draft, frame }: { kb: KbName; draft: string; frame: number }) => {
  const f = draftField(kb);
  const text = draft.replace(/\n/g, '⏎');
  const send = KB[kb].keys.send;
  const caret = Math.floor(frame / 15) % 2 === 0;
  const right = f.x + f.w - 16;
  // Short text starts at the left of the field like the real one; text that would not fit shows its end.
  const est = [...text].reduce((n, c) => n + (c.charCodeAt(0) < 256 ? 17 : 34), 0);
  const overflow = est > f.w - 40;
  return (
    <Layer>
      <Rect x={f.x} y={f.y} width={f.w} height={f.h} radius={12} fill={COLORS.field} />
      <Layer clip={{ kind: 'path', d: rectPath(f.x + 6, f.y, f.w - 12, f.h) }}>
        <Text font={theme.font} weight={400} size={34} color="#ffffff" x={overflow ? right - 1400 : f.x + 14} y={f.y + (f.h - 34 * LINE) / 2} maxWidth={1400} align={overflow ? 'right' : 'left'}
          chars={(_c: string, i: number) => (i === text.length ? { color: caret ? COLORS.blue : NONE } : null)}>{text + '|'}</Text>
      </Layer>
      <Rect x={send.x} y={send.y} width={send.w} height={send.h} radius={12} fill={COLORS.blue} />
      <Glyph r={send} text="傳送" size={30} weight={500} />
    </Layer>
  );
};

const Handwriting = ({ frame, state }: { frame: number; state: PhoneState }) => {
  const pad = KB.handwriting.keys.pad;
  const sched = strokeSchedule();
  return (
    <Layer>
      {state.inkOn && <Rect x={pad.x + 240} y={pad.y + 150} width={240} height={70} radius={10} fill={COLORS.hwPad} />}
      {state.inkOn && STROKES.map((s, i) => {
        if (frame < sched[i].from) return null;
        const u = (frame - sched[i].from) / (sched[i].to - sched[i].from);
        const pts = partialStroke(s, u);
        return <Path key={i} d={polyline(pts.length < 2 ? [pts[0], pts[0]] : pts)} fill={NONE} stroke={{ color: '#ffffff', width: INK_WIDTH, cap: 'round', join: 'round' }} />;
      })}
      {state.hwCandidates && HW_CAND.xs.map((x, i) => (
        <Text key={i} font={theme.font} weight={400} size={HW_CAND.size} color="#ffffff" x={x - 100} y={HW_CAND.y - (HW_CAND.size * LINE) / 2} maxWidth={200} align="center">{HW_CAND.texts[i]}</Text>
      ))}
    </Layer>
  );
};

const Quick = ({ state }: { state: PhoneState }) => {
  if (state.candidates.length === 0) return null;
  const n = state.code.length;
  const roots = state.code.split('').map((c) => QUICK_ROOT[c]).join('');
  const y = QUICK_BAR.y;
  return (
    <Layer clip={{ kind: 'path', d: rectPath(0, y - 31, 720, 62) }}>
      <Text font={theme.font} weight={500} size={QUICK_BAR.size} color={COLORS.blue} x={14 - state.scroll} y={y - (QUICK_BAR.size * LINE) / 2} maxWidth={200}>{roots}</Text>
      {state.candidates.map((c, i) => {
        const x = quickCenter(n, i, state.scroll);
        if (x < -50 || x > 770) return null;
        return (
          <Layer key={`${c}${i}`}>
            {i === 0 && <Rect x={x - 38} y={y - QUICK_BAR.h / 2} width={76} height={QUICK_BAR.h} radius={12} fill="#ffffff1f" />}
            <Text font={theme.font} weight={400} size={QUICK_BAR.size} color="#ffffff" x={x - 40} y={y - (QUICK_BAR.size * LINE) / 2} maxWidth={80} align="center">{c}</Text>
          </Layer>
        );
      })}
    </Layer>
  );
};

/**
 * The connected screenshot is cut 16 px lower than the blocked one, so its panel would start lower and jump at 1362. In the
 * connected state the blocked screenshot is drawn first, bottom aligned, and the connected one over it: the panel top is the
 * same in both states and every pixel is from the device.
 */
const Underlay = () => {
  const b = KB.blocked;
  return (
    <Layer id="keyboard-under" x={PHONE.x} y={kbTop('blocked')} clip={{ kind: 'path', d: panelPath(b.panelTop, 720, b.h, BOTTOM_RADIUS) }}>
      <Image src={staticFile(`images/${b.file}`)} width={720} height={b.h} />
    </Layer>
  );
};

const Keyboard = ({ at, chapter, state }: { at: number; chapter: Chapter; state: PhoneState }) => {
  const kb = state.kb;
  const info = KB[kb];
  const down = PRESSES.find((p) => at >= p.t && at < p.t + p.hold && chapterOfPress(p.t) === chapter);
  const hasDraft = info.rowY !== null;
  return (
    <>
      {kb === 'connected' && <Underlay />}
      <Layer id="keyboard" x={PHONE.x} y={kbTop(kb)} clip={{ kind: 'path', d: panelPath(info.panelTop, 720, info.h, BOTTOM_RADIUS) }}>
        <Image src={staticFile(`images/${info.file}`)} width={720} height={info.h} />
        {(kb === 'connected' || kb === 'draft') && state.shift && <ShiftOn kb={kb} />}
        {hasDraft && state.draft !== '' && <DraftRow kb={kb} draft={state.draft} frame={at} />}
        {kb === 'handwriting' && <Handwriting frame={at} state={state} />}
        {kb === 'quick' && <Quick state={state} />}
        {down && down.kb === kb && <Pressed kb={kb} press={down} />}
      </Layer>
    </>
  );
};

/** The phone at a chapter's frame: body, the app behind the keyboard, the keyboard picture with its overlays, and the finger(s). */
export const Phone = ({ at, chapter }: { at: number; chapter: Chapter }) => {
  const state = phoneAt(at, chapter);
  const showBox = kbTop(state.kb) >= 216;
  const onPad = fingerSource(at, chapter) === 'pad';
  const track = onPad ? trackpadState(at) : null;
  const finger = onPad ? null : fingerAt(at);
  return (
    <Layer id="iphone">
      <Rect id="iphone-body" x={PHONE.x - PHONE.bezel} y={SCREEN_TOP - PHONE.bezel} width={PHONE.w + PHONE.bezel * 2} height={864 - SCREEN_TOP + PHONE.bezel * 2} radius={PHONE.radius + PHONE.bezel}
        fill="#0c0c0e" stroke={{ color: '#4a4b50', width: 3 }} />
      <Layer id="iphone-screen" clip={{ kind: 'path', d: roundedRectPath(PHONE.x, SCREEN_TOP, PHONE.w, 864 - SCREEN_TOP, PHONE.radius) }}>
        <Rect x={PHONE.x} y={SCREEN_TOP} width={PHONE.w} height={864 - SCREEN_TOP} fill="#000000" />
        {showBox && (
          <Layer id="app-field">
            <Card rect={{ x: 1188, y: 96, width: 648, height: 104 }} radius={24} fill={ios.card} />
            <Skel x={1220} y={140} w={300} />
          </Layer>
        )}
        <Keyboard at={at} chapter={chapter} state={state} />
      </Layer>
      {finger && finger.visible && (
        <Layer id="finger" opacity={finger.opacity}>
          <TapDot state={{ x: finger.x, y: finger.y, visible: true, press: finger.press }} />
        </Layer>
      )}
      {track && track.fingers.length > 0 && (
        <Layer id="fingers" opacity={track.fingerOpacity}>
          <TapDot state={{ x: track.fingers[0].x, y: track.fingers[0].y, visible: true, press: track.fingers[0].down ? 1 : 0 }} />
          {track.fingers[1] && <TapDot id="pointer2" state={{ x: track.fingers[1].x, y: track.fingers[1].y, visible: true, press: track.fingers[1].down ? 1 : 0 }} />}
        </Layer>
      )}
    </Layer>
  );
};
