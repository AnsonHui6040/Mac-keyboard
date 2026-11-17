// Writes docs/video/promo-v0.2.srt from the narration and the timeline.
import { writeFileSync } from 'node:fs';
import { toSrt } from '../src/promo/srt.ts';

const out = new URL('../../docs/video/promo-v0.2.srt', import.meta.url);
writeFileSync(out, toSrt());
console.log(`wrote ${out.pathname}`);
