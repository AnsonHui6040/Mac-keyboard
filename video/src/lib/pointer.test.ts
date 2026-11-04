import { test } from 'node:test';
import assert from 'node:assert/strict';
import { pointerAt } from './pointer.ts';

const FPS = 30;
const near = (a: number, b: number, eps = 1e-9) => assert.ok(Math.abs(a - b) <= eps, `${a} vs ${b}`);

const click = [{ from: 30, x: 100, y: 200, press: true }];

test('hidden before the first cue, visible from it', () => {
  assert.equal(pointerAt(0, click, FPS).visible, false);
  assert.equal(pointerAt(29, click, FPS).visible, false);
  assert.equal(pointerAt(30, click, FPS).visible, true);
  assert.equal(pointerAt(0, [], FPS).visible, false);
});

test('first cue appears at its target and stays there', () => {
  const s = pointerAt(30, click, FPS);
  near(s.x, 100);
  near(s.y, 200);
  near(pointerAt(500, click, FPS).x, 100);
});

const two = [
  { from: 0, x: 0, y: 0, press: false },
  { from: 60, x: 300, y: 150, press: true },
];

test('arrives 18 frames after from, exactly on target', () => {
  const mid = pointerAt(60 + 9, two, FPS);
  assert.ok(mid.x > 0 && mid.x < 300);
  const done = pointerAt(60 + 18, two, FPS);
  assert.equal(done.x, 300);
  assert.equal(done.y, 150);
  assert.equal(pointerAt(60 + 17, two, FPS).x < 300, true);
});

test('movement is ease-out cubic: fast start, monotonic, more than linear at halfway', () => {
  let last = -1;
  for (let f = 60; f <= 78; f++) {
    const x = pointerAt(f, two, FPS).x;
    assert.ok(x >= last);
    last = x;
  }
  const half = pointerAt(69, two, FPS).x;
  near(half, 300 * (1 - Math.pow(0.5, 3)));
  assert.ok(half > 150);
});

test('press stays 0 for 15 frames after arrival, then pulses to 1 and back to 0 within 8 frames', () => {
  const arrive = 60 + 18;
  for (let f = 60; f < arrive + 15; f++) assert.equal(pointerAt(f, two, FPS).press, 0, `frame ${f}`);
  const vals: number[] = [];
  for (let f = arrive + 15; f <= arrive + 15 + 8; f++) vals.push(pointerAt(f, two, FPS).press);
  assert.equal(vals[0], 0);
  assert.equal(Math.max(...vals), 1);
  assert.equal(vals[vals.length - 1], 0);
  assert.ok(vals.every((v) => v >= 0 && v <= 1));
  assert.equal(pointerAt(arrive + 15 + 9, two, FPS).press, 0);
  assert.equal(pointerAt(1000, two, FPS).press, 0);
});

test('press false is always 0', () => {
  for (let f = 0; f < 200; f++) assert.equal(pointerAt(f, [{ from: 10, x: 5, y: 5, press: false }], FPS).press, 0);
  for (let f = 0; f < 60; f++) assert.equal(pointerAt(f, two, FPS).press, 0);
});

test('next cue starts from the current position, including mid-flight', () => {
  const cues = [
    { from: 0, x: 0, y: 0, press: false },
    { from: 30, x: 100, y: 0, press: false },
    { from: 39, x: 0, y: 100, press: false }, // interrupts the second cue halfway
  ];
  const at39 = pointerAt(39, cues, FPS);
  near(at39.x, 100 * (1 - Math.pow(0.5, 3)));
  near(at39.y, 0);
  const after = pointerAt(39 + 9, cues, FPS);
  // halfway between the interrupted position and the third target
  near(after.x, at39.x + (0 - at39.x) * (1 - Math.pow(0.5, 3)));
  near(after.y, 100 * (1 - Math.pow(0.5, 3)));
  assert.equal(pointerAt(39 + 18, cues, FPS).x, 0);
  assert.equal(pointerAt(39 + 18, cues, FPS).y, 100);
});

test('next cue after a completed one starts from the previous target', () => {
  const cues = [
    { from: 0, x: 0, y: 0, press: false },
    { from: 30, x: 100, y: 0, press: true },
    { from: 200, x: 100, y: 80, press: false },
  ];
  near(pointerAt(200, cues, FPS).x, 100);
  near(pointerAt(200, cues, FPS).y, 0);
  near(pointerAt(209, cues, FPS).y, 80 * (1 - Math.pow(0.5, 3)));
  assert.equal(pointerAt(218, cues, FPS).y, 80);
  assert.equal(pointerAt(200, cues, FPS).press, 0);
});
