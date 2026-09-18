# Dynamic Island for Omarchy (`io.github.buildscript-dev.dynamic-island`)

A MacBook-style Dynamic Island that runs natively inside `omarchy-shell`
(Quickshell). A black notch hangs from the top edge, exactly as tall as the
bar, and springs open for whatever is happening: music, volume and
brightness, notifications, charging, Bluetooth, timers, screen recording.

It follows your Omarchy theme and bar (height, colors, font scale), uses
Hyprland blur for the translucent styles, and tucks away over fullscreen
windows.

## How it behaves

The island has five shapes. Moving between them is one spring animation:
it opens with a slight overshoot and closes with more damping. Content
fades out fast, then the new content comes in from a soft blur while the
shape is still settling. This is the same order Apple uses.

| Mode | Size | Triggered by |
|---|---|---|
| **Idle notch** | notch width × bar height, concave "ears" into the top edge | nothing happening |
| **Compact live activity** | widens sideways: leading + trailing content | music playing (art + waveform tinted by the album color), timer (orange countdown), screen recording (pulsing red dot + elapsed) |
| **Alert pill** | wide, a little taller | charging / on battery / low battery, Bluetooth connect/disconnect, Do Not Disturb, timer done, `omarchy osd -m` messages |
| **HUD** | drops down with a level bar | volume, brightness, keyboard backlight: every `omarchy osd -p` |
| **Notification peek** | medium card | new notifications from the Omarchy notification daemon |
| **Expanded** | large card | hover (rest ~0.3 s) or click |

**Expanded** shows **Now Playing**: artwork, title, artist and album, a
waveform, a seekable scrubber that thickens under the pointer, and
previous / play-pause / next. "Previous" restarts the track after 4 s, like
Apple does. When nothing is playing it shows a **home** view instead: a
large clock, this week's dates with today marked, 1/5/10/25-minute timer
pills (or the running timer with pause/cancel), a Focus (DND) toggle, and
"Stop recording" while you're recording. The top strip shows the player,
the battery, a DND moon and the mic-privacy dot.

Other details:

- The notch swells slightly under the pointer to show it can be clicked
  (a stand-in for haptics).
- Holding the volume key updates the HUD in place. A new HUD or alert
  replaces the current one straight away. Notifications queue behind it.
- Hovering an activity keeps it on screen until the pointer leaves.
- An orange dot shows while any app is recording from the microphone.

## Gestures

- **Hover** on the notch: opens after a short pause (`openOnHover`, `hoverDelay`).
- **Left click**: open or close. On a notification it runs the default
  action. On a HUD or alert it closes it and opens the island.
- **Right click** on a notification: dismisses it.
- **Middle click**: play / pause.
- **Scroll** on the closed notch: volume ±2 %.
- Click the artwork in the expanded player to raise the player window.

## Styles and colors

Set these on the island's bar entry in `~/.config/omarchy/shell.json`.
Changes apply as soon as you save:

```json
{ "id": "io.github.buildscript-dev.dynamic-island", "style": "glass", "palette": "theme" }
```

| Key | Default | Meaning |
|---|---|---|
| `style` | `black` | `black` = true MacBook notch · `bar` = the bar's theme background/text · `glass` = translucent, blurred by Hyprland |
| `palette` | `apple` | `apple` = Apple system colors (green charging, orange timer, red record, indigo focus) · `theme` = your theme's accent/urgent |
| `notchWidth` | `200` | width of the idle notch in px |
| `openOnHover` / `hoverDelay` | `true` / `320` | open by resting the pointer on the notch |
| `showNotifications` | `true` | peek new notifications |
| `replaceOsd` | `true` | show `omarchy osd` (volume, brightness…) in the island |
| `hideInFullscreen` | `true` | slide away over fullscreen windows; a 3px strip at the top edge brings it back |
| `showWhenIdle` | `true` | keep the bare notch visible when nothing is happening |
| `artworkTint` | `true` | tint the waveform with the album's color |
| `showMicIndicator` | `true` | orange mic-in-use dot |
| `scrollVolume` | `true` | scroll on the notch for volume |
| `monitor` | `all` | `all` or a connector name (`eDP-2`) |

## Installed pieces

1. **Plugin**: this folder. It declares a `service` that draws one notch
   window per monitor on the `omarchy-dynamic-island` overlay layer. It also
   declares a `bar-widget`: an invisible spacer in the bar's center that
   reserves the notch's width, so bar widgets flow around it like the macOS
   menu bar.
2. **`~/.config/omarchy/shell.json`**: the island is the bar's center
   widget and `centerAnchor`. `omarchy.osd` is in `disabledPlugins`, so
   `omarchy osd` calls go to the island. `omarchy.clock` was added on the
   right.
3. **`~/.config/hypr/looknfeel.lua`**: a `layer_rule` for
   `omarchy-dynamic-island` that turns on blur (for `glass`/`bar`) and
   turns off Hyprland's own layer fade.

Backups of both config files were saved next to them as `*.bak.<timestamp>`.

## IPC

```sh
omarchy-shell island state               # JSON snapshot
omarchy-shell island expand | collapse
omarchy-shell island timer 300           # start a 5-minute timer
omarchy-shell island timerCancel
omarchy-shell island alert "<glyph>" "Title" "Value"
omarchy-shell island hud volume 40
omarchy-shell island notify "Title" "Body"
omarchy osd -i brightness -p 50          # the stock OSD command, now shown in the island
```

## Reverting

To bring back the stock OSD, remove `"omarchy.osd"` from `disabledPlugins`
(or set `"replaceOsd": false` on the island entry and then re-enable it).
To remove the island, take its entry out of `bar.layout.center`. The old
`sharifmdathar.dynamic-island` plugin is still installed but not in the
layout. Don't use both at once: both register the `island` IPC target.
