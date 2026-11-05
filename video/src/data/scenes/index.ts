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
import { scene10 } from './scene10.ts';
import { scene11 } from './scene11.ts';
import { scene12 } from './scene12.ts';
import { scene13 } from './scene13.ts';
import { scene14 } from './scene14.ts';
import { scene15 } from './scene15.ts';
import { scene16 } from './scene16.ts';
import { scene17 } from './scene17.ts';
import { scene18 } from './scene18.ts';
import { scene19 } from './scene19.ts';
import { scene20 } from './scene20.ts';
import { scene21 } from './scene21.ts';

export const FPS = 30;
export const WIDTH = 1920;
export const HEIGHT = 1080;

export const SCENES: SceneSpec[] = [scene01, scene02, scene03, scene04, scene05, scene06, scene07, scene08, scene09, scene10, scene11, scene12, scene13, scene14, scene15, scene16, scene17, scene18, scene19, scene20, scene21];

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
