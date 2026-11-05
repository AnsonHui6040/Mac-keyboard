/** Scenes 10 and 15: when the command is typed in 終端機 and its output appears. Pure frame maths, counted from the frame the terminal page opens. */
export const PROMPT = '~/Downloads % ';
/** Frames the empty prompt shows before the first character. */
export const TYPE_START = 8;
/** Characters typed per frame. */
export const TYPE_RATE = 2;
/** Frames between the last character and the output (the Return key). */
export const ENTER_FRAMES = 4;
/** Frames after the output before the green marks that say the two values are equal. */
export const MATCH_DELAY = 8;

export const commandText = (fileName: string): string => `shasum -a 256 ${fileName}`;

/** How many characters of the command are on screen `pageFrame` frames after the page opened. */
export const typedChars = (pageFrame: number, total: number): number => Math.min(total, Math.max(0, Math.floor((pageFrame - TYPE_START) * TYPE_RATE)));

/** The frame (since the page opened) at which the shasum output shows. */
export const outputAt = (total: number): number => TYPE_START + Math.ceil(total / TYPE_RATE) + ENTER_FRAMES;

/** The frame (since the page opened) at which the green marks start to fade in, never before the pointer is on the hash. */
export const matchAt = (total: number, pointerLand: number): number => Math.max(outputAt(total) + MATCH_DELAY, pointerLand);
