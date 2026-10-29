# Work from a List

A small floating list of what you're working on today. It sits above every
app without taking focus, keeps up to 25 tasks, and clears what you finished each morning.

It looks like a ruled notebook page by default: white paper, dark ink, faint
blue lines under each task, and a red margin. Right-click → Color, or menu bar
→ Color, switches to a solid Teal, Midnight, Indigo, Forest, Plum or Graphite
card with white text. Every theme is opaque, so the list stands out and reads
the same on any wallpaper, in light or dark mode.

## Install

You need macOS 13 (Ventura) or later, on Apple silicon or Intel. Paste this into
Terminal:

```sh
curl -fsSL https://raw.githubusercontent.com/dbisiw07/work-from-a-list/main/get.sh | sh
```

That downloads the latest release into `~/Applications` and starts it. It also
starts at login and comes back if it ever crashes; choosing Quit keeps it closed
until your next login. Run the same line again to update. To remove it:

```sh
curl -fsSL https://raw.githubusercontent.com/dbisiw07/work-from-a-list/main/uninstall.sh | sh
```

Your list and mantras stay unless you add `-s -- --all` after `sh`.

The app isn't notarized by Apple yet. The line above installs it without a
warning. If you download the zip from Releases in a browser instead, macOS
will block it the first time: open System Settings → Privacy & Security and
click Open Anyway.

## Using it

- **Add:** click the add line ("Think, Break it down, Sweat the details and edges"), type a
  task and press Return. The line stays ready for the next one. Press Return on
  an empty line, or Esc, and the keyboard goes back to the app you were in.
  Clicking the + also adds what you've typed.
- **Check off:** click a task's circle. It fills green with a pop, a line draws
  through the text, and the task slides down below the open ones, so what's
  left stays on top. Uncheck it to bring it back up and edit it again.
- **Edit:** click a task's text. A task you edit down to nothing is removed.
- **Remove:** hover a task and click ×. "Removed … Undo" shows in its place for
  5 seconds if you change your mind.
- **Reorder:** drag a task up or down; the others slide out of the way.
- **Urgent:** hover a task and click the "!" to mark it as must-be-done-today.
  It gets an orange "!" and moves to the top, above the other open tasks. Only
  3 tasks can be urgent at once (done ones don't count), so urgent stays
  meaningful; finish one to free a slot. You can still drag any task anywhere.
- **Working on now:** hover a task and click the pin. Its circle turns
  half-filled, a green pin stays on it with how long you've been on it ("40m",
  updated once a minute), and the menu bar shows that task
  instead of the count, so you can see it from any app. Only one task can be
  "now": pinning another moves it, and checking it off or clicking the pin
  again clears it.
- **All done:** when the last task is checked off, the card glows green, says
  "All done ✓" and plays a soft chime (Chime When All Done in the menu bar
  turns it off).
- **Move and size:** drag the header or empty space to move the HUD. Drag the
  right edge to make it wider for longer tasks (the text stays the same size).
  Drag the bottom-right corner, or right-click → Size, to scale everything.
- **Hide:** click × in the header or press ⌃⌥T; press ⌃⌥T again to bring it
  back. The menu bar icon stays, and its menu lets you check tasks off, Clear
  Completed, change Size and Color, Reset HUD Position and Quit.

Past 10 tasks the list scrolls inside the card instead of growing down the
screen. At 25 the add line says "That's 25 — plenty for one day."

## Mantras and header

Under the list a quiet ✦ line shows one of your mantras. It changes every 25
minutes, counted from 6:00, and none repeats until all have shown; each day
gets a new order. Click it, or choose
menu bar → Mantras & Header…, to add, edit and delete mantras. They're kept in
`~/Library/Application Support/WorkFromAList/mantras.txt`, one per line, and editing that
file works too. Menu bar → Show Mantras turns the line off.

The same window changes the header: the words after "Today –", the green
subtitle and the gray motto under it. Put `**two stars**` around a word to make
it bold, and leave a line empty to hide it.

## Each morning

The list is saved in `~/Library/Application Support/WorkFromAList/today.json`.
Each morning at 5 am the done tasks clear and the unfinished ones carry over
to the new day in the same order. Urgent tasks stay urgent until you finish
them or clear the flag. The "now" pin clears, so each morning you choose what
to start on.
Until 5 am a list you make after midnight still counts as today's. To change the reset hour, run
`defaults write io.github.dbisiw07.work-from-a-list resetHour -int 5` and restart the app.

## Changing the list from other apps

The HUD watches `today.json`, so a script, a Shortcut or anything else that
writes the file shows up in the HUD and the menu bar within a moment. Write the
same JSON the HUD writes: `{"day": "2026-10-29", "items": [{"text": "…"}]}`.
Each item can also have `"done"` and `"urgent"` (true/false) and an `"id"`;
leave the id out for a new task and the HUD adds one. `"now"` is the id of the
pinned task. A file from an earlier day gets the morning reset, and a
half-written file is ignored until it's complete (or put back from the HUD's
copy if it stays broken). While you're typing in a task, your text wins and
everything else comes from the file.

## How it stays light

There's no ticking timer. The app sleeps until you touch the list. One timer
fires at the morning reset and one when the mantra changes. It also rechecks the day on wake, unlock and
clock changes. Saves are written half a second after your last change, not on
every keystroke. It sits at ~0% CPU and ~20 MB of memory.

The HUD only takes the keyboard while you're typing in it, never on its own.

## Build it yourself

You need Apple's command line tools for the Swift compiler. If
`swiftc --version` doesn't work, run `xcode-select --install` first.

```sh
git clone https://github.com/dbisiw07/work-from-a-list && cd work-from-a-list
./install.sh     # build, install to ~/Applications and start
./build.sh       # just build "Work from a List.app" in this folder
./uninstall.sh   # stop it and remove the app and LaunchAgent
```

`"Work from a List.app/Contents/MacOS/WorkFromAList" --print` prints today's list, and
`--test` runs the checks.

## Contributing

Issues, ideas and pull requests are welcome; see [CONTRIBUTING.md](CONTRIBUTING.md).
[AGENTS.md](AGENTS.md) explains how the code fits together, for people and AI
coding agents alike.

## License

[MIT](LICENSE)
