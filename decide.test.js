#!/usr/bin/env node
// Self-check for the "what is due right now" logic in index.js — the one piece that
// decides whether you get checked in at all. Runs the real script with --what against a
// throwaway GREYTHR_HOME, so no browser, no Keychain, no touching the real config.
//
//   node decide.test.js

import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'greythr-test-'));
fs.mkdirSync(path.join(HOME, 'logs'));

const now = new Date();
const TODAY = now.toLocaleString('sv-SE').slice(0, 10);
const WEEKEND = now.getDay() === 0 || now.getDay() === 6;
/** @param {number} offsetMin */
const hhmm = (offsetMin) => {
  const d = new Date(now.getTime() + offsetMin * 60000);
  return `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`;
};
const PASSED = hhmm(-60);
const LATER = hhmm(+60);

/** @param {Record<string, any>} config @param {Record<string, any>} [state] @param {string} [fakeNow] */
function decide(config, state = {}, fakeNow) {
  fs.writeFileSync(path.join(HOME, 'config.json'), JSON.stringify(config));
  fs.writeFileSync(path.join(HOME, 'logs', 'state.json'), JSON.stringify(state));
  return execFileSync('node', ['index.js', '--what'], {
    encoding: 'utf8',
    env: { ...process.env, GREYTHR_HOME: HOME, ...(fakeNow ? { GREYTHR_NOW: fakeNow } : {}) },
  }).trim();
}

const base = {
  checkInAt: PASSED, checkOutAt: PASSED,
  checkInEnabled: true, checkOutEnabled: true, weekdaysOnly: false,
};

/** @type {[label: string, config: Record<string, any>, state: Record<string, any>, expected: string, fakeNow?: string][]} */
const cases = [
  ['both due, nothing done yet → check in first', base, {}, 'in'],
  ['already checked in today → check out', base, { lastCheckinDate: TODAY }, 'out'],
  ['both done today → nothing',
    base, { lastCheckinDate: TODAY, lastCheckoutDate: TODAY }, 'nothing'],
  ['neither time reached → nothing',
    { ...base, checkInAt: LATER, checkOutAt: LATER }, {}, 'nothing'],
  ['check-in disabled → check out', { ...base, checkInEnabled: false }, {}, 'out'],
  ['check-out time not reached yet, check-in done → nothing',
    { ...base, checkOutAt: LATER }, { lastCheckinDate: TODAY }, 'nothing'],
  [`weekdaysOnly on a ${WEEKEND ? 'weekend' : 'weekday'}`,
    { ...base, weekdaysOnly: true }, {}, WEEKEND ? 'nothing' : 'in'],
  ['missing config falls back to defaults (19:00 check-out, 09:00 check-in)',
    {}, { lastCheckinDate: TODAY, lastCheckoutDate: TODAY }, 'nothing'],
];

// Weekends, pinned to real dates so both branches run whatever day the suite runs on.
// Times are 09:00/19:00 and the clock is 23:00, so only the day-of-week can block these.
const allDay = { ...base, checkInAt: '09:00', checkOutAt: '19:00', weekdaysOnly: true };
cases.push(
  ['Saturday blocked', allDay, {}, 'nothing', '2026-09-19T23:00:00'],
  ['Sunday blocked', allDay, {}, 'nothing', '2026-09-20T23:00:00'],
  ['Monday allowed (proves the guard is day-specific)', allDay, {}, 'in', '2026-09-21T23:00:00'],
  ['Saturday with weekdaysOnly off still acts',
    { ...allDay, weekdaysOnly: false }, {}, 'in', '2026-09-19T23:00:00'],
);

let failed = 0;
for (const [label, config, state, expected, fakeNow] of cases) {
  const got = decide(config, state, fakeNow);
  const ok = got === expected;
  if (!ok) failed++;
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${label} → ${got}${ok ? '' : ` (expected ${expected})`}`);
}

fs.rmSync(HOME, { recursive: true, force: true });
assert.equal(failed, 0, `${failed} case(s) failed`);
console.log(`\n${cases.length} passed`);
