import { test } from 'node:test';
import assert from 'node:assert/strict';
import { STATUS_CELL } from './layout.ts';
import { textWidth } from './metrics.ts';
import { statusCellLabels } from './statusCell.ts';

test('every host name fits the status cell at 22 px', () => {
  for (const name of ['Mac', 'Windows', 'Linux']) {
    assert.ok(textWidth(name, STATUS_CELL.size, 500) <= STATUS_CELL.w - 16, name);
  }
});

test('the status cell keeps the old one-line look without a host', () => {
  assert.deepEqual(statusCellLabels(undefined, 24), [{ text: '已連接', y: 24, h: 49, size: 22, color: '#30d158' }]);
  assert.deepEqual(statusCellLabels('Windows', 24), [
    { text: 'Windows', y: 24, h: 24.5, size: 22, color: '#ffffff' },
    { text: '已連接', y: 48.5, h: 24.5, size: 22, color: '#30d158' },
  ]);
});
