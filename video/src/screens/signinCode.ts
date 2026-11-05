/** Scene 5 beat 3: the verification code is typed into the iloader sheet one digit at a time. Pure frame maths. */
export const CODE_LENGTH = 6;
/** Frames after the pointer is on the field until the first digit shows. */
export const CODE_START = 6;
/** Frames between two digits. */
export const CODE_PITCH = 7;

/** How many digits are on screen `sinceLand` frames after the pointer landed on the field. */
export const typedDigits = (sinceLand: number): number => (sinceLand < CODE_START ? 0 : Math.min(CODE_LENGTH, Math.floor((sinceLand - CODE_START) / CODE_PITCH) + 1));
