import { Layer, Path, Rect, Text, dropShadow } from '@kinetographdev/core';
import { MacWindow } from '../components/MacWindow.tsx';
import { MacCursor } from '../components/MacCursor.tsx';
import { Skel } from '../components/ios.tsx';
import { theme } from '../theme.ts';
import { DESKTOP, DISPLAY, LOGIN_FIELDS, LOGIN_WIN, MENU, TEXTEDIT, TITLEBAR } from './layout.ts';
import { lastMacChange, macTextAt } from './script.ts';
import { trackpadState } from './trackpad.ts';
import { loginCursorAt, loginFocused } from './login.ts';
import { roundedRectPath } from './shapes.ts';
import type { Chapter } from './timeline.ts';

const NONE = '#00000000';
const DESKTOP_FILL = '#24262b';
const MENU_FILL = '#1b1c20';
const DOC_FILL = '#1e1f23';
const CARET = '#2f7bf6';
const LINE = 1.45;
const SCREEN = { x: DISPLAY.x + DISPLAY.inset, y: DISPLAY.y + DISPLAY.inset, w: DISPLAY.w - 2 * DISPLAY.inset, h: DISPLAY.h - 2 * DISPLAY.inset };

export const MENU_FIRST = { textedit: ['文字編輯', '檔案', '編輯', '格式', '顯示方式', '視窗', '輔助說明'], login: ['登入', '檔案', '編輯', '視窗'] } as const;

const MenuBar = ({ items }: { items: readonly string[] }) => {
  let x = SCREEN.x + 28;
  return (
    <Layer id="menu-bar">
      <Rect x={SCREEN.x} y={SCREEN.y} width={SCREEN.w} height={DISPLAY.menuH} fill={MENU_FILL} />
      {items.map((t, i) => {
        const w = t.length * 24;
        const el = <Text key={t} font={theme.font} weight={i === 0 ? 700 : 400} size={24} color={theme.ink} x={x} y={SCREEN.y + (DISPLAY.menuH - 24 * LINE) / 2} maxWidth={w + 8}>{t}</Text>;
        x += w + 34;
        return el;
      })}
    </Layer>
  );
};

/** The Mac display: bezel, screen with its menu bar and desktop, then whatever is on the desktop. */
export const Display = ({ menu, children }: { menu: readonly string[]; children: React.ReactNode }) => (
  <Layer id="mac-display">
    <Rect id="display-body" x={DISPLAY.x} y={DISPLAY.y} width={DISPLAY.w} height={DISPLAY.h} radius={DISPLAY.radius} fill="#0c0c0e" stroke={{ color: '#4a4b50', width: 3 }} />
    <Layer id="display-screen" clip={{ kind: 'path', d: roundedRectPath(SCREEN.x, SCREEN.y, SCREEN.w, SCREEN.h, 18) }}>
      <Rect x={SCREEN.x} y={SCREEN.y} width={SCREEN.w} height={SCREEN.h} fill={DESKTOP_FILL} />
      {children}
      <MenuBar items={menu} />
    </Layer>
  </Layer>
);

// --- the TextEdit document ---
const DocLines = ({ text, size, weight, x, y, caret, color = theme.ink }: { text: string; size: number; weight: 400 | 500 | 700; x: number; y: number; caret: boolean; color?: string }) => {
  const lines = text.split('\n');
  return (
    <Layer>
      {lines.map((l, i) => {
        const last = i === lines.length - 1;
        const shown = last ? l + '|' : l;
        if (shown === '') return null;
        return (
          <Text key={i} font={theme.font} weight={weight} size={size} color={color} x={x} y={y + i * size * LINE} maxWidth={TEXTEDIT.w - 112}
            chars={(_c: string, k: number) => (last && k === l.length ? { color: caret ? CARET : NONE } : null)}>{shown}</Text>
        );
      })}
    </Layer>
  );
};

const Doc = ({ children, scrollY = 0 }: { children: React.ReactNode; scrollY?: number }) => (
  <Layer>
    <Rect x={2} y={TITLEBAR + 2} width={TEXTEDIT.w - 4} height={TEXTEDIT.h - TITLEBAR - 4} radius={24} fill={DOC_FILL} />
    <Layer clip={{ kind: 'path', d: roundedRectPath(2, TITLEBAR + 2, TEXTEDIT.w - 4, TEXTEDIT.h - TITLEBAR - 4, 24) }}>
      <Layer y={-scrollY}>{children}</Layer>
    </Layer>
  </Layer>
);

const TextWindow = ({ scale, children, scrollY }: { scale: number; children: React.ReactNode; scrollY?: number }) => (
  <Layer id="textedit" x={TEXTEDIT.x} y={TEXTEDIT.y} scale={scale}>
    <MacWindow rect={{ x: 0, y: 0, width: TEXTEDIT.w, height: TEXTEDIT.h }} title="未命名" shadow={false}>
      <Doc scrollY={scrollY}>{children}</Doc>
    </MacWindow>
  </Layer>
);

// --- desktop icons and the context menu of scene 4 ---
const FileIcon = ({ x, y, selected, lifted }: { x: number; y: number; selected: boolean; lifted: boolean }) => (
  <Layer id="file-icon" x={x} y={y} scale={lifted ? 1.1 : 1} effects={lifted ? [dropShadow({ y: 14, blur: 26, color: '#00000090' })] : []}>
    {selected && <Rect x={-64} y={-72} width={128} height={166} radius={14} fill="#ffffff26" />}
    <Path x={-40} y={-56} d="M0 8 Q0 0 8 0 H54 L80 26 V96 Q80 104 72 104 H8 Q0 104 0 96 Z" fill="#e8e9ec" stroke={{ color: '#c9cacf', width: 2 }} />
    <Path x={-40} y={-56} d="M54 0 V18 Q54 26 62 26 H80 Z" fill="#c4c5cb" />
    {[44, 60, 76].map((yy) => <Rect key={yy} x={-26} y={-56 + yy} width={52} height={6} radius={3} fill="#b4b6bd" />)}
    <Rect x={-46} y={58} width={92} height={34} radius={8} fill={selected ? '#0a60d0' : NONE} />
    <Text font={theme.font} weight={500} size={24} color="#ffffff" x={-60} y={58 + (34 - 24 * LINE) / 2} maxWidth={120} align="center">報告</Text>
  </Layer>
);

const FolderIcon = ({ x, y }: { x: number; y: number }) => (
  <Layer id="folder-icon" x={x} y={y}>
    <Path x={-58} y={-44} d="M0 10 Q0 0 10 0 H36 Q42 0 46 5 L52 12 H106 Q116 12 116 22 V80 Q116 90 106 90 H10 Q0 90 0 80 Z" fill="#5aaef5" />
    <Path x={-58} y={-44} d="M0 30 Q0 22 8 22 H108 Q116 22 116 30 V80 Q116 90 106 90 H10 Q0 90 0 80 Z" fill="#7cc2fb" />
    <Text font={theme.font} weight={500} size={24} color="#ffffff" x={-60} y={58 + (34 - 24 * LINE) / 2} maxWidth={120} align="center">文件</Text>
  </Layer>
);

const MENU_ITEMS = ['打開', '取得資訊', '重新命名', '丟到垃圾桶'] as const;
const ContextMenu = ({ x, y }: { x: number; y: number }) => (
  <Layer id="context-menu" x={x} y={y} effects={[dropShadow({ y: 12, blur: 30, color: '#00000090' })]}>
    <Rect width={MENU.w} height={MENU.h} radius={14} fill="#2c2d32" stroke={{ color: '#4a4b50', width: 2 }} />
    {MENU_ITEMS.map((t, i) => (
      <Layer key={t}>
        {i === 3 && <Rect x={16} y={8 + 3 * 54 - 1} width={218} height={2} fill="#4a4b50" />}
        <Text font={theme.font} weight={400} size={26} color="#f2f1ee" x={26} y={8 + i * 54 + (54 - 26 * LINE) / 2} maxWidth={200}>{t}</Text>
      </Layer>
    ))}
  </Layer>
);

// --- chapter 0: scenes 1 to 4 ---
export const Chapter0 = ({ at }: { at: number }) => {
  const t = trackpadState(at);
  const text = macTextAt(at, 0);
  const changed = lastMacChange(at, 0);
  const caret = at - changed < 12 || Math.floor(at / 15) % 2 === 0;
  const barsIn = Math.max(0, Math.min(1, (at - 912) / 24));
  return (
    <Display menu={MENU_FIRST.textedit}>
      {at >= 900 && (
        <Layer id="desktop-icons">
          <FileIcon x={t.filePos.x} y={t.filePos.y} selected={t.fileSelected} lifted={t.fileLifted} />
          <FolderIcon x={DESKTOP.folder.x} y={DESKTOP.folder.y} />
        </Layer>
      )}
      <TextWindow scale={t.winScale} scrollY={t.scrollY}>
        <DocLines text={text} size={56} weight={500} x={56} y={96} caret={caret} />
        <Layer opacity={barsIn}>
          {Array.from({ length: 10 }, (_, i) => <Skel key={i} x={56} y={596 + i * 46} w={[640, 520, 700, 460, 610, 380, 680, 540, 590, 420][i]} tone="#4b4c52" />)}
        </Layer>
      </TextWindow>
      {t.menuOpen && <ContextMenu x={t.menuPos.x} y={t.menuPos.y} />}
      {t.cursorVisible && (
        <Layer id="cursor-fade" opacity={Math.min(1, (at - 949) / 4)}>
          <MacCursor id="cursor" state={{ x: t.cursor.x, y: t.cursor.y, visible: true, press: t.cursorPress }} />
        </Layer>
      )}
    </Display>
  );
};

// --- chapter 1: scene 5, the login window ---
const Field = ({ r, focused, caretOn, children }: { r: { x: number; y: number; w: number; h: number }; focused: boolean; caretOn: boolean; children?: React.ReactNode }) => (
  <Layer>
    <Rect x={r.x} y={r.y} width={r.w} height={r.h} radius={14} fill="#17181b" stroke={{ color: focused ? theme.blue : '#4a4b50', width: focused ? 4 : 2 }} />
    {children}
    {focused && <Rect x={r.x + 22} y={r.y + 14} width={3} height={r.h - 28} fill={caretOn ? CARET : NONE} />}
  </Layer>
);

export const Chapter1 = ({ at }: { at: number }) => {
  const W = LOGIN_WIN;
  const F = LOGIN_FIELDS;
  const cur = loginCursorAt(at);
  const focused = loginFocused(at);
  return (
    <Display menu={MENU_FIRST.login}>
      <MacWindow rect={{ x: W.x, y: W.y, width: W.w, height: W.h }} title="登入" shadow={false}>
        <Text font={theme.font} weight={500} size={28} color={theme.muted} x={F.account.x} y={F.account.y - 52} maxWidth={300}>帳號</Text>
        <Field r={F.account} focused={false} caretOn={false}><Skel x={F.account.x + 24} y={F.account.y + 24} w={230} /></Field>
        <Text font={theme.font} weight={500} size={28} color={theme.muted} x={F.password.x} y={F.password.y - 52} maxWidth={300}>密碼</Text>
        <Field r={F.password} focused={focused} caretOn={Math.floor((at - 1358) / 15) % 2 === 0} />
        <Rect x={F.button.x} y={F.button.y} width={F.button.w} height={F.button.h} radius={14} fill={theme.blue} />
        <Text font={theme.font} weight={500} size={30} color="#ffffff" x={F.button.x} y={F.button.y + (F.button.h - 30 * LINE) / 2} maxWidth={F.button.w} align="center">登入</Text>
      </MacWindow>
      {cur.visible && (
        <Layer id="cursor-fade" opacity={Math.min(1, (at - 1333) / 4)}>
          <MacCursor id="cursor" state={{ x: cur.x, y: cur.y, visible: true, press: cur.press }} />
        </Layer>
      )}
    </Display>
  );
};

// --- chapter 2: scene 6, the product name and where to get it ---
const SHOW_AT = 1615;
const SHOW_FRAMES = 12;
export const PRODUCT_CAPTION_LAYOUT = { pill: { x: 56, y: 262, w: 330, h: 72 }, rows: [{ label: '下載', url: 'github.com/AnsonHui6040/Mac-keyboard', y: 396 }, { label: '安裝教學', url: 'youtu.be/dGhEuzRpAEg', y: 540 }] } as const;

export const Chapter2 = ({ at }: { at: number }) => {
  const text = macTextAt(at, 2);
  const typing = at < 1640;
  const caret = typing && (at - lastMacChange(at, 2) < 12 || Math.floor(at / 15) % 2 === 0);
  const u = Math.max(0, Math.min(1, (at - SHOW_AT) / SHOW_FRAMES));
  const e = u * u * (3 - 2 * u);
  const L = PRODUCT_CAPTION_LAYOUT;
  return (
    <Display menu={MENU_FIRST.textedit}>
      <TextWindow scale={1}>
        <DocLines text={text} size={96} weight={700} x={56} y={96} caret={caret} />
        <Layer id="product-info" opacity={e} y={(1 - e) * 14}>
          <Rect x={L.pill.x} y={L.pill.y} width={L.pill.w} height={L.pill.h} radius={L.pill.h / 2} fill={NONE} stroke={{ color: '#febc2e', width: 3 }} />
          <Text font={theme.font} weight={700} size={40} color="#febc2e" x={L.pill.x} y={L.pill.y + (L.pill.h - 40 * LINE) / 2} maxWidth={L.pill.w} align="center">v0.1.0 Alpha</Text>
          {L.rows.map((r) => (
            <Layer key={r.label}>
              <Text font={theme.font} weight={400} size={32} color={theme.muted} x={56} y={r.y} maxWidth={600}>{r.label}</Text>
              <Text font={theme.font} weight={500} size={44} color={theme.ink} x={56} y={r.y + 32 * LINE + 4} maxWidth={TEXTEDIT.w - 112}>{r.url}</Text>
            </Layer>
          ))}
        </Layer>
      </TextWindow>
    </Display>
  );
};
