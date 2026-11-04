/** Every registered scene, with the script entry that gives its caption and length. */
import script from '../script.json' with { type: 'json' };
import { compileScene, type CompiledScene, type SceneSpec } from '../../lib/sceneSpec.ts';
import { scene01 } from './scene01.ts';
import { scene02 } from './scene02.ts';
import { scene03 } from './scene03.ts';
import { scene04 } from './scene04.ts';
import { scene05 } from './scene05.ts';
import { scene06 } from './scene06.ts';
import { scene07 } from './scene07.ts';
import { scene08 } from './scene08.ts';
import { scene09 } from './scene09.ts';
import { scene16 } from './scene16.ts';

export const FPS = 30;
export const WIDTH = 1920;
export const HEIGHT = 1080;

export const SCENES: SceneSpec[] = [scene01, scene02, scene03, scene04, scene05, scene06, scene07, scene08, scene09, scene16];

export const sceneEntry = (n: number): { n: number; seconds: number; caption: string } => {
  const entry = script.scenes.find((s) => s.n === n);
  if (!entry) throw new Error(`script.json has no scene ${n}`);
  return entry;
};

export const sceneFrames = (n: number): number => sceneEntry(n).seconds * FPS;

export const compileRegistered = (spec: SceneSpec): CompiledScene => {
  const entry = sceneEntry(spec.n);
  return compileScene(spec, entry.caption, entry.seconds, FPS);
};

/** Composition id of a scene: Scene16. */
export const sceneId = (n: number): string => `Scene${String(n).padStart(2, '0')}`;
