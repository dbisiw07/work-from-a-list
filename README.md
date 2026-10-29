# Today HUD

A small floating list of what you're working on today. It sits above every
app without taking focus, keeps up to 25 tasks, and starts fresh each morning.

It looks like a ruled notebook page by default: white paper, dark ink, faint
blue lines under each task, and a red margin. Right-click → Color, or menu bar
→ Color, switches to a solid Teal, Midnight, Indigo, Forest, Plum or Graphite
card with white text. Every theme is opaque, so the list stands out and reads
the same on any wallpaper, in light or dark mode.

## Using it

- **Add:** click the add line ("Think, break it down, sweat the details"), type a
  task and press Return. The line stays ready for the next one. Press Return on
  an empty line, or Esc, and the keyboard goes back to the app you were in.
  Clicking the + also adds what you've typed.
- **Check off:** click a task's circle. The circle pops and a line draws through
  the text. Uncheck it to edit it again.
- **Edit:** click a task's text. A task you edit down to nothing is removed.
- **Remove:** hover a task and click ×. "Removed … Undo" shows in its place for
  5 seconds if you change your mind.
- **Reorder:** drag a task up or down; the others slide out of the way.
- **Working on now:** hover a task and click the pin. Its circle turns
  half-filled and a green pin stays on it, and the menu bar shows that task
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

## One day at a time

Only today's list is saved, in
`~/Library/Application Support/TodayHUD/today.json`. Each morning at 6 am it
starts fresh and the file is overwritten. Until then a list you make after
midnight still counts as today's. To change the reset hour, run
`defaults write local.today-hud resetHour -int 6` and restart the app.

## How it stays light

There's no ticking timer. The app sleeps until you touch the list. One timer
fires at the morning reset, and it also rechecks the day on wake, unlock and
clock changes. Saves are written half a second after your last change, not on
every keystroke. It sits at ~0% CPU and ~20 MB of memory.

The HUD only takes the keyboard while you're typing in it, never on its own.

## Install

You need macOS 13 (Ventura) or later, on Apple silicon or Intel, and Apple's
command line tools for the Swift compiler. If `swiftc --version` doesn't work,
run `xcode-select --install` first.

```sh
git clone <this repo> today-hud && cd today-hud
./install.sh
```

`install.sh` builds the app on your Mac, copies it to `~/Applications`, and
registers a LaunchAgent (`local.today-hud`), so the HUD starts at login and
comes back if it ever crashes. Choosing Quit keeps it closed until your next
login. Only one copy ever runs. Run `install.sh` again after pulling changes.

```sh
./uninstall.sh   # stop it and remove the app and LaunchAgent
./build.sh       # just build "Today HUD.app" in this folder
```

`"Today HUD.app/Contents/MacOS/TodayHUD" --print` prints today's list.
