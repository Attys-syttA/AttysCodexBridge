# Watchdog restart-request follow-up

Date: 2026-06-10

## Symptom

After the last Telegram `/restart` on 2026-06-09, the bot did not come back up even though it was no longer running.

## Evidence

- `.telecodex/restart-request.json` was written at `2026-06-09T06:17:47.616Z` (`2026-06-09 08:17:47` local time).
- `.telecodex/process-events.jsonl` has no `launcher_started` event around that timestamp. The next launcher event in the inspected local state was on `2026-06-10T03:31:26Z`.
- `.telecodex/watchdog-events.jsonl` had no later watchdog check after `2026-06-09T03:54:17Z` in the inspected local state.
- `scripts/watchdog.ps1` currently reads `stop-request.json`, but not `restart-request.json`.
- The Telegram restart path writes `restart-request.json`, then calls `scheduleBotRestart(...)` from the live bot process. If that detached launcher spawn does not result in a real launcher start, the restart request remains only as evidence and no fallback component consumes it.

## Likely cause

The restart request file is not a watchdog queue item today. It is written by the bot, but the watchdog ignores it. Therefore, once the bot is already stopped, the stale `restart-request.json` cannot bring it back.

## Fix direction

Teach `scripts/watchdog.ps1` to consume `restart-request.json` when the tracked bot process is missing or the heartbeat is stale:

- read and validate `restart-request.json`;
- honor its `launchProfile` value when present, otherwise use `default`;
- launch `start-attyscodexbridge-workspace.ps1 -LaunchProfile <profile>`;
- write an explicit watchdog event such as `restart_request_recovered`;
- remove or mark the request after a successful launcher start so it does not loop forever;
- keep `stop-request.json` behavior higher priority, so a deliberate stop still suppresses restart.

## Work-machine checklist

After pulling this commit on the work machine:

```powershell
npm install
npm test
npm run build
.\scripts\watchdog.ps1 -StatusOnly
```

Then implement and test the watchdog-side `restart-request.json` recovery path.
