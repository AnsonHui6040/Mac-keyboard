/** Scenes, captions and chapters of the product intro (docs/video/product-intro-script.md). Pure data. */
export const FPS = 30;
export const FRAMES = 1830;
export const WIDTH = 1920;
export const HEIGHT = 1080;

export type SceneDef = { id: string; from: number; to: number; caption: string };

export const SCENES: readonly SceneDef[] = [
  { id: '1', from: 0, to: 180, caption: '用 iPhone 打字到 Mac' },
  { id: '2a', from: 180, to: 330, caption: '即時模式每按一個鍵就送出' },
  { id: '2b', from: 330, to: 450, caption: '草稿模式先在鍵盤上編輯' },
  { id: '2c', from: 450, to: 540, caption: '按「傳送」才一次送出' },
  { id: '3a', from: 540, to: 720, caption: '中文可以用手寫' },
  { id: '3b', from: 720, to: 900, caption: '也可以在 App 改用速成' },
  { id: '4a', from: 900, to: 955, caption: '切換到觸控板' },
  { id: '4b', from: 955, to: 1025, caption: '一根手指移動游標' },
  { id: '4c', from: 1025, to: 1085, caption: '輕點一下就是點按' },
  { id: '4d', from: 1085, to: 1170, caption: '按住再移動就能拖曳' },
  { id: '4e', from: 1170, to: 1235, caption: '兩指輕點就是右鍵' },
  { id: '4f', from: 1235, to: 1320, caption: '兩指滑動可以捲動' },
  { id: '5a', from: 1320, to: 1410, caption: '系統標示的密碼欄不會輸入文字' },
  { id: '5b', from: 1410, to: 1530, caption: '部分終端機與遠端桌面偵測不到\n請不要用這個鍵盤輸入密碼' },
  { id: '6a', from: 1530, to: 1680, caption: 'Alpha 版透過 SideStore 安裝' },
  { id: '6b', from: 1680, to: 1830, caption: '不是 App Store 版本' },
];

export const captionAt = (frame: number): string => {
  const s = SCENES.find((c) => frame >= c.from && frame < c.to);
  return s ? s.caption : SCENES[SCENES.length - 1].caption;
};

/** Caption length for the reading-speed rule: every CJK character counts 1, every run of Latin letters or digits counts 1. */
export const captionLength = (text: string): number => {
  const cjk = (text.match(/[㐀-鿿]/g) ?? []).length;
  const words = (text.match(/[A-Za-z0-9]+/g) ?? []).length;
  return cjk + words;
};

/** Three chapters of the picture: the Mac display with the TextEdit window (0), the login window (1), the product window (2). */
export const CHAPTER_START = [0, 1320, 1530] as const;
/** A change between chapters: the old one fades out over the first half, the new one in over the second. They never overlap. */
export const CHANGE_FRAMES = 8;
export type Chapter = 0 | 1 | 2;
export type PictureLayer = { chapter: Chapter; /** frame the chapter is drawn at (the old chapter holds its last frame while it fades out) */ at: number; opacity: number };

/** The layer that is drawn at a frame: always exactly one. */
export const layerAt = (frame: number): PictureLayer => {
  let c: Chapter = 0;
  for (let i = 1; i < CHAPTER_START.length; i++) if (frame >= CHAPTER_START[i]) c = i as Chapter;
  const k = frame - CHAPTER_START[c];
  const half = CHANGE_FRAMES / 2;
  if (c > 0 && k < CHANGE_FRAMES) {
    if (k < half) return { chapter: (c - 1) as Chapter, at: CHAPTER_START[c] - 1, opacity: 1 - (k + 1) / (half + 1) };
    return { chapter: c, at: frame, opacity: (k - half + 1) / (half + 1) };
  }
  return { chapter: c, at: frame, opacity: 1 };
};

/** Every piece of fixed text drawn on the picture, for the content rules. Text typed in the demo is not copy and is listed apart. */
export const SCREEN_TEXT: readonly string[] = [
  '文字編輯', '檔案', '編輯', '格式', '顯示方式', '視窗', '輔助說明', '登入', '未命名', '帳號', '密碼',
  '報告', '文件', '打開', '取得資訊', '重新命名', '丟到垃圾桶',
  'v0.1.0 Alpha', '下載', '安裝教學', 'github.com/AnsonHui6040/Mac-keyboard', 'youtu.be/dGhEuzRpAEg',
  '傳送', '輸入草稿',
];

export const FORBIDDEN: readonly string[] = [' · ', '→', '，', ',', '零延遲', '絕對', '完全不漏字', 'Claude2'];
