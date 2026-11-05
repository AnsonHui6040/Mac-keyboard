import { Layer } from '@kinetographdev/core';
import { MacPressRing } from '../components/MacCursor.tsx';
import { fadeIn, pageAt } from '../components/PhoneScreen.tsx';
import { pulseAt, secondPeak } from './doubleClick.ts';
import { FinderPage, ReleasePage, TerminalPage } from './macPages.tsx';
import type { ScreenProps } from './registry.tsx';

/**
 * Scene 15, all on the Mac. Beat 0: the Release page. Beat 1: tap the .zip (download mark), the Terminal values with
 * green marks, then Finder where a double click on the .zip brings out the app. Beat 2: the app is dragged to 應用程式;
 * the pointer has no press there, so the icon follows `pointer` from the moment the second step starts.
 */
export const ZipFlow = ({ beatIndex, beatFrame, stepTimes, pointer }: ScreenProps) => {
  if (beatIndex === 0) return <ReleasePage row="zip" hover={0} downloaded={0} />;

  if (beatIndex === 1) {
    const page = pageAt(stepTimes, beatFrame);
    if (page === 0) {
      const land = stepTimes[0]?.land ?? Infinity;
      return <ReleasePage row="zip" hover={fadeIn(beatFrame, land - 4, 6)} downloaded={fadeIn(beatFrame, land + 4, 8)} />;
    }
    if (page === 1) return <TerminalPage kind="zip" match={fadeIn(beatFrame, stepTimes[1]?.land ?? Infinity, 10)} />;
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
  const dragging = beatFrame >= dragStart && beatFrame < drop;
  const moved = beatFrame >= drop;
  return (
    <FinderPage
      s={{
        zipSelected: 0,
        app: 1,
        ghost: beatFrame >= dragStart,
        moved,
        appsHi: moved ? 0 : fadeIn(beatFrame, dragStart + 8, 8),
        drag: dragging ? { x: pointer.x, y: pointer.y } : undefined,
      }}
    />
  );
};
