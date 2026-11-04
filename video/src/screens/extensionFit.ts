/** Label sizes of the App Contains Extensions dialog (pure numbers, so tests can import them). */

/** Width of the label in em at weight 500 (measured with kinetograph inspect at size 40 and divided by 40). */
export const EM = { keepMain: 18.47, keepEach: 26.95 } as const;
/** Room for a label inside its 354 wide row: 8 px each side. */
export const ROOM = 338;
export const FULL = 28;

/** The size that makes a label of `em` width fit on one line, at most the normal size. */
export const fitSize = (em: number): number => Math.min(FULL, Math.floor((ROOM / em) * 10) / 10);
