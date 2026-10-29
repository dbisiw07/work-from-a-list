# Today HUD

A floating list of what you're working on today. Seven items at most, so the
list stays honest.

It looks like a ruled notebook page by default: white paper, dark ink, faint
blue lines under each item, and a red margin. Right-click → Color, or menu bar
→ Color, switches to a solid Teal, Midnight, Indigo, Forest, Plum or Graphite
card with white text. Every theme is opaque, so the list stands out and reads
the same on any wallpaper, in light or dark mode.

- Click "What matters today?", type an item and press Return. The box stays
  ready for the next one. Press Return on an empty line, or Esc, and the
  keyboard goes back to the app you were in.
- Click a circle to check an item off; done items are struck through (uncheck
  one to edit it again). Click an item's text to edit it, and hover a
  row and click × to remove it. An item you edit down to nothing is removed.
- The header shows the date and a ring with done/total. When the last item is
  checked off, the card glows green, says "All done ✓", and plays a soft chime.
- At seven items the add box is replaced by "That's seven. Finish one before
  adding more."
- Drag it anywhere and resize it from the bottom-right corner, or right-click →
  Size. Change its look from Color. Hide it with the × in the header or ⌃⌥T. The menu bar shows done/total,
  and its menu lets you check items off, Clear Completed, toggle the chime,
  Reset Position and Quit.

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

```sh
./install.sh     # build, copy to ~/Applications, start at login (LaunchAgent local.today-hud)
./uninstall.sh   # stop + remove (your list file stays until the next reset)
./build.sh       # just build "Today HUD.app" here
```

`"Today HUD.app/Contents/MacOS/TodayHUD" --print` prints today's list.
