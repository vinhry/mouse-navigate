# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Fixed
- Touch gestures went on working behind the lock screen and while another user's session
  was in front, so a gesture bound to an app, a web address, a shortcut or a keystroke
  could run where nobody was looking. Everything stands down while the Mac is asleep,
  locked or switched to another user, and comes back once you are in front of it again.
  A side-button press waiting on a hold or double-click is let go of too.
- Taking Accessibility away from MouseNavigate while it ran left the menu bar saying
  Running while nothing worked. It now notices within seconds, shows the permission
  warning, and starts again by itself once access is granted.
- **Launch Finder**, **Launch Default Browser** and **Launch App** looked the app up while
  every click and keystroke on the Mac waited, and so did the actions that send a macOS
  shortcut (**Move Left / Right a Space**, **Screenshot Selection**, and **Mission
  Control**, **App Exposé** and **Show Desktop** when the Dock cannot be asked directly),
  which read System Settings on every use. The launches happen once the press has been
  answered, and the shortcuts are read ahead of time. A button bound to an app that has
  since been deleted now does nothing rather than its usual click, and says so in the log.
- Drawing a letter with the right or middle button redrew the ink and brought its window
  forward for every movement the mouse reported, while the pointer waited, and recognised
  the letter and ran its action before the release was answered. The ink is drawn at most
  once a display frame, and the letter is read once the button is up.
- Opening **Grid Jump** made its window on every display while the key that opened it was
  still being held up, so keys typed straight after it waited. The grid now appears a
  moment after the key has been answered.
- An update whose unpacking or Gatekeeper check never finished, or whose download only
  trickled in, left **Settings → About** saying it was downloading for the rest of the
  session, and every later check was turned away as already under way. Each step now has
  a time limit, and an update that runs out of time is reported as failed.
- **Install and Relaunch** copied and checked the new version while every click and
  keystroke on the Mac waited. It now does that in the background, and **Settings →
  About** says it is installing. An update that macOS had cleared out of the caches folder
  while it waited could never be installed; it is downloaded again instead.

## [0.7.0] - 2026-10-11

### Added
- Eight two-segment drawn strokes, each one straight leg then another, under
  **Settings → Touch → Characters**: the corners **Left then Up**, **Right then Up**,
  **Up then Left** and **Up then Right**, and the out-and-back strokes **Left then Right**,
  **Right then Left**, **Up then Down** and **Down then Up**. The other four corners were
  letters already (`L`, `T`, `F` and `J`) and stay so. All eight start out unbound.

## [0.6.1] - 2026-10-10

### Added
- The Touch tab warns when macOS has a three-finger gesture on that takes one of the bound
  trackpad gestures: Mission Control and App Exposé on a three-finger swipe, three-finger
  drag, or Look up on a three-finger tap. It names the gestures taken, says where to change
  the setting and offers **Open Trackpad Settings…**. MouseNavigate only listens to the
  touches, so macOS acts on them too until its gesture is moved to four fingers or off.

### Fixed
- Dragging the Settings window to another display left the Touch tab's gesture list,
  preview and Restore Defaults drawn over the header. The pane container's size was left to
  the layout engine, which chose differently after the move; it is pinned now.

## [0.6.0] - 2026-10-10

### Added
- **Export Settings…** and **Import Settings…** on the About tab. Every setting goes to a
  JSON file that can be read and edited by hand, and comes back from one after the whole
  file has been checked.
- **Modifier keys with mouse buttons.** `⌃`, `⌥`, `⇧` and `⌘` held with a side button make
  a combination with bindings of its own, chosen under **With:** on the Mouse tab. A
  combination that has not been bound does what the button does on its own.
- **Modifier keys with the scroll wheel**, each its own option under Scroll Wheel: `⇧`
  scrolls sideways, `⌥` scrolls precisely, `⌘` scrolls fast. A modifier an option acts on
  is taken off the event, so an app does not act on it a second time.
- **Scroll settings per axis, per mouse and per app.** The wheel reverses vertically,
  horizontally, both ways or neither, and each axis has a speed of its own. A mouse model
  can have its own scroll settings, under **For:** in the Scroll Wheel section, and so can
  an app, which follows **Applies to** like the pickers; an app's win over the mouse's,
  which win over the ones for all.
- **Hold a side button and drag.** Each button has four more bindings under **Press** on
  the Mouse tab, **Drag ↑ ↓ ← →**, which fire once the pointer has moved about 30 points
  with the button held. A drag counts only before a hold has fired.

- **Restore Defaults** on the Mouse tab, for the mouse in use: every button binding, for
  every press and modifier combination, and the scroll settings for all mice and that
  mouse. In an app's scope it hands the app's buttons and wheel back to the ones for all apps.
- The Mouse tab's **Press** and **With** pickers mark, with a dot, the presses and modifier
  keys that have bindings, and a line under them says which bindings the pickers are
  showing, so a binding under Hold, a drag or ⌘ is no longer invisible until clicked through.
- Action menus are grouped under headings, with **Disabled** at the top where it can be
  found, and a custom binding too long for its menu shows in full on hover.
- The Trackpad and Magic Mouse panes show how the gesture under the pointer is done, the way
  the Characters pane shows a stroke: a picture of the surface beside the list, with the
  fingers that rest on it in grey and the ones that tap, click or slide in red, over and
  over, and the how-to in words under it. The picture is mirrored for **Left-handed** and
  holds still with Reduce Motion. The rows' tooltips are gone, since they only covered the
  how-to now shown in the open.
- A menu bar glyph, tooltip and menu line for **Off in &lt;app&gt;**, while the app in front has
  MouseNavigate turned off; before, the icon said Running while nothing worked.
- VoiceOver reads the menu bar icon's state.
- With Reduce Motion on, the stroke preview on the Touch tab holds still and the drawn-letter
  result goes away without a fade.
- Click hints say **Finding targets…** when the Accessibility scan takes longer than a
  moment, as it does in Electron apps, instead of looking like a key that did nothing.
- The drawn-letter result sits on a plate that follows the system appearance, so it can be
  read over dark content.
- **Version X is available**, on a copy that cannot install an update itself, offers to open
  the release page instead of ending there.
- **Check for Updates…** while a check or download is already under way says so.
- **Launch at Login** says why when it cannot be turned on, instead of quietly staying off.
- A clean import of settings is confirmed; before, only one with leftovers was.

### Changed
- **Preferences** is **Settings**, as macOS has called it since Ventura: the menu item, with
  `⌘,`, and the window title. Nothing about where settings are kept changes.
- The Settings window has a main menu behind it, so `⌘C`, `⌘V` and `⌘A` work in its text
  fields, `⌘W` closes it and `⌘Q` quits.
- The Scroll Wheel section's checkbox names the app or mouse it gives settings to.
- The Launch App and Add App panels each say what the app is for.
- The menu bar header reads **MouseNavigate 0.5.0**, the permission items carry a warning
  symbol rather than a text one, and the two labels that wrote ⌘⇧ now write ⇧⌘ like the rest.
- When a copy cannot update itself, the About tab says so under the greyed-out box rather
  than only in its tooltip.
- **Remove App** says that the app's scroll settings and turned-off state go too.
- **Reverse scrolling direction** became **Reverse: Both**, and the one **Speed** became
  a vertical and a horizontal speed. Existing settings carry over.
- The Trackpad and Magic Mouse panes draw the empty device before any gesture is hovered,
  so the preview column is never blank.
- Tabbing to a gesture or character picker with keyboard navigation shows its picture and
  how-to, as hovering does, and VoiceOver reads the how-to as the picker's help.
- VoiceOver reads each picker, slider, segmented control and key recorder with the label
  beside it: "Button 3", "Vertical speed", "Activate (hold)".

### Fixed
- The Settings window was 858 points wide: the Keyboard Cursor tab's hint was one long line
  and set the width of every tab, leaving the Touch and About tabs mostly empty. The hint
  wraps and the window is 120 points narrower.
- With an app chosen under **Applies to**, the Scroll Wheel section's checkbox sat far to
  the right, in the room the hidden mouse picker kept.
- The Touch tab's previews now stop or start when Reduce Motion is changed while the
  window is open, rather than at the next hover.
- The Export and Import buttons on the About tab stand apart from the update status line.
- Recording a keyboard shortcut for a button or gesture while MouseNavigate was paused
  resumed the keyboard cursor when the sheet closed.
- With an app chosen under **Applies to**, the Scroll Wheel section showed a stray **For:**
  label with nothing after it.
- Importing settings asked whether to replace everything before the file had been checked,
  so a file that was not a settings file was still asked about.
- When the helper that reopens MouseNavigate after an update could not start, the
  explanation was never shown: the app quit before the alert reached the screen.
- A drawn stroke is matched against the letter templates once rather than twice.
- An event tap that macOS switched off, and MouseNavigate switched back on, is noted in
  the unified log under the `tap` category, with what switched it off.
- Per-app bindings are decoded once per settings change instead of three times per button
  press.
- Dragging a scroll-speed slider, rebinding a mouse button, or changing any other setting
  outside the Keyboard Cursor tab no longer ends cursor mode.
- A Magic Mouse click that became a gesture no longer hands the app its release alone if
  MouseNavigate is paused, or the app switched, while the button is still down.
- Click hints no longer leave Electron and Chromium apps building their accessibility
  tree after the hints have closed.

## [0.5.0] - 2026-10-09

### Fixed
- The updater opens a release's page only when it is a web address. GitHub's answer names
  the page as well as the download, and only the download was held to `https`; the page was
  handed to whatever opens its scheme.
- A copy that cannot update itself, such as an ad hoc or Apple Development build, now says
  so in the tooltip of its greyed-out "Check for updates automatically" box. The
  explanation was written and then overwritten before it could show.

## [0.4.3] - 2026-10-08

### Fixed
- Trackpad taps beside a resting finger behave as they did in 0.4.1. Three allowances made
  for the Magic Mouse in 0.4.2 had reached the trackpad too: a resting finger that had
  started to move still counted as resting, so a two-finger tap whose fingers landed a beat
  apart became a One-Fix tap; fingers all lifting together could be a tap; and taps within
  100 ms of each other were dropped, which a quick index double-tap could hit. All three now
  apply to the Magic Mouse only.
- With **Tap to click** on, a trackpad tap that became a gesture was also a click. In
  Terminal and Finder, whose tabs are windows, that click landed just after a One-Fix tap
  had switched tab and brought the old tab straight back. The click macOS makes from a tap
  that was a gesture is now held back.
- `--touch-debug` lines carry the time in seconds since the monitor started.

## [0.4.2] - 2026-10-07

### Fixed
- **Magic Mouse gestures work the way the mouse is held.** Slides start from fingers already
  resting on the mouse, where before a finger had to land beside a resting one first. A
  resting finger that has crept along with the mouse still counts as resting, instead of
  disqualifying itself after a few seconds of use. The heel of the hand on the back of the
  mouse, and the side of the hand along an edge, are no longer taken for fingers, so they
  cannot turn a two-finger gesture into a three-finger one or defeat the middle-click pose.
  A finger that lands beside a resting one to click is a click, not a Near / Far Tap, so
  ordinary clicks no longer switch tabs as well. Scrolling along the mouse with a finger
  resting beside the scrolling one is left alone.
- A Magic Mouse is recognised by its MultitouchSupport family rather than by its name, so
  one whose name is missing from the registry no longer gets the trackpad gestures.
  `--touch-debug` prints the family of each surface.
- A slide can be made again after the fingers come to rest; before, every finger had to
  lift first.
- A Magic Mouse loses a lightly resting or sliding finger for a frame at a time. Each loss
  used to be a lift and each return a landing, so a slide fired once per dropout or not at
  all, a slid finger returning to rest fired the opposite slide, and a resting index finger
  produced a stream of Far-Taps, and a light tap that bounced fired two or three times. A
  finger that comes back within 50 ms is now the same finger, and taps closer together
  than 100 ms are one tap; mouse taps are reported 50 ms later.
- Tapping on a Magic Mouse rocks it, and the resting finger shifts a hair. That shift no
  longer disqualifies it from anchoring the next tap or slide.
- Near-Tap is a tap where the index finger naturally rests, or tucked in towards the middle
  finger; Far-Tap means reaching out towards the edge. The split used to fall right on the
  natural spread, so the same tap came out Near or Far depending on where the middle
  finger happened to rest.
- `--touch-debug` shows every finger in range with its state and size, hovering ones included.

## [0.4.1] - 2026-10-06

### Fixed
- Leaving cursor mode with a key still held, such as pressing Escape while holding `A` or
  letting go of `A` a beat before a movement key, no longer types that letter into the
  frontmost app for as long as the key stays down.
- `⌘` shortcuts on mapped keys (`⌘S`, `⌘L`, `⌘F`…) reach the frontmost app while cursor
  mode is engaged or locked, and pressing one while the grid or the click hints are up
  closes them instead of starting a cursor action that nothing could end.
- Engaging cursor mode from a mouse button while the activation key was mid-press no longer
  leaves that key stuck down in the app, or loses the letter.
- A side button pressed while drawing with the middle button no longer ends the drawing or
  loses its own release; a release whose press MouseNavigate swallowed is swallowed too,
  even across **Pause** and app switches. A hold or double-click no binding handles is
  passed on as the button's own clicks, where it was pressed.
- The pointer reaches the last column of a display and crosses to the next one at the
  slowest speeds, where it used to stop one point short.
- Maximize Left / Right no longer carries a window to a display stacked above or below.
- The "Keep MouseNavigate up to date?" question and the other update alerts no longer freeze
  the keyboard cursor, button holds and gestures while they are open.
- Closing Preferences with a key recorder still armed no longer leaves the keyboard cursor
  off until the window is opened again; recording a key another binding uses swaps them.
- Built-in shortcuts such as Close Tab and Quit send the right key on AZERTY, QWERTZ and
  other layouts, and key labels in Preferences and the click hints read as the keys they are.
- Window actions and app launches no longer run inside the event tap, so a hung app cannot
  stall every keystroke on the Mac; window requests give up after a quarter of a second.
- A settings change made after Accessibility was revoked shows the permission warning and
  recovers when it is granted again, instead of silently stopping for good.
- Synthetic clicks no longer carry the Shift or Option held for a speed tier, and
  double-clicks follow the system's double-click interval.
- Cursor mode stands down when the screen locks, as documented.
- Launch at Login says when macOS is still waiting for approval, and opens Login Items.
- Local builds signed with an Apple Development certificate, and copies run from source,
  no longer download every release only to refuse it.
- A second launch from the command line opens Preferences, as a second launch from Finder
  already did.

### Changed
- Keystrokes only pass through MouseNavigate while the keyboard cursor is enabled.
- The build script writes `dist/MouseNavigate.zip` next to the app.

## [0.4.0] - 2026-09-27

Copies of 0.3.x cannot update themselves, so install this version by hand once. From here
on, MouseNavigate offers updates itself.

### Added
- **Custom actions** for buttons, gestures and drawn letters, at the foot of every picker:
  - **Keyboard Shortcut…** records any key combination and sends it to the frontmost app.
  - **Launch App…** opens an app you choose.
  - **Open URL…** opens a web address or any other link.
  - **Run Shortcut…** runs a shortcut from the Shortcuts app by name.
- **Per-app bindings.** **Applies to** on the Mouse and Touch tabs switches the pickers to
  one app's own bindings, which win over the ones for all apps while that app is in front.
  Each app can also turn MouseNavigate off entirely, keyboard cursor included, for games,
  virtual machines and remote desktops.
- New built-in actions: Play / Pause, Next / Previous Track, Volume Up / Down, Mute, Lock
  Screen and Screenshot Selection.
- **Hold and double-click** bindings for every mouse button, under **Press** on the Mouse
  tab. A button bound only to a click still acts the moment it goes down.
- **Scroll Wheel** options for mice: reverse the direction, change the speed, and an
  experimental smooth scrolling mode. Trackpads and the Magic Mouse are never affected.

- **Grid jump** (`G` in cursor mode): pick cells of a 3×3 grid, each pick splitting the
  last, to bring the pointer anywhere in three keystrokes. Delete goes back, 1–9 change
  display, Escape puts the pointer back.
- **Click hints** (`H` in cursor mode): everything clickable in the frontmost window gets a
  short label; type it to click, with Shift for a right-click and Option to only move there.
- **Click Hints** and **Grid Jump** as actions for mouse buttons and gestures.
- **Updates from GitHub Releases.** MouseNavigate asks once whether to check daily, then
  downloads a newer release in the background and offers **Install and Relaunch** in the
  menu bar menu. An update must be signed by the same developer as the running copy and
  notarized by Apple before it replaces anything. **Check for Updates…** is in the menu
  and in Preferences → About.

### Changed
- Existing settings carry over unchanged: built-in actions are stored exactly as before.
- A side button whose press ran an action now swallows its release too, rather than handing
  apps a release for a press they never saw.

## [0.3.2] - 2026-09-23

### Fixed
- **MouseNavigate now starts properly on a Mac that has never run it before.** It appeared
  in Activity Monitor as a live process with no menu bar icon, no permission prompt and no
  way to quit it. Opening the `.app` started a launcher that spawned a detached copy of
  itself and exited, so the process that survived was never registered with macOS:
  permission prompts were attributed to a process that had already gone, and the menu bar
  icon was created only after the Accessibility check, the event tap, device enumeration
  and two private-framework loads had all completed. It worked only on machines that had
  already granted Accessibility to an earlier build.
  - The app is now a single process that macOS knows about, and the menu bar icon is
    created before anything that can stall or ask for permission.
  - Launching it again opens Preferences instead of a dialog offering to quit it.
  - Startup now goes to the unified log, so a machine where it misbehaves can say why:
    `log show --last 10m --predicate 'subsystem == "com.vinhry.MouseNavigate"' --info`.
  - A lock file that cannot be created is no longer mistaken for "already running", which
    used to stop the app from starting at all, in silence.
  - A failed run loop source no longer exits the app, and a menu bar icon whose image is
    missing now falls back to text rather than an invisible square.

### Removed
- The "already running" dialog, and with it the distributed notification it used to quit
  the other copy — any process on the machine could post that notification and terminate
  MouseNavigate.

## [0.3.1] - 2026-09-22

### Fixed
- **The activate key can auto-repeat again.** Holding `A` is what engages cursor mode, so
  `A` was the one letter on the keyboard that could not repeat while held down. Tapping it
  and pressing it again straight away now hands the key straight over, so it repeats like
  any other letter and cursor mode stays out of the way. How soon the second press has to
  land is the new **Double-tap to repeat** setting in Preferences → Keyboard Cursor
  (0.4 s by default, `Off` at zero).

## [0.3.0] - 2026-09-22

### Added
- **Touch tab** with jitouch-style gestures, off by default:
  - Trackpad: tab switching by tapping beside a resting finger, three-finger tap and
    one-fix two-tap to open links in new tabs, close / reopen tabs, click-slide to quit,
    index double-tap to refresh, four-finger rolls to minimize and maximize, and a
    move / resize window mode.
  - Magic Mouse: near / far taps for tabs, slides for closing tabs, refreshing, minimizing,
    maximizing and changing spaces, three-finger swipes for Show Desktop and Mission
    Control, a middle click, and a corner hold to move / resize windows.
  - Drawn letters A–Z and eight directions, from the trackpad, a right-button drag or a
    middle-button drag.
  - Drawn strokes appear on screen as they are made, around the pointer, followed in the
    middle of the screen by the letter recognised and the action it ran, or "no match".
    Switched off with **Show the drawing on screen**.
  - **Finger spacing** for drawn letters, setting how far apart the two fingers must be
    before a movement counts as drawing rather than scrolling.
  - Hovering a character in Preferences traces its stroke beside the list, looping, with a
    ring marking where the stroke starts.
  - Left-handed mode, and `--touch-debug` for seeing what the recognizer sees.
- **About tab** with the version, developer, GitHub and issue links, and license.
- New actions for buttons and gestures: next / previous / new / close / reopen tab, refresh,
  open link in new tab, copy, paste, new, open, save, quit, minimize, maximize, maximize
  left / right (walking across displays), move / resize window, Show Desktop, move a space
  left / right, launch Finder and launch the default browser.

### Changed
- Preferences now has four tabs: **Mouse**, **Keyboard Cursor**, **Touch** and **About**.
- Action pickers are grouped by kind.
- Clicks and scrolls pass through the event tap only while touch gestures are on.

### Fixed
- **The built-in keyboard and trackpad are no longer detected as a mouse.** A MacBook's
  internal keyboard / trackpad reports the HID Mouse usage, so with no mouse attached it was
  shown as the detected device and given the generic button profile. Built-in devices,
  trackpads and keyboards are now skipped, and `--list-devices` marks them as ignored.
- **Universal binary.** Recent toolchains put every `swift build` in the same output
  directory whatever `--arch` asks for, so the Intel build overwrote the Apple silicon one
  and `build-app.sh` shipped an Intel-only app. Each architecture now builds in its own
  scratch path, and the script checks what it got before merging.
- A retain cycle in the Characters preference pane kept the character list and its views
  alive for the life of the process.
- A long drawing thins its path instead of growing without limit, bounding both memory and
  recognition cost while keeping the shape.
- The overlay no longer resizes its window and rewrites layer scales on every frame of a
  stroke, and scroll events check a cached flag instead of walking the recognizers.

### Security
- The single-instance lock file moved from `/tmp` to the per-user temporary directory, kept
  at `0600`. Any account on the machine could create and hold the old path, which would stop
  the daemon from ever starting.
- Finger data from `MultitouchSupport` is checked before use: a finger count beyond what any
  hand has is rejected rather than walked, and coordinates must be finite and on the surface.
- The private frameworks the app loads are no longer unloaded on teardown, since they run
  their own callback threads.

## [0.2.0] - 2026-09-12

### Added
- **Device auto-detection.** The attached mouse is identified over IOKit and its button
  profile applied automatically. Logitech MX Master 4 and MX Master 3 / 3S are recognised
  by HID product string, with a product-ID fallback so Bluetooth, Bolt and Unifying
  connections all match. Anything else gets a generic profile.
- **Per-device button mappings**, so switching mice no longer means remapping. Buttons
  `3`–`9` are now configurable, up from `3`–`6`.
- **Keyboard cursor control.** Hold `A` to drive the pointer: `IJKL` to move, `S` / `D` /
  `F` to click (hold `S` to drag), `Space` to scroll, `;` to lock, `Esc` to exit. `Shift`
  and `Shift`+`Ctrl` are speed tiers, `Option` is precision. Movement eases in and
  diagonals are normalised.
- Every cursor key and speed value is rebindable in Preferences.
- **Toggle Keyboard Cursor** as a mouse button action.
- Button tester in Preferences, which reports the number of whichever button you press.
- Input Monitoring warning in the status menu, alongside the existing Accessibility one.
- `--list-devices` flag for diagnosing detection.
- **Universal binary**, so the app runs on Intel Macs as well as Apple silicon.
- Unit tests covering device matching, the movement curve, screen clamping and the
  activation state machine.

### Changed
- Preferences is now a two-tab window: **Mouse** and **Keyboard Cursor**.
- The status bar icon changes while cursor mode is engaged.
- Without Accessibility permission the app no longer quits silently. It stays in the menu
  bar with a warning icon and starts working as soon as the permission is granted.
- Local builds are signed with a Developer ID identity when one is available, so
  permissions survive rebuilds.
- `main.swift` split into focused files, with the pure logic moved to a new
  `MouseNavigateCore` library target.

### Notes
- The activation key is withheld rather than swallowed: cursor mode engages only if it is
  still held after the delay, so typing rolls like `as` and shortcuts like `⌘A` are
  unaffected.

## [0.1.0] - 2026-04-06

### Added
- Global mouse side-button support for Logitech MX4.
- Safari/Finder back/forward mapping:
  - Button `3` -> `⌘ + [`
  - Button `4` -> `⌘ + ]`
- System action mapping:
  - Button `5` -> App Exposé
  - Button `6` -> Mission Control
- Single-instance behavior with popup prompt and quit-running-instance action.
- Low-memory launcher/daemon runtime architecture.
- App bundle packaging script (`scripts/build-app.sh`) with icon generation.
- Optional stable code signing support via `SIGN_IDENTITY`.
