/** The narration of the v0.2 promo. The one source of captions (SRT) and of the text sent to the voice. Pure data. */
export type LineId = '01' | '02' | '03' | '04' | '05' | '06' | '07' | '08' | '09' | '10';
export type SegId = '1' | '2' | '3' | '4' | '5' | '6' | '7' | '8' | '9' | '10';
export type NarrationLine = { id: LineId; seg: SegId; caption: string; spoken: string };

const same = (id: LineId, seg: SegId, caption: string): NarrationLine => ({ id, seg, caption, spoken: caption });

export const NARRATION: readonly NarrationLine[] = [
  same('01', '1', '一支 iPhone，可以打字到三部電腦。'),
  same('02', '2', '先打到 Mac。即時模式每按一個鍵就送出；草稿模式可以先改好錯字，再一次傳送。'),
  same('03', '3', '點一下，換到 Windows。'),
  same('04', '4', '中文可以直接手寫，選好字按傳送，記事本就出現剛寫好的字。'),
  same('05', '5', '再點一下，換到 Linux。'),
  same('06', '6', '習慣速成的話，可以在 App 裡改用速成輸入，一樣打得出中文。'),
  same('07', '7', '再點一下，回到 Mac。'),
  same('08', '8', '鍵盤還能變成觸控板：一指移動游標，輕點就是點按，按住可以拖曳，兩指輕點是右鍵，兩指滑動來捲動。'),
  same('09', '9', '這就是 Remote Keyboard。'),
  {
    id: '10',
    seg: '10',
    caption: '目前是 v0.2 Alpha 版，透過 SideStore 安裝。下載連結在說明欄。',
    spoken: '目前是零點二 Alpha 版，透過 SideStore 安裝。下載連結在說明欄。',
  },
];
