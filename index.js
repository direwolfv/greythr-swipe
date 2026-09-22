#!/usr/bin/env node
// Auto check-in / check-out for greytHR.
// Runs every 5 minutes via launchd. Each tick it decides whether anything is due
// (see decide()), and if so logs in headlessly, clicks Sign In / Sign Out once, and
// remembers it did so for the day.
//
// Settings live in config.json, written by the menu bar app. Credentials live in the
// macOS Keychain (items "greythr-username" / "greythr-password").
//
// Flags:
//   --in       sign in now, skipping the time/day/already-done guards
//   --out      sign out now, likewise
//   --force    same as --out (kept for muscle memory)
//   --dry-run  log in and locate the button, but do NOT click it
//   --headed   show the browser window (for debugging; "headless": false does it always)
//   --what     print what this tick would do ('in' / 'out' / 'nothing') and exit

// playwright-core, not playwright: it has no browser-download step at all, so an
// install can never pull the 1.3 GB browser bundle. We always drive an installed
// Chromium (Brave/Chrome/Edge) via executablePath instead.
import { chromium } from 'playwright-core';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

// Settings and logs live outside the app so an installed, read-only bundle still works.
// GREYTHR_HOME overrides the location (used by decide.test.js).
const HERE = process.env.GREYTHR_HOME
  || path.join(os.homedir(), 'Library', 'Application Support', 'greytHR');
fs.mkdirSync(HERE, { recursive: true });
const LOG_DIR = path.join(HERE, 'logs');
const CONFIG_FILE = path.join(HERE, 'config.json');
const STATE_FILE = path.join(LOG_DIR, 'state.json');
const LOG_FILE = path.join(LOG_DIR, 'checkout.log');

fs.mkdirSync(LOG_DIR, { recursive: true });

const args = new Set(process.argv.slice(2));
const FORCE = args.has('--force');
const DRY_RUN = args.has('--dry-run');
const HEADED = args.has('--headed');

const DEFAULTS = {
  checkInAt: '09:00',
  checkOutAt: '19:00',
  checkInEnabled: true,
  checkOutEnabled: true,
  baseUrl: '',         // your company's greytHR URL, set in the app
  weekdaysOnly: true,
  headless: true,
  browserPath: null,   // null = auto: the first installed Brave/Chrome/Edge
  geoLat: null,
  geoLon: null,
};

/** @param {string} file @param {any} [fallback] @returns {any} */
function readJson(file, fallback = {}) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return fallback; }
}

function ts() {
  const d = new Date();
  return d.toLocaleString('sv-SE'); // YYYY-MM-DD HH:MM:SS in local time
}

/** @param {string} msg */
function log(msg) {
  const line = `[${ts()}] ${msg}`;
  console.log(line);
  // Collapse repeats: a stuck 5-minute job would otherwise bury the log (and the app's
  // activity panel) under the same line forever. Same message as last time → rewrite that
  // line with a fresh timestamp and a count.
  // ponytail: rewrites the whole file; it stays small because of this very collapsing.
  /** @type {string[]} */
  let lines = [];
  try { lines = fs.readFileSync(LOG_FILE, 'utf8').split('\n').filter(Boolean); } catch {}
  const prev = (lines[lines.length - 1] || '').match(/^\[[^\]]+\] (.*?)(?: \(x(\d+)\))?$/);
  if (prev && prev[1] === msg) {
    lines[lines.length - 1] = `${line} (x${Number(prev[2] || 1) + 1})`;
    fs.writeFileSync(LOG_FILE, lines.join('\n') + '\n');
  } else {
    fs.appendFileSync(LOG_FILE, line + '\n');
  }
}

function today() {
  return ts().slice(0, 10);
}

/** @param {Record<string, any>} s */
function writeState(s) {
  fs.writeFileSync(STATE_FILE, JSON.stringify(s, null, 2));
}

/** @param {string} title @param {string} message */
function notify(title, message) {
  // Route through the menu bar app rather than osascript: a notification posted by
  // osascript belongs to osascript, so clicking it goes nowhere useful. `open -g` starts
  // the app in the background if it isn't running, without stealing focus.
  const url = `greythr://notify?title=${encodeURIComponent(title)}&body=${encodeURIComponent(message)}`;
  try {
    execFileSync('/usr/bin/open', ['-g', url]);
  } catch { /* notifications are best-effort */ }
}

/** @param {string} service @returns {string} */
function keychain(service) {
  try {
    return execFileSync('/usr/bin/security',
      ['find-generic-password', '-s', service, '-w'], { encoding: 'utf8' }).trim();
  } catch { return ''; }
}

// Which Chromium to drive: the configured one, else the first installed browser. There is
// no fallback — playwright-core ships no browser, so a miss has to be an error.
function browserExecutable() {
  if (cfg.browserPath && fs.existsSync(cfg.browserPath)) return cfg.browserPath;
  const found = SYSTEM_BROWSERS.find((p) => fs.existsSync(p));
  if (!found) {
    throw new Error('No Chromium browser found. Install Brave, Chrome or Edge, '
      + 'or set "browserPath" in config.json to a Chromium-based browser.');
  }
  return found;
}

/** @param {string} hhmm @returns {number} */
function minutesOfDay(hhmm) {
  const [h, m] = String(hhmm).split(':').map(Number);
  return h * 60 + m;
}

const SYSTEM_BROWSERS = [
  '/Applications/Brave Browser.app/Contents/MacOS/Brave Browser',
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
];

// ---------- what, if anything, is due right now ----------
const cfg = { ...DEFAULTS, ...readJson(CONFIG_FILE) };
// Show the browser if either the flag or the config says so.
const VISIBLE = HEADED || cfg.headless === false;
const state = readJson(STATE_FILE);
// GREYTHR_NOW pins the moment decide() judges, so the weekday/weekend branch is
// testable on any day (see decide.test.js). Log timestamps stay on the real clock.
const now = process.env.GREYTHR_NOW ? new Date(process.env.GREYTHR_NOW) : new Date();

// Per-action wiring, so the rest of the script never branches on the action again.
const ACTIONS = {
  in: { verb: 'Sign In', word: /sign\s*in/i, stateKey: 'lastCheckinDate',
        at: cfg.checkInAt, enabled: cfg.checkInEnabled, shot: 'checkin', past: 'Checked in' },
  out: { verb: 'Sign Out', word: /sign\s*out/i, stateKey: 'lastCheckoutDate',
         at: cfg.checkOutAt, enabled: cfg.checkOutEnabled, shot: 'checkout', past: 'Checked out' },
};

/** @returns {'in' | 'out' | null} */
function decide() {
  const day = now.getDay(); // 0 = Sunday, 6 = Saturday
  if (cfg.weekdaysOnly && (day === 0 || day === 6)) return null;

  const nowMin = now.getHours() * 60 + now.getMinutes();
  // ponytail: check-in is tested first, so a Mac woken long after both times signs in on
  // this tick and out on the next (5 min later). Split into two launchd jobs if that
  // ever matters.
  for (const name of /** @type {const} */ (['in', 'out'])) {
    const a = ACTIONS[name];
    if (a.enabled && nowMin >= minutesOfDay(a.at) && state[a.stateKey] !== today()) return name;
  }
  return null;
}

const name = args.has('--in') ? 'in'
  : args.has('--out') || FORCE ? 'out'
  : decide();

if (args.has('--what')) { // what would this tick do? (no login, no browser)
  console.log(name || 'nothing');
  process.exit(0);
}

if (!name) process.exit(0); // silent: keeps the 5-minute ticks out of the log

const action = ACTIONS[name];

// ---------- credentials ----------
const USERNAME = keychain('greythr-username');
const PASSWORD = keychain('greythr-password');

if (!USERNAME || !PASSWORD) {
  log('ERROR: credentials not found. Open the greytHR menu bar app and save them.');
  notify('greytHR failed', 'Credentials not set — open the greytHR menu bar app');
  process.exit(1);
}

// ---------- the greytHR URL ----------
const BASE_URL = String(cfg.baseUrl || '').trim().replace(/\/+$/, '')
  .replace(/^(?!https?:\/\/)/, 'https://');

if (BASE_URL === 'https://') {
  log('ERROR: greytHR URL not set. Open the app and enter it on the Account tab.');
  notify('greytHR failed', 'greytHR URL not set — open the app');
  process.exit(1);
}

// ---------- pick the browser (before launching, so a miss is a clean message) ----------
let executablePath;
try {
  executablePath = browserExecutable();
} catch (err) {
  const msg = err instanceof Error ? err.message : String(err);
  log(`ERROR: ${msg}`);
  notify('greytHR failed', msg);
  process.exit(1);
}

// ---------- do it ----------
// slowMo when visible: at full speed the whole run is over in ~10 seconds and there is
// nothing to watch, which defeats the point of turning headless off.
const browser = await chromium.launch({
  headless: !VISIBLE,
  slowMo: VISIBLE ? 300 : 0,
  // Brave/Chrome/Edge are all Chromium, so Playwright can drive them directly. It always
  // uses a fresh temporary profile — your real Brave profile, logins and extensions are
  // untouched (and an already-running Brave doesn't get in the way).
  executablePath,
});
try {
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 900 } });

  if (cfg.geoLat != null && cfg.geoLon != null) {
    await ctx.grantPermissions(['geolocation'], { origin: BASE_URL });
    await ctx.setGeolocation({ latitude: Number(cfg.geoLat), longitude: Number(cfg.geoLon) });
  }

  const page = await ctx.newPage();
  if (VISIBLE) await page.bringToFront(); // otherwise it opens behind everything
  log(`Opening ${BASE_URL} for ${action.verb} ...`);
  await page.goto(BASE_URL, { waitUntil: 'domcontentloaded', timeout: 60000 });

  const userField = page
    .locator('#username, input[name="username"], input[formcontrolname="username"]')
    .first();
  const onLoginPage = await userField
    .waitFor({ state: 'visible', timeout: 20000 })
    .then(() => true)
    .catch(() => false);

  if (onLoginPage) {
    await userField.fill(USERNAME);
    await page.locator('#password, input[type="password"]').first().fill(PASSWORD);
    await page
      .locator('button[type="submit"], button:has-text("Log in"), button:has-text("Login")')
      .first()
      .click();
    log('Submitted login form.');
  } else {
    log('Login form not shown; assuming an active session.');
  }

  // Wait for the dashboard attendance widget and find the Sign In / Sign Out button.
  // greytHR's widget shows one or the other, so seeing the OPPOSITE button means the
  // action already happened — that is "nothing to do", not a failure. Seeing neither
  // is the real error (page never loaded, layout changed, login silently failed).
  const other = ACTIONS[name === 'in' ? 'out' : 'in'];
  /** @param {RegExp} word @param {string} key */
  const candidatesFor = (word, key) => [
    page.getByRole('button', { name: word }),
    page.locator('gt-button', { hasText: word }),
    page.getByText(new RegExp(`^\\s*sign\\s*${key}\\s*$`, 'i')),
  ];
  /** @param {import('playwright-core').Locator[]} list */
  const firstVisible = async (list) => {
    for (const c of list) {
      if (await c.first().isVisible().catch(() => false)) return c.first();
    }
    return null;
  };

  let button = null;
  let alreadyDone = false;
  const deadline = Date.now() + 60000;
  // Give the wanted button a head start before concluding "already done" — the widget
  // can render the other state for a moment while it settles.
  const graceUntil = Date.now() + 10000;
  while (!button && !alreadyDone && Date.now() < deadline) {
    if (!page.url().includes('/auth/login')) {
      button = await firstVisible(candidatesFor(action.word, name));
      if (!button && Date.now() > graceUntil) {
        alreadyDone = (await firstVisible(candidatesFor(other.word, name === 'in' ? 'out' : 'in'))) !== null;
      }
    }
    if (!button && !alreadyDone) await page.waitForTimeout(1000);
  }

  if (alreadyDone) {
    // Record it so the 5-minute ticks stop retrying for the rest of the day.
    if (!DRY_RUN) {
      state[action.stateKey] = today();
      delete state.failures;
      writeState(state);
    }
    const msg = `Already ${action.past.toLowerCase()} — greytHR is showing "${other.verb}".`;
    log(msg);
    notify('greytHR', `Already ${action.past.toLowerCase()} today`);
  } else if (!button) {
    const shot = path.join(LOG_DIR, `fail-${today()}.png`);
    await page.screenshot({ path: shot, fullPage: true }).catch(() => {});
    const stuckOnLogin = page.url().includes('/auth/login');
    throw new Error(
      stuckOnLogin
        ? `Login did not succeed — wrong credentials, or a captcha/OTP is required. Screenshot: ${shot}`
        : `Logged in, but neither a "Sign In" nor a "Sign Out" button was on the page. Screenshot: ${shot}`,
    );
  } else if (DRY_RUN) {
    log(`DRY RUN: logged in and found the ${action.verb} button — not clicking it.`);
    if (VISIBLE) await page.waitForTimeout(8000);
  } else {
    await button.click();
    log(`Clicked ${action.verb}.`);

    // Some greytHR setups pop a confirmation/remarks dialog — accept it if one appears.
    const dialogConfirm = page
      .locator('[role="dialog"], .modal, .popup, gt-popup-modal, .cdk-overlay-container')
      .getByRole('button', { name: /confirm|yes|^ok(ay)?$|proceed|submit|sign\s*(in|out)/i })
      .first();
    const hasDialog = await dialogConfirm
      .waitFor({ state: 'visible', timeout: 4000 })
      .then(() => true)
      .catch(() => false);
    if (hasDialog) {
      await dialogConfirm.click();
      log('Accepted the confirmation dialog.');
    }

    await page.waitForTimeout(VISIBLE ? 8000 : 4000);
    const shot = path.join(LOG_DIR, `${action.shot}-${today()}.png`);
    await page.screenshot({ path: shot }).catch(() => {});

    state[action.stateKey] = today();
    delete state.failures;
    writeState(state);

    const t = new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    log(`${action.past} at ${t}. Screenshot: ${shot}`);
    notify('greytHR', `${action.past} at ${t}`);
  }
} catch (err) {
  const f = state.failures?.date === today() ? state.failures : { date: today(), count: 0 };
  f.count += 1;
  state.failures = f;
  writeState(state);
  const msg = err instanceof Error ? err.message : String(err);
  log(`ERROR (attempt ${f.count} today): ${msg}`);
  // Notify on the first failure, then every 4th, so 5-minute retries don't spam.
  if (f.count === 1 || f.count % 4 === 0) {
    notify('greytHR failed', msg.slice(0, 120));
  }
  process.exitCode = 1;
} finally {
  await browser.close();
}
