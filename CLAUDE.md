# greythr-swipe

**This repo is public.** A personal macOS tool: a launchd job runs `index.js`, which drives an
installed Chromium via playwright-core to sign in/out of greytHR. `app/` is a SwiftUI menu bar
app that writes the config and owns the credentials — it is a control panel, not the engine.

## Never commit

- **The employer's greytHR tenant hostname.** `baseUrl` is config-only: it defaults to `""` in
  `index.js` DEFAULTS and is typed into the app's Account tab. A real tenant was hardcoded once
  and had to be purged from every commit and blob. Use `yourcompany.greythr.com` in code,
  comments, README and fixtures.
- **Credentials.** They live only in the macOS Keychain (`greythr-username`, `greythr-password`),
  read at runtime with `/usr/bin/security`. Nothing may write them to a file.
- **Real logs, screenshots, config.** The runtime writes to
  `~/Library/Application Support/greytHR/`, never into the repo. `config.json` and `logs/` stay
  in `.gitignore`; login-failure screenshots can show the username field filled in.

## Before commit and push

```sh
brew install gitleaks   # prerequisite: not an npm dependency, so `npm run scan`
                        # fails with "command not found" without it
npm run scan            # gitleaks over the working tree
npm run scan:history    # gitleaks over every commit — run before the first push
```

Config is `.gitleaks.toml`. **The default ruleset would not have caught this project's only real
leak** — it finds API keys and tokens, and the tenant hostname is neither. The `greythr-tenant`
rule is what does, with `yourcompany.greythr.com` allowlisted as the one permitted spelling.

Scan the working tree *and* the history. After a history rewrite the index can still hold the old
blobs, which a bare `git commit` would put straight back.

## Commit messages

A one-line subject, a blank line, then **bullet points only — at most 10**. No paragraphs, no
trailers.

```
Ship the menu bar app and Homebrew formula

- Move settings and logs to ~/Library/Application Support/greytHR
- Resolve node at run time so nvm upgrades cannot break the LaunchAgent
- Prune devDependencies from the bundle; it shipped 34 MB of compiler
- Add decide.test.js covering the weekend guard on any day of the week
```

More than 10 changes means grouping them, not a longer list. Drop the noise — a rename or a
version bump does not need its own bullet if it came along with the change above it.

## Gate

```sh
npm test            # decide.test.js — 12 cases, the scheduling logic
npm run typecheck   # tsc --noEmit over the JSDoc types; no build step, no emit
./app/build.sh      # builds app/greytHR.app; needs node on PATH and `npm install` first
```

`build.sh` copies `node_modules` wholesale then prunes to what `package.json` lists under
`dependencies` — a source install runs plain `npm install`, so devDependencies would otherwise
ship inside the app (that mistake took the bundle from 6.9M to 41M).

## Conventions

- `index.js` is ESM. The repo has `"type": "module"`, and `build.sh` writes a one-line
  `package.json` into the bundle so the shipped copy is explicit rather than relying on Node's
  syntax detection, which only exists from 20.19.
- `run.sh` resolves node at run time (`NODE_BIN`, then config `nodePath`, then Homebrew, then the
  newest nvm, then `PATH`). launchd gives the job almost no `PATH`, and baking an absolute path
  breaks on the next `nvm install`. Keep that lookup in `run.sh` only — the app's Test button
  calls `run.sh --print-node` rather than reimplementing it.
- The Homebrew formula is not in this repo — it lives in the tap `direwolfv/homebrew-tap`,
  because Homebrew only loads formulae from a tap. Keeping a copy here made its sha256 chase
  its own tarball. After tagging a release, update the url and sha256 there.

