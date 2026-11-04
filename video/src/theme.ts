/** Visual system values for the install tutorial (dark stage). Source: design doc, 視覺系統. */
export const theme = {
  font: 'Noto Sans TC',
  stage: '#17181b',
  ink: '#f2f1ee',
  muted: '#9a9ba1',
  hairline: '#34363b',
  /** Subtitle divider: spans the stage margins, sits at y=884. */
  divider: { x: 72, y: 884, width: 1776, height: 2 },
  dialog: { fill: '#26272b', edge: '#4a4b50', radius: 46, title: '#f4f4f5', shadow: '#00000060' },
  skeleton: { color: '#4b4c52', height: 16, radius: 8, pitch: 38 },
  neutralBtn: { fill: '#3b3c41', ink: '#f1f1f2' },
  blue: '#2f7bf6',
  good: { ring: '#35c46a', ink: '#5fdc8f' },
  bad: '#ff5a4f',
  subtitle: { weight: 500, size: 46, y: 920, maxWidth: 1776, lineHeight: 1.4 },
  deviceTag: { x: 72, y: 72, weight: 500, size: 30 },
  callout: { weight: 700, size: 52, lineWidth: 5, ringGap: 6, lineLength: 170, textGap: 22, labelLift: 38 },
} as const;

export type Theme = typeof theme;
