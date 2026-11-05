/**
 * The phone's keyboard pages, drawn live from the measured key rectangles of intro/layout.ts, so a close-up stays sharp. The look is
 * the real screenshots' (docs/manual/images/kb-*.png): same keys, same labels, same colours. Local coordinates: 720 wide, the bottom
 * edge of the screen at y 864, every page bottom aligned. The finger rings are not drawn here (see Fingers.tsx).
 */
import { Ellipse, Layer, Path, Rect, Text } from '@kinetographdev/core';
import { theme } from '../theme.ts';
import { HW_CAND, KB, KEY_LABEL, QUICK_BAR, QUICK_ROOT, quickCenter } from '../intro/layout.ts';
import { panelPath, rectPath, polyline } from '../intro/shapes.ts';
import { INK_FROM } from './events.ts';
import { PHONE, PHONE_TOP, kbTop, type KbName, type R } from './layout.ts';
import { DRAFT_TEXT, inkAt, type PhoneState } from './state.ts';
import { textWidth } from './metrics.ts';

const NONE = '#00000000';
const LINE = 1.45;
export const PANEL = '#1f1f1f';
const LETTER = '#6b6b6b';
const FUNC = '#424242';
const SEG = '#36353a';
const FIELD = '#373639';
const BLUE = '#0a84ff';
const GREEN = '#30d158';
const GREY = '#8e8e93';
const BOTTOM_RADIUS = 110;

const Label = ({ r, text, size, color = '#ffffff', weight = 400, dy = 0 }: { r: R; text: string; size: number; color?: string; weight?: 400 | 500 | 700; dy?: number }) => (
  <Text font={theme.font} weight={weight} size={size} color={color} x={r.x} y={r.y + (r.h - size * LINE) / 2 + dy} maxWidth={r.w} align="center">{text}</Text>
);

// --- icons, drawn in a box of their own ---
const Shift = ({ r, color = '#ffffff' }: { r: R; color?: string }) => (
  <Path x={r.x + r.w / 2 - 17} y={r.y + r.h / 2 - 17} d="M17 0 L34 18 H24 V34 H10 V18 H0 Z" fill={NONE} stroke={{ color, width: 3.5, join: 'round' }} />
);
const Delete = ({ cx, cy, s = 1 }: { cx: number; cy: number; s?: number }) => (
  <Layer x={cx - 22 * s} y={cy - 15 * s} scale={s}>
    <Path d="M12 0 H38 Q44 0 44 6 V24 Q44 30 38 30 H12 L0 15 Z" fill={NONE} stroke={{ color: '#ffffff', width: 3.2, join: 'round' }} />
    <Path d="M19 9 L33 21 M33 9 L19 21" fill={NONE} stroke={{ color: '#ffffff', width: 3.2, cap: 'round' }} />
  </Layer>
);
const Chevron = ({ cx, cy, dir }: { cx: number; cy: number; dir: 'left' | 'right' }) => (
  <Path d={dir === 'left' ? `M${cx + 8} ${cy - 15} L${cx - 7} ${cy} L${cx + 8} ${cy + 15}` : `M${cx - 8} ${cy - 15} L${cx + 7} ${cy} L${cx - 8} ${cy + 15}`} fill={NONE} stroke={{ color: '#ffffff', width: 3.6, cap: 'round', join: 'round' }} />
);
/** Keyboard with a chevron under it: the hide key. */
const HideIcon = ({ cx, cy }: { cx: number; cy: number }) => (
  <Layer x={cx - 19} y={cy - 17}>
    <Rect width={38} height={22} radius={4} fill={NONE} stroke={{ color: '#ffffff', width: 2.4 }} />
    {[0, 1, 2].flatMap((r) => Array.from({ length: r === 2 ? 1 : 5 }, (_, c) => (
      r === 2 ? <Rect key={`${r}${c}`} x={10} y={15} width={18} height={2.6} radius={1.3} fill="#ffffff" /> : <Rect key={`${r}${c}`} x={5 + c * 6.2 + r * 3} y={5 + r * 5} width={3} height={2.6} radius={1.3} fill="#ffffff" />
    )))}
    <Path d="M9 27 L19 33 L29 27" fill={NONE} stroke={{ color: '#ffffff', width: 2.4, cap: 'round', join: 'round' }} />
  </Layer>
);
const Globe = ({ cx, cy }: { cx: number; cy: number }) => (
  <Layer x={cx} y={cy}>
    <Ellipse x={-24} y={-24} width={48} height={48} fill={NONE} stroke={{ color: '#ffffff', width: 3 }} />
    <Ellipse x={-11} y={-24} width={22} height={48} fill={NONE} stroke={{ color: '#ffffff', width: 3 }} />
    <Path d="M-24 0 H24 M-20 -12 H20 M-20 12 H20 M0 -24 V24" fill={NONE} stroke={{ color: '#ffffff', width: 2.6 }} />
  </Layer>
);
const Mic = ({ cx, cy }: { cx: number; cy: number }) => (
  <Layer x={cx} y={cy}>
    <Rect x={-9} y={-27} width={18} height={34} radius={9} fill={NONE} stroke={{ color: '#ffffff', width: 3 }} />
    <Path d="M-17 -4 Q-17 17 0 17 Q17 17 17 -4 M0 17 V28 M-9 28 H9" fill={NONE} stroke={{ color: '#ffffff', width: 3, cap: 'round' }} />
  </Layer>
);

// --- the pieces of a page (image coordinates of its screenshot) ---
const Toolbar = ({ kb, s }: { kb: KbName; s: PhoneState }) => {
  const y = KB[kb].toolbarY;
  const pad = kb === 'trackpad';
  const live = s.kb !== 'draft' && s.kb !== 'handwriting' && s.kb !== 'quick';
  const dim = s.status === 'none' ? 0.4 : 1;
  return (
    <Layer>
      {!pad && (
        <Layer>
          <Rect x={12} y={y} width={130} height={49} radius={14} fill={SEG} />
          <Rect x={80} y={y + 3} width={60} height={43} radius={12} fill="#000000" />
          <Label r={{ x: 14, y, w: 66, h: 49 }} text="本機" size={24} color={GREY} weight={500} />
          <Label r={{ x: 80, y, w: 60, h: 49 }} text="遠端" size={24} weight={500} />
        </Layer>
      )}
      {s.status === 'connected' && <Label r={{ x: 148, y, w: 140, h: 49 }} text="已連接" size={22} color={GREEN} weight={500} />}
      <Layer opacity={dim}>
        <Rect x={295} y={y} width={130} height={49} radius={12} fill={FUNC} />
        <Label r={{ x: 295, y, w: 130, h: 49 }} text={pad ? '鍵盤' : '觸控板'} size={24.5} />
      </Layer>
      <Rect x={437} y={y} width={130} height={49} radius={12} fill={FUNC} />
      <HideIcon cx={502} cy={y + 24.5} />
      {!pad && (
        <Layer>
          <Rect x={580} y={y} width={128} height={49} radius={14} fill={SEG} />
          <Rect x={live ? 582 : 646} y={y + 3} width={60} height={43} radius={12} fill="#000000" />
          <Label r={{ x: 582, y, w: 60, h: 49 }} text="即時" size={23} color={live ? '#ffffff' : GREY} weight={500} />
          <Label r={{ x: 646, y, w: 60, h: 49 }} text="草稿" size={23} color={live ? GREY : '#ffffff'} weight={500} />
        </Layer>
      )}
    </Layer>
  );
};

/** The draft row: the left and right keys, the field with its text and caret, the send key. */
const DraftRow = ({ kb, s, f }: { kb: KbName; s: PhoneState; f: number }) => {
  const k = KB[kb].keys;
  const ry = KB[kb].rowY!;
  const field = { x: 169, y: ry, w: 421, h: 53 };
  const { size, weight, padLeft } = DRAFT_TEXT;
  const text = s.draft.replace(/\n/g, '⏎');
  const before = s.draft.slice(0, s.caret).replace(/\n/g, '⏎');
  const after = s.draft.slice(s.caret).replace(/\n/g, '⏎');
  const caretX = field.x + padLeft + textWidth(before, size, weight);
  const blink = Math.floor(f / 15) % 2 === 0;
  const typing = s.pressed && (s.pressed.fx.k === 'char' || s.pressed.fx.k === 'pick' || s.pressed.fx.k === 'caret') ? true : false;
  const caretOn = blink || typing;
  const ty = field.y + (field.h - size * LINE) / 2;
  const sendOn = s.draft.length > 0 && s.code === '';
  return (
    <Layer>
      <Rect x={k.left.x} y={k.left.y} width={k.left.w} height={k.left.h} radius={12} fill={FUNC} />
      <Chevron cx={k.left.x + k.left.w / 2} cy={k.left.y + k.left.h / 2} dir="left" />
      <Rect x={k.right.x} y={k.right.y} width={k.right.w} height={k.right.h} radius={12} fill={FUNC} />
      <Chevron cx={k.right.x + k.right.w / 2} cy={k.right.y + k.right.h / 2} dir="right" />
      <Rect x={field.x} y={field.y} width={field.w} height={field.h} radius={12} fill={FIELD} />
      <Layer clip={{ kind: 'path', d: rectPath(field.x + 4, field.y, field.w - 8, field.h) }}>
        {text === '' && <Text font={theme.font} weight={400} size={size} color="#6f6f74" x={field.x + padLeft + 6} y={ty} maxWidth={300}>輸入草稿</Text>}
        {before !== '' && <Text font={theme.font} weight={weight} size={size} color="#ffffff" x={field.x + padLeft} y={ty} maxWidth={500}>{before}</Text>}
        {after !== '' && <Text font={theme.font} weight={weight} size={size} color="#ffffff" x={caretX + 3} y={ty} maxWidth={500}>{after}</Text>}
        <Rect x={caretX} y={field.y + 9} width={3} height={field.h - 18} radius={1.5} fill={caretOn ? BLUE : NONE} />
      </Layer>
      <Rect x={k.send.x} y={k.send.y} width={k.send.w} height={k.send.h} radius={12} fill={sendOn ? BLUE : '#403f44'} />
      <Label r={k.send} text="傳送" size={26} color={sendOn ? '#ffffff' : GREY} weight={500} />
    </Layer>
  );
};

const FUNC_KEYS = ['shift', 'delete', 'sym', 'zh', 'enter', 'rewrite'];
const keyLabel = (name: string, r: R, color = '#ffffff') => {
  if (name === 'shift') return <Shift r={r} color={color} />;
  if (name === 'delete') return <Delete cx={r.x + r.w / 2} cy={r.y + r.h / 2} />;
  if (name === 'space') return <Label r={r} text="空白" size={37.5} color={color} />;
  const t = KEY_LABEL[name];
  return t ? <Label r={r} text={t} size={26} color={color} /> : null;
};

const Keys = ({ kb, s }: { kb: KbName; s: PhoneState }) => {
  const keys = KB[kb].keys;
  const quick = kb === 'quick';
  const down = s.pressed && s.pressed.kb === kb ? s.pressed : null;
  return (
    <Layer>
      {Object.entries(keys).map(([name, r]) => {
        if (['trackpadBtn', 'hide', 'left', 'right', 'send', 'pad'].includes(name)) return null;
        const isDown = down?.key === name;
        const fn = FUNC_KEYS.includes(name);
        const shiftOn = name === 'shift' && s.shift;
        const fill = fn ? (isDown || shiftOn ? LETTER : FUNC) : isDown ? FUNC : LETTER;
        const isLetter = name.length === 1;
        const ch = isLetter ? (s.shift && !quick ? name.toUpperCase() : name) : '';
        const pressedChar = isDown && down!.fx.k === 'char' ? (down!.fx as { c: string }).c : ch;
        return (
          <Layer key={name}>
            <Rect x={r.x} y={r.y} width={r.w} height={r.h} radius={11} fill={fill} />
            {isLetter && !quick && <Label r={r} text={isDown ? pressedChar : ch} size={isDown ? 44 : 42} />}
            {isLetter && quick && (
              <Layer>
                <Label r={r} text={QUICK_ROOT[name]} size={43} />
                <Text font={theme.font} weight={500} size={17} color={isDown ? '#ffffffcc' : '#ffffff99'} x={r.x + r.w - 26} y={r.y + 5} maxWidth={20} align="center">{name.toUpperCase()}</Text>
              </Layer>
            )}
            {!isLetter && keyLabel(name, r)}
          </Layer>
        );
      })}
    </Layer>
  );
};

const Handwriting = ({ s, f }: { s: PhoneState; f: number }) => {
  const pad = KB.handwriting.keys.pad;
  const writing = f >= INK_FROM;
  return (
    <Layer>
      <Rect x={pad.x} y={pad.y} width={pad.w} height={pad.h} radius={14} fill="#3d3d3d" />
      {s.inkOn && !writing && <Label r={{ x: pad.x, y: pad.y + 150, w: pad.w, h: 70 }} text="在這裡手寫" size={30} color="#6e6e6e" weight={400} />}
      {!s.inkOn && <Label r={{ x: pad.x, y: pad.y + 150, w: pad.w, h: 70 }} text="在這裡手寫" size={30} color="#6e6e6e" weight={400} />}
      <Delete cx={660} cy={pad.y + 32} s={0.8} />
      {s.inkOn && inkAt(f).map((pts, i) => (
        <Path key={i} d={polyline((pts.length < 2 ? [pts[0], pts[0]] : pts).map((p) => [p.x, p.y] as const))} fill={NONE} stroke={{ color: '#ffffff', width: 8, cap: 'round', join: 'round' }} />
      ))}
      {s.hwCandidates && HW_CAND.xs.map((x, i) => (
        <Text key={i} font={theme.font} weight={400} size={HW_CAND.size} color="#ffffff" x={x - 100} y={HW_CAND.y - (HW_CAND.size * LINE) / 2} maxWidth={200} align="center">{HW_CAND.texts[i]}</Text>
      ))}
    </Layer>
  );
};

const QuickBar = ({ s }: { s: PhoneState }) => {
  if (s.candidates.length === 0) return null;
  const n = s.code.length;
  const roots = s.code.split('').map((c) => QUICK_ROOT[c]).join('');
  const y = QUICK_BAR.y;
  return (
    <Layer clip={{ kind: 'path', d: rectPath(0, y - 31, 720, 62) }}>
      <Text font={theme.font} weight={500} size={QUICK_BAR.size} color={BLUE} x={14 - s.scroll} y={y - (QUICK_BAR.size * LINE) / 2} maxWidth={200}>{roots}</Text>
      {s.candidates.map((c, i) => {
        const x = quickCenter(n, i, s.scroll);
        if (x < -50 || x > 770) return null;
        return (
          <Layer key={`${c}${i}`}>
            {i === 0 && s.scroll === 0 && <Rect x={x - 38} y={y - QUICK_BAR.h / 2} width={76} height={QUICK_BAR.h} radius={12} fill="#ffffff1f" />}
            <Text font={theme.font} weight={400} size={QUICK_BAR.size} color="#ffffff" x={x - 40} y={y - (QUICK_BAR.size * LINE) / 2} maxWidth={80} align="center">{c}</Text>
          </Layer>
        );
      })}
    </Layer>
  );
};

/** One keyboard page, bottom aligned on the phone screen. */
export const PhoneScreen = ({ state, f }: { state: PhoneState; f: number }) => {
  const kb = state.kb;
  const info = KB[kb];
  const hasDraft = info.rowY !== null;
  const pad = KB.trackpad.keys.pad;
  return (
    <Layer y={kbTop(kb)}>
      <Path d={panelPath(info.panelTop, 720, info.h, BOTTOM_RADIUS)} fill={PANEL} />
      <Toolbar kb={kb} s={state} />
      {hasDraft && <DraftRow kb={kb} s={state} f={f} />}
      {kb === 'trackpad' ? <Rect x={pad.x} y={pad.y} width={pad.w} height={pad.h} radius={14} fill="#333333" /> : <Keys kb={kb} s={state} />}
      {kb === 'handwriting' && <Handwriting s={state} f={f} />}
      {kb === 'quick' && <QuickBar s={state} />}
      <Globe cx={76} cy={info.h - 70} />
      <Mic cx={643} cy={info.h - 70} />
    </Layer>
  );
};
