/** The status cell of the phone's toolbar as text lines. Pure numbers and strings: node can import this. */
import { STATUS_CELL } from './layout.ts';

export type StatusLabel = { text: string; y: number; h: number; size: number; color: string };

const WHITE = '#ffffff';
const GREEN = '#30d158';

/** One line "已連接" the height of the cell without a host (the look of the old films); with a host, its name above "已連接", half the cell each. */
export const statusCellLabels = (host: string | undefined, toolbarY: number): StatusLabel[] => {
  const { h, size } = STATUS_CELL;
  if (host === undefined) return [{ text: '已連接', y: toolbarY, h, size, color: GREEN }];
  return [
    { text: host, y: toolbarY, h: h / 2, size, color: WHITE },
    { text: '已連接', y: toolbarY + h / 2, h: h / 2, size, color: GREEN },
  ];
};
