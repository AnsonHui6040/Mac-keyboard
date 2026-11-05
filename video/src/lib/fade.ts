import { FADE_FRAMES } from './sceneSpec.ts';

/**
 * Opacity of a scene's opening fade over FADE_FRAMES (8) frames: 1/8 on the scene's first frame, 1 on the eighth (frame 7).
 * Like the screen change fade, it never draws an empty frame. Adds no frames.
 */
export const openingFade = (localFrame: number): number => Math.min(1, Math.max(0, (localFrame + 1) / FADE_FRAMES));
