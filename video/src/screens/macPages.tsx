/** Mac pieces of scenes 10 and 15, drawn in canvas pixels: the GitHub Release page, Terminal, AirDrop and a Finder window. */
import type { ReactNode } from 'react';
import { Ellipse, Layer, Path, Rect, Text } from '@kinetographdev/core';
import { CheckDisc, DocIcon, FolderIcon, RkIcon, ZipIcon } from '../components/appIcons.tsx';
import { GrayIcon, IloaderIcon, PhoneLine } from '../components/icons.tsx';
import { Btn } from '../components/ios.tsx';
import { MacWindow } from '../components/MacWindow.tsx';
import { SkeletonLines } from '../components/SkeletonLines.tsx';
import { IPA_NAME, ZIP_NAME, IPA_SHA256, ZIP_SHA256, RELEASE_URL, SIDESTORE_URL } from '../data/artifacts.ts';
import { theme } from '../theme.ts';
import * as L from './layouts.ts';
import type { Rect as Box } from './geometry.ts';
import { PROMPT, commandText, outputAt, typedChars } from './terminal.ts';

const NONE = '#00000000';
const PANEL = '#1b1c20';
const LINK = '#6cb0ff';
const GREEN = '#35c46a';

const T = ({ x, y, size, weight = 500, color = theme.ink, w, align, id, children }: { x: number; y: number; size: number; weight?: 400 | 500 | 700; color?: string; w?: number; align?: 'left' | 'center' | 'right'; id?: string; children: string }) => (
  <Text id={id} font={theme.font} weight={weight} size={size} color={color} x={x} y={y} maxWidth={w} align={align}>{children}</Text>
);

/** Monospace text (the engine's bundled JetBrains Mono): one character is 0.6 x size wide. */
const Mono = ({ id, x, y, color = theme.ink, children }: { id?: string; x: number; y: number; color?: string; children: ReactNode }) => (
  <Layer id={id} x={x} y={y}>
    <div style={{ position: 'absolute', left: 0, top: 0, fontFamily: 'monospace', fontSize: L.TERM_SIZE, lineHeight: '48px', whiteSpace: 'pre', color }}>{children}</div>
  </Layer>
);

const inner = (W: Box): Box => ({ x: W.x + 2, y: W.y + 58, width: W.width - 4, height: W.height - 60 });
const Panel = ({ W, fill = PANEL }: { W: Box; fill?: string }) => {
  const r = inner(W);
  return <Rect x={r.x} y={r.y} width={r.width} height={r.height} radius={24} fill={fill} />;
};

// ------------------------------------------------------------------ browser pages

/** The download mark in a browser's title bar, shown once a download has started. */
const DownloadMark = ({ W, opacity }: { W: Box; opacity: number }) => (
  <Layer id="download-mark" opacity={opacity}>
    <Ellipse x={W.x + W.width - 86} y={W.y + 10} width={36} height={36} fill="#2f6fd0" />
    <Path x={W.x + W.width - 86} y={W.y + 10} d="M18 9 V24 M11 18 L18 25 L25 18" fill={NONE} stroke={{ color: '#ffffff', width: 3.5, cap: 'round', join: 'round' }} />
  </Layer>
);

/** Scene 5 beat 0: sidestore.io with the iloader download button (the pointer is on it; `hover` lights it, `downloaded` shows the mark). */
export const SideStoreSite = ({ hover, downloaded }: { hover: number; downloaded: number }) => {
  const W = L.ILOADER_WINDOW;
  const b = L.ILO_DL;
  return (
    <Layer id="screen-sidestore-site">
      <MacWindow rect={W} title="sidestore.io" address={SIDESTORE_URL}>
        <Panel W={W} />
        <IloaderIcon x={W.x + 60} y={W.y + 110} size={128} />
        <T x={W.x + 220} y={W.y + 112} size={68} weight={700}>iloader</T>
        <SkeletonLines x={W.x + 220} y={W.y + 214} widths={[640, 520]} />
        <Btn target="idl" rect={b}>
          <Rect width={b.width} height={b.height} radius={22} fill="#0a84ff" />
          <Rect width={b.width} height={b.height} radius={22} fill="#ffffff" opacity={hover * 0.18} />
          <Path x={36} y={(b.height - 34) / 2} d="M17 3 V25 M6 15 L17 26 L28 15 M4 33 H30" fill={NONE} stroke={{ color: '#ffffff', width: 4, cap: 'round', join: 'round' }} />
          <T x={84} y={(b.height - 32 * 1.45) / 2} size={32} weight={700} color="#ffffff">Download</T>
        </Btn>
        <Rect x={b.x + b.width + 24} y={b.y} width={250} height={b.height} radius={22} fill="#3b3c41" />
        <SkeletonLines x={W.x + 60} y={W.y + 560} widths={[820, 700, 560]} />
        <DownloadMark W={W} opacity={downloaded} />
      </MacWindow>
    </Layer>
  );
};

// ------------------------------------------------------------------ GitHub Release page

/** `row` is the asset the pointer is on; `hover` (0 to 1) fades its highlight in; `downloaded` (0 to 1) shows the download mark in the title bar. */
export const ReleasePage = ({ row, hover, downloaded }: { row: 'ipa' | 'zip'; hover: number; downloaded: number }) => {
  const W = L.REL_WIN;
  const x0 = W.x + 80;
  const rows = [
    { target: 'ipadl', rect: L.REL_IPA, name: IPA_NAME, key: 'ipa', tone: '#0a84ff' },
    { target: 'zipdl', rect: L.REL_ZIP, name: ZIP_NAME, key: 'zip', tone: '#8d8f94' },
  ];
  const card = { x: x0, y: W.y + 350, width: 1440, height: 252 };
  return (
    <Layer id="screen-release">
      <MacWindow rect={W} title="github.com" address={RELEASE_URL}>
        <Panel W={W} />
        <T x={x0} y={W.y + 86} size={46} weight={700}>Remote Keyboard v0.1.0</T>
        <SkeletonLines x={x0} y={W.y + 176} widths={[1040, 860, 600]} />
        <T x={x0} y={W.y + 292} size={34} weight={700}>Assets</T>
        <Rect x={card.x} y={card.y} width={card.width} height={card.height} radius={18} fill="#222328" stroke={{ color: theme.hairline, width: 2 }} />
        <Rect x={card.x + 2} y={card.y + L.REL_ROW_H} width={card.width - 4} height={2} fill={theme.hairline} />
        <Rect x={card.x + 2} y={card.y + L.REL_ROW_H * 2} width={card.width - 4} height={2} fill={theme.hairline} />
        {rows.map((r) => (
          <Btn key={r.target} target={r.target} rect={r.rect}>
            <Rect x={4} y={4} width={r.rect.width - 8} height={r.rect.height - 8} radius={14} fill="#2f3138" opacity={row === r.key ? hover : 0} />
            {r.key === 'zip' ? <ZipIcon x={24} y={22} size={42} /> : <DocIcon x={24} y={22} size={42} tone={r.tone} />}
            <T x={84} y={(r.rect.height - 30 * 1.45) / 2} size={30} color={LINK}>{r.name}</T>
            <Rect x={1180} y={(r.rect.height - 16) / 2} width={110} height={16} radius={8} fill={theme.skeleton.color} />
          </Btn>
        ))}
        <Rect x={x0 + 84} y={card.y + L.REL_ROW_H * 2 + 34} width={300} height={16} radius={8} fill={theme.skeleton.color} />
        <Rect x={x0 + 1180} y={card.y + L.REL_ROW_H * 2 + 34} width={110} height={16} radius={8} fill={theme.skeleton.color} />
        <DownloadMark W={W} opacity={downloaded} />
      </MacWindow>
    </Layer>
  );
};

// ------------------------------------------------------------------ Terminal

/**
 * 終端機. `pageFrame` counts the frames since the page opened: the command is typed from TYPE_START on, the output (the hash and
 * the file name) shows after it, and `match` (0 to 1) fades in the green marks that say the two values are equal.
 * The Release page's value is on screen from the start, so once the output shows both hashes are fully visible.
 */
export const TerminalPage = ({ kind, pageFrame, match }: { kind: 'ipa' | 'zip'; pageFrame: number; match: number }) => {
  const W = L.TERM_WIN;
  const name = kind === 'ipa' ? IPA_NAME : ZIP_NAME;
  const sha = kind === 'ipa' ? IPA_SHA256 : ZIP_SHA256;
  const command = commandText(name);
  const typed = typedChars(pageFrame, command.length);
  const done = typed >= command.length;
  const charW = L.TERM_SIZE * 0.6;
  const hashW = sha.length * charW;
  const rowCmd = L.TERM_ROW_CMD;
  const rowHash = L.TERM_ROW_HASH;
  const rowRel = L.TERM_ROW_RELEASE;
  const mid = (rowHash + rowRel) / 2 + 24;
  const showOutput = pageFrame >= outputAt(command.length);
  return (
    <Layer id="screen-terminal">
      <MacWindow rect={W} title="終端機" fill="#17181b">
        <Panel W={W} fill="#101114" />
        <Mono id="terminal-command" x={L.TERM_X} y={rowCmd}>
          <span style={{ color: theme.muted }}>{PROMPT}</span>{command.slice(0, typed)}
        </Mono>
        {!showOutput && <Rect id="terminal-cursor" x={L.TERM_X + (PROMPT.length + typed) * charW} y={rowCmd + 7} width={charW} height={34} fill={theme.ink} opacity={done ? 0.9 : 0.75} />}
        {showOutput && <Mono id="terminal-hash" x={L.TERM_X} y={rowHash}>{sha}</Mono>}
        {showOutput && <Mono id="terminal-file" x={L.TERM_X} y={L.TERM_ROW_FILE} color={theme.muted}>{name}</Mono>}
        <Rect x={W.x + 2} y={L.TERM_DIVIDER} width={W.width - 4} height={2} fill={theme.hairline} />
        <T id="release-label" x={L.TERM_X} y={L.TERM_LABEL} size={28} color={theme.muted}>Release 頁面的 SHA-256</T>
        <Mono id="release-hash" x={L.TERM_X} y={rowRel}>{sha}</Mono>
        <Btn target="hash" rect={L.TERM_HASH_BOX} />
        <Layer id="match-marks" opacity={showOutput ? match : 0}>
          <Rect x={L.TERM_X - 12} y={rowHash - 2} width={hashW + 24} height={52} radius={12} fill={NONE} stroke={{ color: GREEN, width: 3 }} />
          <Rect x={L.TERM_X - 12} y={rowRel - 2} width={hashW + 24} height={52} radius={12} fill={NONE} stroke={{ color: GREEN, width: 3 }} />
          <Path d={`M${L.TERM_X - 20} ${rowHash + 24} H${L.TERM_X - 40} V${rowRel + 24} H${L.TERM_X - 20}`} fill={NONE} stroke={{ color: GREEN, width: 4, cap: 'round', join: 'round' }} />
          <CheckDisc x={L.TERM_X - 40 - 20} y={mid - 20} size={40} />
        </Layer>
      </MacWindow>
    </Layer>
  );
};

// ------------------------------------------------------------------ AirDrop

/** `sent` (0 to 1): the ring around 我的 iPhone fades in once the device is chosen. */
export const AirDropPage = ({ sent }: { sent: number }) => {
  const W = L.AD_WIN;
  const D = L.AD_DEVICE;
  const cx2 = D.x + D.width / 2;
  const cx1 = W.x + 260;
  const top = W.y + 245;
  return (
    <Layer id="screen-airdrop">
      <MacWindow rect={W} title="AirDrop">
        <Panel W={W} fill="#202126" />
        <Rect x={W.x + 60} y={W.y + 90} width={760} height={76} radius={16} fill="#2d2e33" />
        <DocIcon x={W.x + 76} y={W.y + 103} size={50} />
        <T x={W.x + 146} y={W.y + 90 + (76 - 28 * 1.45) / 2} size={28}>{IPA_NAME}</T>
        <Ellipse x={cx1 - 65} y={top} width={130} height={130} fill="#2d2e33" stroke={{ color: '#3f4046', width: 3 }} />
        <Rect x={cx1 - 60} y={top + 150} width={120} height={16} radius={8} fill={theme.skeleton.color} />
        <Btn target="airdrop" rect={D}>
          <Ellipse x={D.width / 2 - 65} y={top - D.y} width={130} height={130} fill="#1f3150" stroke={{ color: '#2f6fd0', width: 3 }} />
          <PhoneLine x={D.width / 2 - 35} y={top - D.y + 30} size={70} color="#ffffff" />
          <Ellipse x={D.width / 2 - 71} y={top - D.y - 6} width={142} height={142} fill={NONE} stroke={{ color: GREEN, width: 6 }} opacity={sent} />
          <T x={0} y={top - D.y + 142} size={28} w={D.width} align="center">我的 iPhone</T>
        </Btn>
        <CheckDisc x={cx2 + 28} y={top - 8} size={44} opacity={Math.max(0, sent * 2 - 1)} />
      </MacWindow>
    </Layer>
  );
};

// ------------------------------------------------------------------ Finder

const SIDEBAR_GRAY: [number, number][] = [[70, 120], [130, 96], [190, 140]];

export type FinderState = {
  /** Which folder the window shows: the downloads (default), or 應用程式 with Remote Keyboard Receiver in it. */
  folder?: 'downloads' | 'apps';
  /** 應用程式 folder: the Receiver cell is selected (0 to 1), and the app has been opened (0 to 1 over its bounce). */
  rkSelected?: number;
  rkOpen?: number;
  /** The zip cell is selected (a click or double click landed on it). */
  zipSelected: number;
  /** 0 to 1: the unzipped app next to the zip. */
  app: number;
  /** The app is being dragged: its cell in the window is a ghost. */
  ghost: boolean;
  /** The app was dropped on 應用程式: it is gone from this folder. */
  moved: boolean;
  /** 0 to 1: 應用程式 in the sidebar is highlighted (the drag is over it). */
  appsHi: number;
  /** Canvas position of the pointer while an app is dragged; the icon is drawn there. */
  drag?: { x: number; y: number };
};

export const FinderPage = ({ s }: { s: FinderState }) => {
  const W = L.FIN_WIN;
  const zip = L.FIN_ZIP;
  const app = L.FIN_APP;
  const appVisible = s.moved ? 0 : s.app;
  const inApps = s.folder === 'apps';
  const appsHi = inApps ? 1 : s.appsHi;
  const rk = L.FIN_RKAPP;
  const bounce = Math.sin(Math.PI * Math.min(1, Math.max(0, s.rkOpen ?? 0))) * 14;
  return (
    <Layer id="screen-finder">
      <MacWindow rect={W} title={inApps ? '應用程式' : '下載項目'}>
        <Panel W={W} />
        <Rect x={W.x + 2} y={W.y + 58} width={L.FIN_SIDEBAR_W - 2} height={W.height - 60} radius={24} fill="#202126" />
        <Rect x={W.x + L.FIN_SIDEBAR_W - 24} y={W.y + 58} width={24} height={W.height - 60} fill="#202126" />
        <Rect x={W.x + L.FIN_SIDEBAR_W} y={W.y + 58} width={2} height={W.height - 60} fill={theme.hairline} />
        {SIDEBAR_GRAY.map(([dy, w]) => (
          <Layer key={dy}>
            <FolderIcon x={W.x + 28} y={W.y + dy + 8} size={36} />
            <Rect x={W.x + 78} y={W.y + dy + 18} width={w} height={16} radius={8} fill={theme.skeleton.color} />
          </Layer>
        ))}
        <Btn target="apps" rect={L.FIN_APPS}>
          <Rect width={L.FIN_APPS.width} height={L.FIN_APPS.height} radius={12} fill="#2f6fd0" opacity={appsHi} />
          <FolderIcon x={14} y={8} size={36} />
          <T x={64} y={(L.FIN_APPS.height - 28 * 1.45) / 2} size={28}>應用程式</T>
        </Btn>
        <Layer id="downloads-row" x={L.FIN_DOWNLOADS.x} y={L.FIN_DOWNLOADS.y}>
          <Rect width={L.FIN_DOWNLOADS.width} height={L.FIN_DOWNLOADS.height} radius={12} fill="#34363b" opacity={1 - appsHi * 0.6} />
          <FolderIcon x={14} y={8} size={36} />
          <T x={64} y={(L.FIN_DOWNLOADS.height - 28 * 1.45) / 2} size={28}>下載項目</T>
        </Layer>

        {inApps ? (
          <Layer id="apps-folder">
            {[0, 1].map((i) => (
              <Layer key={i}>
                <GrayIcon x={zip.x + i * 300 + 45} y={zip.y + 6} size={150} tone={['#4a4b50', '#3d4756'][i]} />
                <Rect x={zip.x + i * 300 + 40} y={zip.y + 192} width={[160, 130][i]} height={16} radius={8} fill={theme.skeleton.color} />
              </Layer>
            ))}
            <Btn target="rkapp" rect={rk}>
              <Rect x={10} y={0} width={220} height={194} radius={16} fill="#2f3138" opacity={s.rkSelected ?? 0} />
              <Layer y={-bounce}>
                <RkIcon x={45} y={6} size={150} />
              </Layer>
              <T x={0} y={180} size={24} w={rk.width} align="center">{'Remote Keyboard\nReceiver'}</T>
            </Btn>
          </Layer>
        ) : (
          <Layer id="downloads-folder">
            <Btn target="zipfile" rect={zip}>
              <Rect x={10} y={0} width={220} height={194} radius={16} fill="#2f3138" opacity={s.zipSelected} />
              <ZipIcon x={45} y={6} size={150} />
              <T x={0} y={180} size={24} w={zip.width} align="center">{'RemoteKeyboard\nReceiver-v0.1.0-\nmacOS.zip'}</T>
            </Btn>
            <Btn target="receiver" rect={app}>
              <Layer opacity={appVisible * (s.ghost ? 0.3 : 1)}>
                <RkIcon x={45} y={6} size={150} />
                <T x={0} y={180} size={24} w={app.width} align="center">{'Remote Keyboard\nReceiver'}</T>
              </Layer>
            </Btn>
          </Layer>
        )}
        {s.drag && <RkIcon id="drag-icon" x={s.drag.x - 30} y={s.drag.y - 22} size={120} opacity={0.92} />}
      </MacWindow>
    </Layer>
  );
};
