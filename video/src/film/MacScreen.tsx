/**
 * The Mac screen, 1280 by 800, drawn live: the desktop with a document, the file and the folder of shot 21, the login window, the
 * remote desktop window. Colours are the product's only (no red, yellow or blue on the Mac side), the window buttons are grey.
 */
import { Ellipse, Layer, Path, Rect, Text, dropShadow } from '@kinetographdev/core';
import { theme } from '../theme.ts';
import { roundedRectPath } from '../intro/shapes.ts';
import { CURSOR, DOC, FOLDER_ITEMS, FOLDER_WIN, ICON, LOGIN_FIELDS, LOGIN_WIN, MAC, MENU, REMOTE_FIELD, REMOTE_WIN } from './layout.ts';
import { macAt, type MacState } from './state.ts';
import { textWidth } from './metrics.ts';

const NONE = '#00000000';
const LINE = 1.45;
const INK = theme.ink;
const MUTED = theme.muted;
const BAR = '#1b1c20';
const WINDOW = '#26272b';
const PAPER = '#1e1f23';
const EDGE = '#4a4b50';
const SOFT = '#ffffff24';
const ARROW = 'M0 0 L0 29 L7 22.5 L12 34 L17.5 31.5 L12.5 20.5 L22 20.5 Z';
const DOC_BIG = 72;
const ease = (u: number): number => (u <= 0 ? 0 : u >= 1 ? 1 : 1 - (1 - u) ** 3);

const MENUS = { doc: ['文字編輯', '檔案', '編輯', '格式', '顯示方式', '視窗', '輔助說明'], login: ['登入', '檔案', '編輯', '視窗'], remote: ['遠端桌面', '檔案', '編輯', '視窗'] } as const;

const MenuBar = ({ items }: { items: readonly string[] }) => {
  let x = 28;
  return (
    <Layer>
      <Rect width={MAC.w} height={MAC.menuH} fill={BAR} />
      {items.map((t, i) => {
        const w = [...t].length * 21;
        const el = <Text key={t} font={theme.font} weight={i === 0 ? 700 : 400} size={20} color={INK} x={x} y={(MAC.menuH - 20 * LINE) / 2} maxWidth={w + 8}>{t}</Text>;
        x += w + 28;
        return el;
      })}
    </Layer>
  );
};

/** A window: rounded panel, grey window buttons, a centred title and a hairline under the bar. */
const Window = ({ x, y, w, h, bar = 56, title }: { x: number; y: number; w: number; h: number; bar?: number; title: string }) => (
  <Layer>
    <Rect x={x} y={y} width={w} height={h} radius={22} fill={WINDOW} stroke={{ color: EDGE, width: 2 }} />
    {[0, 1, 2].map((i) => <Ellipse key={i} x={x + 24 + i * 30} y={y + (bar - 16) / 2} width={16} height={16} fill="#5b5c61" />)}
    <Text font={theme.font} weight={500} size={22} color={MUTED} x={x + 150} y={y + (bar - 22 * LINE) / 2} maxWidth={w - 300} align="center">{title}</Text>
    <Rect x={x + 2} y={y + bar} width={w - 4} height={2} fill={theme.hairline} />
  </Layer>
);

const Cursor = ({ x, y, opacity, press, scale }: { x: number; y: number; opacity: number; press: number; scale: number }) => (
  <Layer x={x} y={y} opacity={opacity}>
    <Ellipse x={-26} y={-26} width={52} height={52} fill={NONE} stroke={{ color: '#ffffff', width: 4 }} opacity={press * 0.7} scale={0.6 + 0.4 * press} origin="center" />
    <Layer scale={scale * (1 - 0.1 * press)}>
      <Path d={ARROW} fill="#111111" stroke={{ color: '#ffffff', width: 2.2 }} />
    </Layer>
  </Layer>
);

// --- the document ---
const DocLines = ({ lines, size, weight, caretOn, x, y, width }: { lines: string[]; size: number; weight: 400 | 500 | 700; caretOn: boolean; x: number; y: number; width: number }) => (
  <Layer>
    {lines.map((l, i) => {
      const last = i === lines.length - 1;
      const shown = last ? `${l}|` : l;
      if (shown === '') return null;
      return (
        <Text key={i} font={theme.font} weight={weight} size={size} color={INK} x={x} y={y + i * size * LINE} maxWidth={width}
          chars={(_c: string, k: number) => (last && k === l.length ? { color: caretOn ? INK : NONE } : null)}>{shown}</Text>
      );
    })}
  </Layer>
);

const DocWindow = ({ m, big }: { m: MacState; big: boolean }) => (
  <Layer>
    <Window x={DOC.x} y={DOC.y} w={DOC.w} h={DOC.h} bar={DOC.bar} title="未命名" />
    <Rect x={DOC.x + 2} y={DOC.y + DOC.bar + 2} width={DOC.w - 4} height={DOC.h - DOC.bar - 4} radius={20} fill={PAPER} />
    <Layer clip={{ kind: 'path', d: roundedRectPath(DOC.x + 2, DOC.y + DOC.bar + 2, DOC.w - 4, DOC.h - DOC.bar - 4, 20) }}>
      <DocLines lines={m.lines} size={big ? DOC_BIG : DOC.size} weight={big ? 700 : 500} caretOn={m.caretOn} x={DOC.textX} y={big ? DOC.textY - 4 : DOC.textY} width={DOC.w - 112} />
    </Layer>
  </Layer>
);

// --- the desktop icons ---
const FileIcon = ({ x, y, selected, lifted, shrink }: { x: number; y: number; selected: boolean; lifted: boolean; shrink: number }) => (
  <Layer x={x} y={y} scale={(lifted ? 1.1 : 1) * (1 - 0.88 * shrink)} opacity={1 - 0.6 * shrink} effects={lifted ? [dropShadow({ y: 16, blur: 28, color: '#00000099' })] : []}>
    <Layer scale={1.45}>
      {selected && <Rect x={-60} y={-72} width={120} height={170} radius={14} fill={SOFT} />}
      <Path x={-40} y={-56} d="M0 8 Q0 0 8 0 H54 L80 26 V96 Q80 104 72 104 H8 Q0 104 0 96 Z" fill="#e8e9ec" stroke={{ color: '#c9cacf', width: 2 }} />
      <Path x={-40} y={-56} d="M54 0 V18 Q54 26 62 26 H80 Z" fill="#c4c5cb" />
      {[44, 60, 76].map((yy) => <Rect key={yy} x={-26} y={-56 + yy} width={52} height={6} radius={3} fill="#b4b6bd" />)}
    </Layer>
    <Rect x={-56} y={90} width={112} height={40} radius={9} fill={selected ? '#5b5d63' : NONE} />
    <Text font={theme.font} weight={500} size={28} color="#ffffff" x={-70} y={90 + (40 - 28 * LINE) / 2} maxWidth={140} align="center">行程</Text>
  </Layer>
);

const FolderIcon = ({ x, y }: { x: number; y: number }) => (
  <Layer x={x} y={y}>
    <Layer scale={1.4}>
      <Path x={-58} y={-44} d="M0 10 Q0 0 10 0 H36 Q42 0 46 5 L52 12 H106 Q116 12 116 22 V80 Q116 90 106 90 H10 Q0 90 0 80 Z" fill="#aeb2ba" />
      <Path x={-58} y={-44} d="M0 30 Q0 22 8 22 H108 Q116 22 116 30 V80 Q116 90 106 90 H10 Q0 90 0 80 Z" fill="#d3d6dc" />
    </Layer>
    <Text font={theme.font} weight={500} size={28} color="#ffffff" x={-70} y={74 + (40 - 28 * LINE) / 2} maxWidth={140} align="center">香港</Text>
  </Layer>
);

const ContextMenu = ({ x, y, hover }: { x: number; y: number; hover: number }) => (
  <Layer x={x} y={y} effects={[dropShadow({ y: 12, blur: 30, color: '#00000090' })]}>
    <Rect width={MENU.w} height={MENU.h} radius={14} fill="#2c2d32" stroke={{ color: EDGE, width: 2 }} />
    {hover >= 0 && <Rect x={8} y={MENU.pad + hover * MENU.itemH} width={MENU.w - 16} height={MENU.itemH} radius={9} fill={SOFT} />}
    {MENU.items.map((t, i) => (
      <Layer key={t}>
        {i === 3 && <Rect x={16} y={MENU.pad + 3 * MENU.itemH - 1} width={MENU.w - 32} height={2} fill={EDGE} />}
        <Text font={theme.font} weight={400} size={26} color="#f2f1ee" x={26} y={MENU.pad + i * MENU.itemH + (MENU.itemH - 26 * LINE) / 2} maxWidth={200}>{t}</Text>
      </Layer>
    ))}
  </Layer>
);

/** The folder window, opening from the folder icon: a list that scrolls. */
const FolderWindow = ({ u, scrollY }: { u: number; scrollY: number }) => {
  const w = FOLDER_WIN;
  const k = ease(u);
  const s = 0.12 + 0.88 * k;
  const cx = ICON.folder.x + (w.x + w.w / 2 - ICON.folder.x) * k;
  const cy = ICON.folder.y + (w.y + w.h / 2 - ICON.folder.y) * k;
  const top = w.bar + 2;
  return (
    <Layer x={cx} y={cy} scale={s} opacity={Math.min(1, u * 5)} effects={[dropShadow({ y: 18, blur: 44, color: '#00000088' })]}>
      <Layer x={-w.w / 2} y={-w.h / 2}>
        <Window x={0} y={0} w={w.w} h={w.h} bar={w.bar} title="香港" />
        <Layer clip={{ kind: 'path', d: roundedRectPath(2, top, w.w - 4, w.h - top - 2, 20) }}>
          <Layer y={-scrollY}>
            {FOLDER_ITEMS.map((name, i) => {
              const y = top + 12 + i * w.row;
              return (
                <Layer key={name}>
                  <Path x={w.pad + 12} y={y + 14} d="M0 6 Q0 0 6 0 H26 L38 12 V50 Q38 56 32 56 H6 Q0 56 0 50 Z" fill="#d9dbe0" />
                  <Text font={theme.font} weight={500} size={30} color={INK} x={w.pad + 72} y={y + (w.row - 30 * LINE) / 2 - 4} maxWidth={400}>{name}</Text>
                  <Rect x={w.pad + 72} y={y + w.row - 4} width={w.w - 2 * w.pad - 72} height={2} fill={theme.hairline} />
                </Layer>
              );
            })}
          </Layer>
        </Layer>
      </Layer>
    </Layer>
  );
};

// --- the login window and the remote desktop window ---
const Field = ({ r, focused, caretOn, children }: { r: { x: number; y: number; w: number; h: number }; focused: boolean; caretOn: boolean; children?: React.ReactNode }) => (
  <Layer>
    <Rect x={r.x} y={r.y} width={r.w} height={r.h} radius={14} fill="#17181b" stroke={{ color: focused ? '#e6e7ea' : EDGE, width: focused ? 4 : 2 }} />
    {children}
    {focused && <Rect x={r.x + 22} y={r.y + 14} width={3} height={r.h - 28} fill={caretOn ? INK : NONE} />}
  </Layer>
);
const Skel = ({ x, y, w }: { x: number; y: number; w: number }) => <Rect x={x} y={y} width={w} height={16} radius={8} fill="#4b4c52" />;

const LoginWindow = ({ m, f }: { m: MacState; f: number }) => {
  const F = LOGIN_FIELDS;
  return (
    <Layer>
      <Window x={LOGIN_WIN.x} y={LOGIN_WIN.y} w={LOGIN_WIN.w} h={LOGIN_WIN.h} title="登入" />
      <Text font={theme.font} weight={500} size={26} color={MUTED} x={F.account.x} y={F.account.y - 46} maxWidth={300}>帳號</Text>
      <Field r={F.account} focused={false} caretOn={false}><Skel x={F.account.x + 24} y={F.account.y + 24} w={230} /></Field>
      <Text font={theme.font} weight={500} size={26} color={MUTED} x={F.password.x} y={F.password.y - 46} maxWidth={300}>密碼</Text>
      <Field r={F.password} focused={m.loginFocused} caretOn={Math.floor(f / 15) % 2 === 0} />
      <Rect x={F.button.x} y={F.button.y} width={F.button.w} height={F.button.h} radius={14} fill="#4a4b50" />
      <Text font={theme.font} weight={500} size={28} color="#ffffff" x={F.button.x} y={F.button.y + (F.button.h - 28 * LINE) / 2} maxWidth={F.button.w} align="center">登入</Text>
    </Layer>
  );
};

const RemoteWindow = ({ m, f }: { m: MacState; f: number }) => {
  const R = REMOTE_WIN;
  const F = REMOTE_FIELD;
  const blink = Math.floor(f / 15) % 2 === 0;
  const dotsW = m.dots * 46;
  return (
    <Layer>
      <Window x={R.x} y={R.y} w={R.w} h={R.h} bar={R.bar} title="遠端桌面" />
      <Rect x={R.x + 20} y={R.y + R.bar + 18} width={R.w - 40} height={R.h - R.bar - 38} radius={14} fill="#15161a" />
      <Rect x={R.x + 200} y={R.y + R.bar + 78} width={R.w - 400} height={R.h - R.bar - 158} radius={18} fill="#202125" stroke={{ color: '#34363b', width: 2 }} />
      <Text font={theme.font} weight={500} size={26} color={MUTED} x={F.x} y={F.y - 54} maxWidth={300}>密碼</Text>
      <Field r={F} focused caretOn={false}>
        {Array.from({ length: m.dots }, (_, i) => <Ellipse key={i} x={F.x + 30 + i * 46} y={F.y + F.h / 2 - 12} width={24} height={24} fill="#ffffff" />)}
        <Rect x={F.x + 32 + dotsW - 8 * (m.dots > 0 ? 0 : 1)} y={F.y + 16} width={3} height={F.h - 32} fill={blink ? INK : NONE} />
      </Field>
    </Layer>
  );
};

/** The Mac at a frame. */
/** `stage` is true in the 3D shots, where the pointer is drawn larger so it is at least 44 px on the frame. */
export const MacScreen = ({ f, stage = false }: { f: number; stage?: boolean }) => {
  const m = macAt(f);
  const t = m.track;
  const menu = m.screen === 'login' ? MENUS.login : m.screen === 'remote' ? MENUS.remote : MENUS.doc;
  return (
    <Layer>
      <Rect width={MAC.w} height={MAC.h} fill="#24262b" />
      {(m.screen === 'doc' || m.screen === 'doc2') && (
        <Layer>
          <DocWindow m={m} big={m.screen === 'doc2'} />
          {m.screen === 'doc' && <FileIcon x={t ? t.filePos.x : ICON.file.x} y={t ? t.filePos.y : ICON.file.y} selected={!!t && (t.fileSelected || t.fileLifted)} lifted={!!t && t.fileLifted} shrink={t ? t.fileDrop : 0} />}
          <FolderIcon x={ICON.folder.x} y={ICON.folder.y} />
          {t && t.folderU > 0 && <FolderWindow u={t.folderU} scrollY={t.scrollY} />}
          {t && t.menuOpen && <ContextMenu x={t.menuPos.x} y={t.menuPos.y} hover={t.menuHover} />}
        </Layer>
      )}
      {m.screen === 'login' && <LoginWindow m={m} f={f} />}
      {m.screen === 'remote' && <RemoteWindow m={m} f={f} />}
      <MenuBar items={menu} />
      {m.cursor && m.cursor.opacity > 0 && <Cursor x={m.cursor.x} y={m.cursor.y} opacity={m.cursor.opacity} press={m.cursor.press} scale={stage ? CURSOR.stage : CURSOR.close} />}
    </Layer>
  );
};

/** x and y of the caret of the last line of the document, on the Mac screen (for the camera). */
export const caretAt = (lines: string[], big = false): { x: number; y: number } => {
  const size = big ? DOC_BIG : DOC.size;
  const i = lines.length - 1;
  return { x: DOC.textX + textWidth(lines[i], size, big ? 700 : 500), y: (big ? DOC.textY - 4 : DOC.textY) + i * size * LINE + (size * LINE) / 2 };
};
