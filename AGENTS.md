# Working on Work from a List

Work from a List is a floating macOS to-do list for one day. It's one Swift file
(`main.swift`, AppKit + SwiftUI, no packages, no Xcode project) built with `swiftc`.
These notes are for anyone changing the code, people and AI coding agents alike.

## How changes land

The app is public and people install `main` directly, so `main` must always work.
Never commit to `main`. Make a branch, open a pull request, and merge only after
CI passes and the change was tried in the real app. Keep each pull request to
one change, and keep saved files compatible (an older or newer version must
still read them).

## Build and check

```sh
./build.sh                                            # builds "Work from a List.app" here
"Work from a List.app/Contents/MacOS/WorkFromAList" --test        # logic checks, no window; exit 1 on failure
"Work from a List.app/Contents/MacOS/WorkFromAList" --print       # prints today's list
./install.sh                                          # build, install to ~/Applications, (re)start
```

Every change must build with no warnings and pass `--test`. CI runs both on
every pull request (`.github/workflows/ci.yml`). When you change logic that
`--test` could cover (the day reset, carry-over, reading files, mantra order),
add a check next to the others at the bottom of `main.swift`.

## Where things are in main.swift

| Section | What's there |
|---|---|
| `Storage` | `Item`, `Store` (today.json, the morning reset, carry-over), `FileWatcher`, `Mantras` (mantras.txt, which one shows when) |
| `Model` | `TodayModel`: the list, the "now" pin, urgent, undo, drag order, header text, mantras. Views never change state directly |
| `Views` | `TodayView` (the card), `ItemRow`, `UndoRow`, `AddField`, `MantraManager` (the Mantras & Header window), `Theme` |
| `Panel & app` | `HUDPanel` (never-focused floating panel; holds clicks on rows to tell a click from a drag), `HUDHostingView` (move, resize), `AppDelegate` (menu bar, hotkey, wake/screen changes) |
| `Entry` | `--test`, `--print`, single instance, launch |

## Rules the app depends on

- **Stays light.** Nothing ticks. No repeating timers and no endless
  animations: the app sleeps until you touch it, plus one timer for the morning
  reset and one for each mantra change. Idle CPU must stay ~0%. A continuous
  animation costs real CPU in a SwiftUI panel, so animations run once and finish.
- **Never steals focus.** The panel is non-activating. It takes the keyboard only
  while you type in it (`allowKey`) and hands it back on Return or Esc.
- **Your data is plain files.** `~/Library/Application Support/WorkFromAList/today.json`
  and `mantras.txt`. Other apps may write them at any time; `FileWatcher` reloads.
  Keep the JSON readable by older versions: new fields must be optional
  (`decodeIfPresent`). Never lose a list: a file that won't decode is ignored, not
  replaced with an empty one.
- **The day turns at `resetHour` (5 am)**, by the clock hour, so daylight saving
  days work. Done tasks clear; open and urgent ones carry over; the pin clears.
- **Small on purpose.** At most 25 tasks, 3 urgent, one "now". Every feature must
  keep the card calm and readable at a glance. Ask before adding settings.
- **Looks like the code around it.** Short comments that say why, names a reader
  can guess, text written for the user (no jargon in the UI or README).

## Trying a change safely

`./install.sh` replaces the running HUD, and it uses your real list. To test on a
throwaway list, back it up first:

```sh
cp ~/Library/Application\ Support/WorkFromAList/today.json /tmp/today-backup.json
# … test …
cp /tmp/today-backup.json ~/Library/Application\ Support/WorkFromAList/today.json
```

Or point a run at a fake home, which leaves your files alone (quit the installed
HUD first, since only one copy runs):
`CFFIXED_USER_HOME=/tmp/fakehome "Work from a List.app/Contents/MacOS/WorkFromAList"`.

For anything visible, take a screenshot (`screencapture -x shot.png`) and look at
it; describe what you checked in the pull request.

## Releases

Push a tag like `v1.0`. CI builds the universal app with `release.sh`, runs the
checks and publishes `Work-from-a-List.zip` on the release, which `get.sh` installs.
