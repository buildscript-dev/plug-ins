import QtQuick
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import Quickshell.Services.UPower
import Quickshell.Services.Pipewire
import Quickshell.Bluetooth
import qs.Commons
import "IslandModel.js" as Model

// Dynamic Island service. Owns every piece of shared state — media, the
// activity queue (HUDs, alerts, notification peeks), live activities
// (music, timer, screen recording) — and mounts one notch window per
// monitor. The windows only decide how to draw that state and track their
// own hover/expanded state.
Item {
  id: root

  property var shell: null
  property var manifest: null
  readonly property string pluginId: "io.github.buildscript-dev.dynamic-island"

  // ------------------------------------------------------------ settings
  // Settings live on the island's bar entry in shell.json, like every other
  // bar widget, so the Omarchy settings UI and `updateEntryInline` apply.
  // The shell's public barConfig snapshot only refreshes on plugin-registry
  // events, so the island reads shell.json itself to apply edits instantly.
  property var liveBarConfig: null
  FileView {
    path: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try {
        var parsed = JSON.parse(text() || "{}")
        root.liveBarConfig = parsed && parsed.bar ? parsed.bar : null
      } catch (e) {}
    }
  }
  readonly property var settings: {
    var cfg = root.liveBarConfig || (root.shell ? root.shell.barConfig : null)
    var layout = cfg && cfg.layout ? cfg.layout : {}
    var sections = ["center", "left", "right"]
    for (var i = 0; i < sections.length; i++) {
      var list = layout[sections[i]] || []
      for (var j = 0; j < list.length; j++)
        if (list[j] && list[j].id === root.pluginId) return list[j]
    }
    return {}
  }
  function setting(name, fallback) {
    var v = root.settings[name]
    return v === undefined || v === null || v === "" ? fallback : v
  }

  readonly property string style: String(setting("style", "black"))           // black | bar | glass
  readonly property string palette: String(setting("palette", "apple"))       // apple | theme
  readonly property int notchWidth: Number(setting("notchWidth", 200))
  readonly property bool openOnHover: setting("openOnHover", true) === true
  readonly property int hoverDelay: Number(setting("hoverDelay", 320))
  readonly property bool showNotifications: setting("showNotifications", true) === true
  readonly property bool replaceOsd: setting("replaceOsd", true) === true
  readonly property bool hideInFullscreen: setting("hideInFullscreen", true) === true
  readonly property bool showWhenIdle: setting("showWhenIdle", true) === true
  readonly property bool artworkTint: setting("artworkTint", true) === true
  readonly property bool showMicIndicator: setting("showMicIndicator", true) === true
  readonly property bool scrollVolume: setting("scrollVolume", true) === true
  readonly property string monitor: String(setting("monitor", "all"))

  // ------------------------------------------------------------ bar geometry
  readonly property var barConfig: root.liveBarConfig || (root.shell && root.shell.barConfig ? root.shell.barConfig : ({}))
  readonly property string barPosition: String(barConfig.position || "top")
  // The notch is exactly as tall as the menu bar, like on a MacBook.
  readonly property int notchHeight: barPosition === "top" ? Style.bar.sizeHorizontal : Math.max(26, Style.bar.sizeHorizontal)

  // ------------------------------------------------------------ look
  readonly property color islandColor: style === "bar" ? Color.bar.background
    : style === "glass" ? Qt.rgba(0, 0, 0, 0.62)
    : "#000000"
  readonly property color textColor: style === "bar" ? Color.bar.text : "#ffffff"
  readonly property color secondaryText: Qt.rgba(textColor.r, textColor.g, textColor.b, 0.58)
  readonly property color trackColor: Qt.rgba(textColor.r, textColor.g, textColor.b, 0.18)
  readonly property color controlFill: Qt.rgba(textColor.r, textColor.g, textColor.b, 0.1)

  function tint(name) {
    if (palette === "theme") {
      if (name === "red") return Color.urgent
      if (name === "white" || name === "") return root.textColor
      return Color.accent
    }
    if (name === "white" || name === "") return root.textColor
    return Model.APPLE[name] || root.textColor
  }

  readonly property string textFont: {
    var want = ["SF Pro Display", "SF Pro Text", "SF Pro", "Inter Display", "Inter", "Inter Variable", "Noto Sans", "Cantarell"]
    var have = Qt.fontFamilies()
    for (var i = 0; i < want.length; i++)
      if (have.indexOf(want[i]) !== -1) return want[i]
    return Style.font.family
  }
  readonly property string iconFont: {
    var have = Qt.fontFamilies()
    if (have.indexOf("JetBrainsMono Nerd Font") !== -1) return "JetBrainsMono Nerd Font"
    if (have.indexOf("Symbols Nerd Font") !== -1) return "Symbols Nerd Font"
    return Style.font.family
  }

  readonly property var glyphs: Model.G

  // Ticks once a second for clocks, timers and progress.
  property date now: new Date()
  Timer {
    interval: 1000
    running: true
    repeat: true
    onTriggered: root.now = new Date()
  }

  // Events fired during startup (initial Bluetooth / battery / DND state) are
  // state loads, not changes; the island only reacts once the grace passes.
  property bool settled: false
  Timer {
    interval: 3500
    running: true
    onTriggered: root.settled = true
  }

  // ------------------------------------------------------------ media
  readonly property var players: Mpris.players ? Mpris.players.values : []
  property string lastPlayerKey: ""
  readonly property var playingPlayer: {
    var first = null
    for (var i = 0; i < players.length; i++) {
      var p = players[i]
      if (!p || !p.isPlaying) continue
      if (!first) first = p
      if (root.lastPlayerKey !== "" && Model.playerKey(p) === root.lastPlayerKey) return p
    }
    return first
  }
  onPlayingPlayerChanged: if (playingPlayer) lastPlayerKey = Model.playerKey(playingPlayer)
  readonly property var player: {
    if (root.playingPlayer) return root.playingPlayer
    var fallback = null
    for (var i = 0; i < players.length; i++) {
      var p = players[i]
      if (!p || !(p.trackTitle || p.trackArtist)) continue
      if (Model.playerKey(p) === root.lastPlayerKey) return p
      if (!fallback) fallback = p
    }
    return fallback
  }
  readonly property bool hasMedia: player !== null && !!(player.trackTitle || player.trackArtist)
  readonly property bool isPlaying: player ? !!player.isPlaying : false
  readonly property string trackTitle: player ? String(player.trackTitle || "") : ""
  readonly property string trackArtist: player ? String(player.trackArtist || "") : ""
  readonly property string trackAlbum: player ? String(player.trackAlbum || "") : ""
  readonly property string trackArt: player ? String(player.trackArtUrl || "") : ""
  readonly property real trackLength: player && Model.validLength(player.length) ? player.length : 0
  readonly property string playerName: player ? String(player.identity || "") : ""
  readonly property string playerIcon: {
    if (!player) return ""
    var id = String(player.desktopEntry || "")
    var entry = id ? DesktopEntries.byId(id) : null
    var icon = entry && entry.icon ? entry.icon : id
    return icon ? Quickshell.iconPath(icon, true) : ""
  }

  // MPRIS position isn't pushed; poll it only while something shows it.
  property real trackPosition: 0
  property int positionWatchers: 0
  Timer {
    interval: 500
    repeat: true
    running: root.player !== null && root.positionWatchers > 0
    triggeredOnStart: true
    onTriggered: {
      if (!root.player) return
      root.player.positionChanged()
      root.trackPosition = root.player.position
    }
  }

  // Paused music lingers as a live activity for a moment, then the island
  // settles back to the bare notch — like macOS notch apps do.
  property bool pausedLinger: false
  onIsPlayingChanged: {
    if (isPlaying) {
      pausedLingerTimer.stop()
      pausedLinger = false
    } else if (hasMedia) {
      pausedLinger = true
      pausedLingerTimer.restart()
    }
  }
  Timer {
    id: pausedLingerTimer
    interval: 6000
    onTriggered: root.pausedLinger = false
  }
  readonly property bool mediaLive: hasMedia && (isPlaying || pausedLinger)

  // The quantizer only reads local files; streaming players (Spotify) hand
  // out https artwork, so fetch it once into a small cache first.
  property string artLocal: ""
  onTrackArtChanged: fetchArt()
  onArtworkTintChanged: fetchArt()
  Component.onCompleted: fetchArt()
  function fetchArt() {
    artLocal = ""
    if (trackArt === "" || !artworkTint) return
    if (trackArt.indexOf("http") !== 0) { artLocal = trackArt; return }
    artFetch.running = false
    artFetch.command = ["sh", "-c",
      "d=\"${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-dynamic-island\"; mkdir -p \"$d\"; " +
      "find \"$d\" -type f -mtime +7 -delete 2>/dev/null; " +
      "f=\"$d/$(printf %s \"$1\" | md5sum | cut -c1-20).img\"; " +
      "[ -s \"$f\" ] || curl -fsL --max-time 8 -o \"$f\" \"$1\" || exit 1; printf %s \"$f\"",
      "sh", trackArt]
    artFetch.running = true
  }
  Process {
    id: artFetch
    stdout: StdioCollector {
      onStreamFinished: {
        var p = String(text || "").trim()
        if (p !== "") root.artLocal = "file://" + p
      }
    }
  }

  ColorQuantizer {
    id: artQuantizer
    source: root.artLocal
    depth: 2
    rescaleSize: 48
  }
  readonly property color mediaAccent: artworkTint && trackArt !== ""
    ? Model.vividColor(artQuantizer.colors, tint("white"))
    : (palette === "theme" ? Color.accent : tint("white"))

  function mediaToggle() {
    var p = root.player
    if (!p) return
    if (p.isPlaying) { if (p.canPause) p.pause() }
    else if (p.canPlay) p.play()
  }
  function mediaNext() { if (root.player && root.player.canGoNext) root.player.next() }
  function mediaPrev() {
    var p = root.player
    if (!p) return
    // Apple behavior: "previous" restarts the track unless you're at the start.
    if (p.canSeek && root.trackPosition > 4) { p.position = 0; root.trackPosition = 0 }
    else if (p.canGoPrevious) p.previous()
  }
  function mediaSeek(fraction) {
    var p = root.player
    if (!p || !p.canSeek || root.trackLength <= 0) return
    var pos = Model.clamp(fraction, 0, 1) * root.trackLength
    p.position = pos
    root.trackPosition = pos
  }
  function mediaRaise() { if (root.player && root.player.canRaise) root.player.raise() }

  // ------------------------------------------------------------ timer
  property real timerEnd: 0        // epoch ms; 0 = no timer
  property real timerTotal: 0      // seconds
  property real timerPausedLeft: -1
  readonly property bool timerActive: timerEnd > 0 || timerPausedLeft >= 0
  readonly property real timerLeft: {
    root.now
    if (timerPausedLeft >= 0) return timerPausedLeft
    return timerEnd > 0 ? Math.max(0, (timerEnd - Date.now()) / 1000) : 0
  }
  function startTimer(seconds) {
    var s = Math.max(1, Math.round(Number(seconds) || 0))
    timerTotal = s
    timerPausedLeft = -1
    timerEnd = Date.now() + s * 1000
    root.now = new Date()
    pushActivity({ kind: "alert", source: "timer", icon: glyphs.timer, tint: "orange", title: "Timer", value: Model.formatTime(s), duration: 1600 })
  }
  function addTimer(seconds) {
    if (!timerActive) { startTimer(seconds); return }
    if (timerPausedLeft >= 0) timerPausedLeft += seconds
    else timerEnd += seconds * 1000
    timerTotal += seconds
    root.now = new Date()
  }
  function toggleTimerPause() {
    if (!timerActive) return
    if (timerPausedLeft >= 0) {
      timerEnd = Date.now() + timerPausedLeft * 1000
      timerPausedLeft = -1
    } else {
      timerPausedLeft = timerLeft
      timerEnd = 0
    }
    root.now = new Date()
  }
  function cancelTimer() {
    timerEnd = 0
    timerPausedLeft = -1
    timerTotal = 0
  }
  Timer {
    interval: 250
    repeat: true
    running: root.timerEnd > 0
    onTriggered: {
      if (Date.now() >= root.timerEnd) {
        root.cancelTimer()
        root.pushActivity({ kind: "alert", source: "timer-done", icon: root.glyphs.timer, tint: "orange", title: "Timer Done", value: "", duration: 6000 })
        chime.running = true
      }
    }
  }
  Process {
    id: chime
    command: ["sh", "-c", "for f in /usr/share/sounds/freedesktop/stereo/complete.oga /usr/share/sounds/freedesktop/stereo/bell.oga; do [ -f \"$f\" ] && exec pw-play \"$f\"; done; exit 0"]
  }

  // ------------------------------------------------------------ recording
  property bool recording: false
  property real recordingSince: 0
  Timer {
    interval: 2500
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: if (!recProc.running) recProc.running = true
  }
  Process {
    id: recProc
    command: ["pgrep", "--quiet", "-f", "^gpu-screen-recorder"]
    onExited: function(code) {
      var on = code === 0
      if (on && !root.recording) root.recordingSince = Date.now()
      root.recording = on
    }
  }
  function stopRecording() {
    Quickshell.execDetached(["omarchy-capture-screenrecording", "--stop-recording"])
  }

  // ------------------------------------------------------------ microphone privacy dot
  readonly property bool micInUse: {
    if (!root.showMicIndicator) return false
    var nodes = Pipewire.nodes ? Pipewire.nodes.values : []
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (!n || !n.isStream) continue
      var props = n.properties || {}
      if (props["media.class"] === "Stream/Input/Audio" && props["stream.monitor"] !== "true") return true
    }
    return false
  }

  // ------------------------------------------------------------ battery
  readonly property var battery: UPower.displayDevice
  readonly property bool hasBattery: battery && battery.isLaptopBattery
  readonly property int batteryPercent: {
    if (!battery) return 0
    var p = Number(battery.percentage || 0)
    return Math.round(p <= 1 ? p * 100 : p)
  }
  readonly property bool onBattery: UPower.onBattery
  readonly property bool charging: hasBattery && !onBattery
  onOnBatteryChanged: {
    if (!settled || !hasBattery) return
    if (onBattery)
      pushActivity({ kind: "alert", source: "power", icon: Model.batteryGlyph(batteryPercent, false), tint: batteryPercent <= 20 ? "red" : "white", title: "On Battery", value: batteryPercent + "%", duration: 2200 })
    else
      pushActivity({ kind: "alert", source: "power", icon: glyphs.charging, tint: "green", title: "Charging", value: batteryPercent + "%", duration: 2600 })
  }
  property int lastLowWarn: 101
  onBatteryPercentChanged: {
    if (!settled || !hasBattery) return
    if (!onBattery) { lastLowWarn = 101; return }
    var levels = [20, 10, 5]
    for (var i = 0; i < levels.length; i++) {
      if (batteryPercent <= levels[i] && lastLowWarn > levels[i]) {
        lastLowWarn = levels[i]
        pushActivity({ kind: "alert", source: "power", icon: glyphs.batteryAlert, tint: "red", title: "Low Battery", value: batteryPercent + "%", duration: 4000 })
        break
      }
    }
  }

  // ------------------------------------------------------------ bluetooth
  Instantiator {
    model: Bluetooth.devices
    delegate: QtObject {
      required property var modelData
      readonly property bool connected: modelData ? !!modelData.connected : false
      onConnectedChanged: root.bluetoothChanged(modelData, connected)
    }
  }
  function bluetoothChanged(dev, connected) {
    if (!settled || !dev) return
    var icon = String(dev.icon || "")
    var audio = icon.indexOf("audio") !== -1 || icon.indexOf("headset") !== -1 || icon.indexOf("headphone") !== -1
    var level = dev.batteryAvailable ? Math.round((dev.battery <= 1 ? dev.battery * 100 : dev.battery)) + "%" : ""
    pushActivity({
      kind: "alert", source: "bluetooth",
      icon: audio ? glyphs.headphones : glyphs.bluetooth,
      tint: connected ? "blue" : "secondary",
      title: String(dev.name || dev.deviceName || "Bluetooth"),
      value: connected ? (level || "Connected") : "Disconnected",
      duration: 2600
    })
  }

  // ------------------------------------------------------------ do not disturb
  property bool dnd: false
  property bool dndLoaded: false
  FileView {
    path: Quickshell.env("HOME") + "/.local/state/omarchy/notifications.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var on = false
      try { on = !!JSON.parse(text() || "{}").doNotDisturb } catch (e) {}
      if (root.dndLoaded && root.settled && on !== root.dnd)
        root.pushActivity({ kind: "alert", source: "dnd", icon: on ? root.glyphs.moon : root.glyphs.bell, tint: on ? "indigo" : "secondary", title: "Do Not Disturb", value: on ? "On" : "Off", duration: 1800 })
      root.dnd = on
      root.dndLoaded = true
    }
  }

  // ------------------------------------------------------------ notifications
  // The Omarchy notification daemon persists each live popup as one JSON file
  // (removed/archived when the popup leaves). Watching that folder mirrors
  // new notifications into the island without a second D-Bus server.
  readonly property string notifDir: Quickshell.env("HOME") + "/.local/state/omarchy/notifications"
  property var seenNotifs: ({})
  property bool notifPrimed: false
  property string notifFile: ""

  FolderListModel {
    id: notifFolder
    folder: "file://" + root.notifDir
    nameFilters: ["*.json"]
    showDirs: false
    sortField: FolderListModel.Name
    sortReversed: true
    onStatusChanged: if (status === FolderListModel.Ready) root.scanNotifs()
    onCountChanged: root.scanNotifs()
  }
  function scanNotifs() {
    if (notifFolder.status !== FolderListModel.Ready) return
    var present = {}
    var fresh = ""
    for (var i = 0; i < notifFolder.count; i++) {
      var name = String(notifFolder.get(i, "fileName") || "")
      if (!name) continue
      present[name] = true
      if (!seenNotifs[name] && fresh === "") fresh = name
    }
    var next = {}
    for (var k in present) next[k] = true
    seenNotifs = next
    if (!notifPrimed) { notifPrimed = true; return }
    // A popup the user dismissed elsewhere shouldn't keep its island peek.
    if (activity && activity.kind === "notification" && !present[activity.file]) finishActivity()
    if (fresh !== "" && showNotifications) {
      notifFile = ""
      notifFile = root.notifDir + "/" + fresh
    }
  }
  FileView {
    id: notifReader
    path: root.notifFile
    printErrors: false
    onLoaded: {
      var d = null
      try { d = JSON.parse(text() || "{}") } catch (e) { return }
      var summary = Model.plainText(d.summary)
      var body = Model.plainText(d.body)
      if (summary === "" && body === "") return
      var image = String(d.image || "")
      var appIcon = String(d.appIcon || "")
      var iconUrl = image !== "" ? image
        : appIcon.indexOf("/") !== -1 || appIcon.indexOf("file:") === 0 ? appIcon
        : appIcon !== "" ? Quickshell.iconPath(appIcon, true) : ""
      var file = root.notifFile.substring(root.notifFile.lastIndexOf("/") + 1)
      root.pushActivity({
        kind: "notification", source: "notification", file: file,
        app: String(d.app || ""), title: summary !== "" ? summary : body,
        body: summary !== "" ? body : "", image: iconUrl,
        urgent: Number(d.urgency) === 2,
        duration: Number(d.urgency) === 2 ? 8000 : 5000
      })
    }
  }
  function notificationActivate() {
    Quickshell.execDetached(["omarchy-shell", "-q", "notifications", "invokeLast"])
    finishActivity()
  }
  function notificationDismiss() {
    Quickshell.execDetached(["omarchy-shell", "-q", "notifications", "dismissOne"])
    finishActivity()
  }

  // ------------------------------------------------------------ transients
  // One activity shows at a time. A repeat of the same source (holding the
  // volume key) updates in place; HUDs and alerts cut in front of queued
  // notifications, and anything else waits its turn.
  property var activity: null
  property var queue: []
  property int activitySerial: 0

  function pushActivity(t) {
    if (!t) return
    if (activity && activity.source === t.source && t.kind === activity.kind) {
      activity = t
      activityTimer.interval = t.duration
      activityTimer.restart()
      return
    }
    if (!activity) { showActivity(t); return }
    var quick = t.kind === "hud" || t.kind === "alert"
    if (quick && activity.kind !== "notification") {
      // A key press answers the last one: swap in place, no queueing.
      showActivity(t)
      return
    }
    if (quick) {
      queue = [activity].concat(queue)
      showActivity(t)
      return
    }
    var q = queue.slice()
    for (var i = 0; i < q.length; i++) {
      if (q[i].source === t.source && q[i].kind === t.kind) { q[i] = t; queue = q; return }
    }
    q.push(t)
    queue = q.slice(-6)
  }
  function showActivity(t) {
    activity = t
    activitySerial++
    activityTimer.interval = t.duration
    activityTimer.restart()
  }
  function finishActivity() {
    activityTimer.stop()
    if (queue.length > 0) {
      var q = queue.slice()
      var next = q.shift()
      queue = q
      // Let the island settle for a beat between two activities, so each
      // one reads as its own event instead of a jump cut.
      activity = null
      nextActivityTimer.pending = next
      nextActivityTimer.restart()
    } else {
      activity = null
    }
  }
  function holdActivity(hold) {
    if (!activity) return
    if (hold) activityTimer.stop()
    else { activityTimer.interval = 1500; activityTimer.restart() }
  }
  Timer {
    id: activityTimer
    onTriggered: root.finishActivity()
  }
  Timer {
    id: nextActivityTimer
    property var pending: null
    interval: 260
    onTriggered: if (pending) { root.showActivity(pending); pending = null }
  }

  // ------------------------------------------------------------ live activity
  readonly property string live: recording ? "recording"
    : timerActive ? "timer"
    : mediaLive ? "media"
    : ""

  // ------------------------------------------------------------ volume by scroll
  function scrollVolumeBy(delta) {
    if (!root.scrollVolume) return
    Quickshell.execDetached(["omarchy-audio-output-volume", delta > 0 ? "+2" : "-2"])
  }

  // ------------------------------------------------------------ expanded (shared across windows)
  // Only the most recent screen to open wins; another screen opening closes it.
  property var expandedWindow: null
  signal collapseAll()

  // ------------------------------------------------------------ bar footprint
  // The bar spacer reads this so bar widgets flow around the notch the way
  // the macOS menu bar flows around the camera housing.
  readonly property int barFootprint: {
    var g = Model.geometry(root.live !== "" ? "compact" : "idle", root.notchWidth, root.notchHeight, 0)
    return g.w + g.rt * 2
  }

  // ------------------------------------------------------------ IPC
  IpcHandler {
    // Taking over the `osd` target routes every `omarchy osd` call (volume,
    // brightness, keyboard light, mic, media keys) into the island — the
    // stock OSD plugin must be disabled for this (see README).
    target: root.replaceOsd ? "osd" : "dynamic-island-osd"
    function show(payloadJson: string): string {
      var p = {}
      try { p = JSON.parse(payloadJson || "{}") } catch (e) { return "bad-json" }
      root.pushActivity(Model.osdTransient(p))
      return "ok"
    }
    function close(): string {
      if (root.activity && (root.activity.kind === "hud" || root.activity.kind === "alert")) root.finishActivity()
      return "ok"
    }
    function state(): string { return root.activity ? "open" : "closed" }
    function ping(): string { return "ok" }
  }

  IpcHandler {
    target: "island"
    function state(): string {
      return JSON.stringify({
        live: root.live, activity: root.activity, queued: root.queue.length,
        media: { title: root.trackTitle, artist: root.trackArtist, playing: root.isPlaying, player: root.playerName },
        timerLeft: Math.round(root.timerLeft), recording: root.recording, micInUse: root.micInUse,
        battery: root.batteryPercent, charging: root.charging, dnd: root.dnd,
        style: root.style, palette: root.palette, font: root.textFont, notchHeight: root.notchHeight
      })
    }
    function ping(): string { return "ok" }
    function expand(): string { root.expandRequested(); return "ok" }
    function collapse(): string { root.collapseAll(); return "ok" }
    function timer(seconds: string): string { root.startTimer(Number(seconds)); return "ok" }
    function timerCancel(): string { root.cancelTimer(); return "ok" }
    function alert(icon: string, title: string, value: string): string {
      root.pushActivity({ kind: "alert", source: "ipc-" + title, icon: icon, tint: "white", title: title, value: value, duration: 2500 })
      return "ok"
    }
    function hud(icon: string, percent: string): string {
      root.pushActivity(Model.osdTransient({ icon: icon, value: percent }))
      return "ok"
    }
    function notify(title: string, body: string): string {
      root.pushActivity({ kind: "notification", source: "ipc-notify", file: "", app: "Dynamic Island", title: title, body: body, image: "", urgent: false, duration: 5000 })
      return "ok"
    }
  }
  signal expandRequested()

  // ------------------------------------------------------------ windows
  Variants {
    model: {
      var all = Quickshell.screens
      if (root.monitor === "all" || root.monitor === "") return all
      var out = []
      for (var i = 0; i < all.length; i++) if (all[i].name === root.monitor) out.push(all[i])
      return out.length > 0 ? out : all
    }
    delegate: IslandWindow {
      required property var modelData
      screen: modelData
      service: root
    }
  }
}
