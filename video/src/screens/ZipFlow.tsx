import { Layer } from '@kinetographdev/core';
import { MacPressRing } from '../components/MacCursor.tsx';
import { fadeIn } from '../components/PhoneScreen.tsx';
import { ZIP_NAME } from '../data/artifacts.ts';
import { pulseAt, secondPeak } from './doubleClick.ts';
import { FinderPage, ReleasePage, TerminalPage } from './macPages.tsx';
import { commandText, matchAt } from './terminal.ts';
import type { ScreenProps } from './registry.tsx';

/** Frames after the second click until the app has bounced once (it is opening). */
export const OPEN_BOUNCE = 14;

/**
 * Scene 15, all on the Mac.
 * Beat 0: the Release page. Beat 1, three steps: press the .zip row (download mark); the 終端機 page from the second step's start
 * (the command is typed, the value shows, green marks); Finder from the third step's start, where a double click on the .zip brings out the app.
 * Beat 2, four steps: the app is dragged to 應用程式 (steps 0 and 1 have no press, so the icon follows `pointer` from the start of step 1
 * and is dropped when it lands); a click on 應用程式 opens the folder (step 2); a double click on Remote Keyboard Receiver there (step 3).
 */
export const ZipFlow = ({ beatIndex, beatFrame, stepTimes, pointer }: ScreenProps) => {
  if (beatIndex === 0) return <ReleasePage row="zip" hover={0} downloaded={0} />;

  if (beatIndex === 1) {
    const terminalAt = stepTimes[1]?.start ?? Infinity;
    const finderAt = stepTimes[2]?.start ?? Infinity;
    if (beatFrame < terminalAt) {
      const land = stepTimes[0]?.land ?? Infinity;
      return <ReleasePage row="zip" hover={fadeIn(beatFrame, land - 4, 6)} downloaded={fadeIn(beatFrame, land + 4, 8)} />;
    }
    if (beatFrame < finderAt) {
      const page = beatFrame - terminalAt;
      const at = matchAt(commandText(ZIP_NAME).length, (stepTimes[1]?.land ?? Infinity) - terminalAt);
      return <TerminalPage kind="zip" pageFrame={page} match={fadeIn(page, at, 10)} />;
    }
    // 連按兩下: the step's own press is the first click; the second ring is drawn here, 10 frames later, and the app comes out after it.
    const land = stepTimes[2]?.land ?? Infinity;
    const second = secondPeak(land);
    return (
      <Layer>
        <FinderPage s={{ zipSelected: fadeIn(beatFrame, land - 4, 4), app: fadeIn(beatFrame, second, 6), ghost: false, moved: false, appsHi: 0 }} />
        <Layer id="second-click" x={pointer.x} y={pointer.y}>
          <MacPressRing press={pulseAt(beatFrame, second)} />
        </Layer>
      </Layer>
    );
  }

  const dragStart = stepTimes[1]?.start ?? Infinity;
  const drop = stepTimes[1]?.land ?? Infinity;
  const openFolder = (stepTimes[2]?.land ?? Infinity) + 4;
  if (beatFrame >= openFolder) {
    // 應用程式 is open: the second click of the double click on the app is drawn here, like the one on the .zip.
    const land = stepTimes[3]?.land ?? Infinity;
    const second = secondPeak(land);
    return (
      <Layer>
        <FinderPage s={{ folder: 'apps', zipSelected: 0, app: 1, ghost: false, moved: true, appsHi: 1, rkSelected: fadeIn(beatFrame, land - 4, 4), rkOpen: (beatFrame - second) / OPEN_BOUNCE }} />
        <Layer id="second-click" x={pointer.x} y={pointer.y}>
          <MacPressRing press={pulseAt(beatFrame, second)} />
        </Layer>
      </Layer>
    );
  }
  const dragging = beatFrame >= dragStart && beatFrame < drop;
  const moved = beatFrame >= drop;
  return (
    <FinderPage
      s={{
        zipSelected: 0,
        app: 1,
        ghost: beatFrame >= dragStart,
        moved,
        appsHi: moved ? fadeIn(beatFrame, (stepTimes[2]?.land ?? Infinity) - 2, 4) : fadeIn(beatFrame, dragStart + 8, 8),
        drag: dragging ? { x: pointer.x, y: pointer.y } : undefined,
      }}
    />
  );
};
