/** Scene 20's last beat: the sentence typed on the iPhone (fictional) and when its letters come. */
export const TYPED_20 = 'Hello from my iPhone';
/** Frames into the last beat when 已連接 turns green, when the first letter appears, and frames per letter. */
export const CONNECT_AT = 10;
export const TYPE20_START = 24;
export const TYPE20_PITCH = 5;

/** How many letters are on the Mac `beatFrame` frames into the last beat. */
export const typed20 = (beatFrame: number): number =>
  beatFrame < TYPE20_START ? 0 : Math.min(TYPED_20.length, Math.floor((beatFrame - TYPE20_START) / TYPE20_PITCH) + 1);
