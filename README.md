# greytHR auto attendance

Signs you in and out of your company's greytHR on a schedule, with a small
macOS menu bar app for credentials and times.

`macos` · `menubar` · `swift` · `swiftui` · `playwright` · `launchd` · `automation` · `attendance` · `greythr`

```
menu bar app (Swift)  ──writes──▶  Keychain + config.json
                                        │
                     launchd (every 5 min) ──▶ index.js ──▶ Playwright ──▶ greytHR
```

**The app is a control panel, not the engine.** Quit it and the automation keeps running.

## Install

Needs Brave, Chrome or Edge installed — the automation drives one of those, and never
downloads a browser of its own.

From source:

```sh
npm install
./app/build.sh             # no Xcode needed, just Command Line Tools
open app/greytHR.app
```

Via Homebrew:

```sh
brew tap direwolfv/tap
brew install direwolfv/tap/greythr-swipe
ln -sfn "$(brew --prefix greythr-swipe)/greytHR.app" /Applications/greytHR.app
open /Applications/greytHR.app
```

The symlink is load-bearing: `SMAppService` registers the timer only for an app reachable
under `/Applications`, and Homebrew cannot create the link from its post-install sandbox.

First launch installs the LaunchAgent. Then **Settings…** → **Account** for the greytHR URL,
username and password, and **Schedule** for your times.

When macOS asks "security wants to access …", click **Always Allow** — otherwise the scheduled
background runs can't read the password.

**Test check-in** / **Test check-out** log in and locate the button without clicking it.

## How it works

launchd runs `index.js` every five minutes. Each tick exits immediately unless:

- it's a weekday (unless *Weekdays only* is off), **and**
- the time is at or past your check-in or check-out time, **and**
- that action hasn't already happened today

If the Mac is asleep at 09:00, the check-in happens on the first tick after it wakes. On failure
it retries every five minutes, notifying on the first failure and every fourth after that, and
leaves a screenshot in the log directory.

## Where things live

| What | Where |
|---|---|
| Worker + node_modules | inside the app: `greytHR.app/Contents/Resources/` |
| Settings, logs, state | `~/Library/Application Support/greytHR/` |
| Credentials | macOS Keychain (`greythr-username`, `greythr-password`) |
| Schedule | `~/Library/LaunchAgents/com.direwolfv.greythr-swipe.plist` |

Every setting has a control in the app. The exceptions are `geoLat` / `geoLon` in `config.json`
— set those by hand if your company captures location on swipe.

## Troubleshooting

```sh
W=app/greytHR.app/Contents/Resources/index.js   # or the installed bundle
node "$W" --what                                # in / out / nothing
node "$W" --in --dry-run --headed               # watch it log in, without clicking
tail -f ~/Library/Application\ Support/greytHR/logs/checkout.log
```

The app is ad-hoc signed, so the first launch may need right-click → **Open**.

It lives in the menu bar only — no Dock icon, no Launchpad entry, and Finder shows the
`/Applications` alias with an arrow. That is the symlink doing its job: `brew upgrade` moves
the keg and the link follows.

## Uninstall

```sh
greythr-swipe-uninstall --all                   # run this FIRST
brew uninstall direwolfv/tap/greythr-swipe
```

`brew uninstall` only removes the keg — the five-minute timer, your settings and the Keychain
items live outside it and would survive, leaving the timer firing at a script that is gone.
Without `--all` the uninstaller keeps your settings, logs and credentials. Built from source
instead? Run `app/uninstall.sh` and delete the repo.

## Unofficial

A personal tool, not affiliated with or endorsed by Greytip Software. "greytHR" is
their trademark; this project just automates a browser against their web app.
