import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import "IslandModel.js" as Model

// One notch per monitor. A full-width, transparent overlay layer whose input
// region is exactly the island, so the desktop and the bar underneath stay
// clickable everywhere else.
PanelWindow {
  id: win

  property var service: null
  readonly property var s: service

  anchors {
    top: true
    left: true
    right: true
  }
  // Room for the largest island plus its drop shadow.
  implicitHeight: s.notchHeight + 174 + 56
  color: "transparent"
  surfaceFormat.opaque: false
  exclusionMode: ExclusionMode.Ignore
  WlrLayershell.namespace: "omarchy-dynamic-island"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
  mask: Region { item: hit }

  // ---------------------------------------------------------------- state
  readonly property var hyprMonitor: Hyprland.monitorFor(win.screen)
  readonly property bool fullscreen: hyprMonitor && hyprMonitor.activeWorkspace
    ? !!hyprMonitor.activeWorkspace.hasFullscreen : false

  property bool hovered: false
  property bool expanded: false
  readonly property var t: s.activity

  readonly property string mode: {
    if (expanded) return "expanded"
    if (t) return t.kind
    if (fullscreen && s.hideInFullscreen && !hovered) return "hidden"
    if (s.live !== "") return "compact"
    return s.showWhenIdle || hovered ? "idle" : "hidden"
  }

  // Views keep drawing the last payload of their kind while they fade out.
  property var lastAlert: ({ icon: "", tint: "white", title: "", value: "" })
  property var lastHud: ({ icon: "", tint: "white", percent: 0, value: "" })
  property var lastNotif: ({ app: "", title: "", body: "", image: "", urgent: false })
  onTChanged: {
    if (!t) return
    if (t.kind === "alert") lastAlert = t
    else if (t.kind === "hud") lastHud = t
    else if (t.kind === "notification") lastNotif = t
  }

  TextMetrics { id: alertTitleMetrics; font.family: s.textFont; font.pixelSize: 13; font.weight: Font.DemiBold; text: win.lastAlert.title || "" }
  TextMetrics { id: alertValueMetrics; font.family: s.textFont; font.pixelSize: 13; font.weight: Font.DemiBold; text: win.lastAlert.value || "" }
  readonly property int alertContentWidth: 20 + 22 + 10 + Math.ceil(alertTitleMetrics.advanceWidth) + 36 + Math.ceil(alertValueMetrics.advanceWidth) + 20

  // ---------------------------------------------------------------- geometry
  function geometryFor(m) {
    return Model.geometry(m, s.notchWidth, s.notchHeight, alertContentWidth)
  }
  readonly property var geom: {
    var g = geometryFor(mode)
    // Hover "breath": the notch swells slightly under the pointer, inviting
    // a click — the tactile cue macOS notch apps use in place of haptics.
    if (hovered && (mode === "idle" || mode === "compact"))
      return { w: g.w + 18, h: g.h + 4, rb: g.rb + 2, rt: g.rt + 1 }
    return g
  }

  // Animated body geometry. Growing uses a bouncier spring (the island
  // "pops" open with a little overshoot); shrinking is more damped, so it
  // tucks back into the notch without wobbling.
  property real bw: 0
  property real bh: 0
  property real brb: 0
  property real brt: 0
  property bool growing: true
  function applyGeometry(animate) {
    var g = geom
    growing = g.w * g.h >= bw * bh
    if (!animate) {
      bwBehavior.enabled = false; bhBehavior.enabled = false; brbBehavior.enabled = false; brtBehavior.enabled = false
    }
    bw = g.w
    bh = g.h
    brb = g.rb
    brt = g.rt
    bwBehavior.enabled = true; bhBehavior.enabled = true; brbBehavior.enabled = true; brtBehavior.enabled = true
  }
  onGeomChanged: applyGeometry(true)
  Component.onCompleted: applyGeometry(false)

  readonly property real springK: growing ? 3.3 : 4.4
  readonly property real springD: growing ? 0.25 : 0.42
  Behavior on bw { id: bwBehavior; SpringAnimation { spring: win.springK; damping: win.springD; epsilon: 0.25 } }
  Behavior on bh { id: bhBehavior; SpringAnimation { spring: win.springK * 1.08; damping: win.springD; epsilon: 0.25 } }
  Behavior on brb { id: brbBehavior; SpringAnimation { spring: win.springK; damping: 0.5; epsilon: 0.1 } }
  Behavior on brt { id: brtBehavior; SpringAnimation { spring: win.springK; damping: 0.5; epsilon: 0.1 } }

  // How far the island has grown past the bare notch; drives the shadow.
  readonly property real lift: Model.clamp((bh - s.notchHeight) / 60, 0, 1)

  // ---------------------------------------------------------------- behavior
  function setExpanded(on) {
    if (on === expanded) return
    expanded = on
    if (on) {
      s.expandedWindow = win
      s.positionWatchers++
    } else {
      s.positionWatchers = Math.max(0, s.positionWatchers - 1)
    }
  }
  Connections {
    target: win.s
    function onExpandedWindowChanged() { if (win.s.expandedWindow !== win) win.setExpanded(false) }
    function onCollapseAll() { win.setExpanded(false) }
    function onExpandRequested() {
      var focused = Hyprland.focusedMonitor
      if (!focused || focused.name === win.screen.name) win.setExpanded(true)
    }
  }
  Component.onDestruction: if (expanded) s.positionWatchers = Math.max(0, s.positionWatchers - 1)

  // The pointer has to rest on the notch for a moment before it opens, so
  // sweeping the cursor across the top of the screen doesn't trigger it.
  Timer {
    id: dwellTimer
    interval: win.s.hoverDelay
    onTriggered: if (win.hovered && (win.mode === "idle" || win.mode === "compact")) win.setExpanded(true)
  }
  Timer {
    id: leaveTimer
    interval: win.expanded ? 380 : 140
    onTriggered: {
      win.hovered = false
      if (win.t) win.s.holdActivity(false)
      win.setExpanded(false)
    }
  }

  // Input only reaches this window inside the mask (the island), so hover
  // on the stage is hover on the island — including over its buttons.
  Item {
    id: stage
    anchors.fill: parent

    HoverHandler {
      id: hover
      onHoveredChanged: {
        if (hovered) {
          leaveTimer.stop()
          win.hovered = true
          if (win.t) win.s.holdActivity(true)
          if (win.s.openOnHover && (win.mode === "idle" || win.mode === "compact")) dwellTimer.restart()
        } else {
          dwellTimer.stop()
          leaveTimer.restart()
        }
      }
    }

    // ---------------------------------------------------------------- input region
    Item {
      id: hit
      x: Math.round((win.width - win.bw) / 2)
      y: 0
      width: Math.max(1, win.bw)
      // Hidden (fullscreen): a 3px strip along the top edge still reveals it.
      height: win.mode === "hidden" ? 3 : Math.max(3, win.bh)

      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
        property real wheelAccum: 0
        cursorShape: win.mode === "hidden" ? Qt.ArrowCursor : Qt.PointingHandCursor
        onClicked: function(mouse) {
          var m = win.mode
          if (mouse.button === Qt.MiddleButton) { win.s.mediaToggle(); return }
          if (m === "notification") {
            if (mouse.button === Qt.RightButton) win.s.notificationDismiss()
            else win.s.notificationActivate()
            return
          }
          if (m === "hud" || m === "alert") {
            win.s.finishActivity()
            if (mouse.button === Qt.LeftButton) win.setExpanded(true)
            return
          }
          dwellTimer.stop()
          win.setExpanded(!win.expanded)
        }
        onWheel: function(wheel) {
          if (win.mode === "expanded" || win.mode === "hidden" || wheel.angleDelta.y === 0) return
          // Scrolling says "adjust", not "open": hold off the hover-open.
          if (dwellTimer.running) dwellTimer.restart()
          wheelAccum += wheel.angleDelta.y
          // Touchpads send many small deltas; step once per wheel notch.
          if (Math.abs(wheelAccum) >= 120 || Math.abs(wheel.angleDelta.y) >= 120) {
            win.s.scrollVolumeBy(wheelAccum)
            wheelAccum = 0
          }
        }
      }
    }

    // ---------------------------------------------------------------- island
    Item {
      id: island
      x: Math.round((win.width - shape.width) / 2)
      y: 0
      width: shape.width
      height: Math.max(0, win.bh)

      Item {
        id: shapeHolder
        width: shape.width
        height: shape.height
        layer.enabled: win.lift > 0.02
        layer.effect: MultiEffect {
          shadowEnabled: true
          shadowColor: Qt.rgba(0, 0, 0, 0.6 * win.lift)
          shadowBlur: 1.0
          blurMax: 36
          shadowVerticalOffset: 10 * win.lift
          autoPaddingEnabled: true
        }

        NotchShape {
          id: shape
          bodyWidth: Math.max(0, win.bw)
          bodyHeight: Math.max(0, win.bh)
          rb: win.brb
          rt: win.brt
          fillColor: win.s.islandColor
          Behavior on fillColor { ColorAnimation { duration: 300 } }
        }
      }

      // Content area: the body of the notch, clipped so views are revealed by
      // the growing shape rather than drawn ahead of it.
      Item {
        id: body
        x: shape._rt
        width: Math.max(0, win.bw)
        height: Math.max(0, win.bh)
        clip: true

        // ------------------------------------------------ compact live activities
        Reveal {
          id: compactMedia
          shown: win.mode === "compact" && win.s.live === "media"
          width: win.geometryFor("compact").w
          height: win.s.notchHeight
          anchors.horizontalCenter: parent.horizontalCenter
          inDelay: 60

          Artwork {
            x: 10
            anchors.verticalCenter: parent.verticalCenter
            width: win.s.notchHeight - 8
            height: width
            radius: 5
            source: win.s.trackArt
            fallbackGlyph: win.s.glyphs.music
            glyphFont: win.s.iconFont
            glyphColor: win.s.mediaAccent
          }
          Waveform {
            anchors.right: parent.right
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            height: win.s.notchHeight - 12
            playing: win.s.isPlaying
            color: win.s.mediaAccent
          }
        }

        Reveal {
          shown: win.mode === "compact" && win.s.live === "timer"
          width: win.geometryFor("compact").w
          height: win.s.notchHeight
          anchors.horizontalCenter: parent.horizontalCenter
          inDelay: 60

          Text {
            x: 13
            anchors.verticalCenter: parent.verticalCenter
            text: win.s.glyphs.timer
            font.family: win.s.iconFont
            font.pixelSize: 15
            color: win.s.tint("orange")
          }
          Text {
            anchors.right: parent.right
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            text: Model.formatTime(Math.ceil(win.s.timerLeft))
            font.family: win.s.textFont
            font.pixelSize: 13
            font.weight: Font.DemiBold
            font.features: { "tnum": 1 }
            color: win.s.tint("orange")
            opacity: win.s.timerPausedLeft >= 0 ? 0.55 : 1
          }
        }

        Reveal {
          shown: win.mode === "compact" && win.s.live === "recording"
          width: win.geometryFor("compact").w
          height: win.s.notchHeight
          anchors.horizontalCenter: parent.horizontalCenter
          inDelay: 60

          Rectangle {
            x: 15
            anchors.verticalCenter: parent.verticalCenter
            width: 9
            height: 9
            radius: 4.5
            color: win.s.tint("red")
            SequentialAnimation on opacity {
              running: win.s.recording
              loops: Animation.Infinite
              NumberAnimation { to: 0.35; duration: 700; easing.type: Easing.InOutSine }
              NumberAnimation { to: 1; duration: 700; easing.type: Easing.InOutSine }
            }
          }
          Text {
            anchors.right: parent.right
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            text: { win.s.now; return Model.formatTime((Date.now() - win.s.recordingSince) / 1000) }
            font.family: win.s.textFont
            font.pixelSize: 13
            font.weight: Font.DemiBold
            font.features: { "tnum": 1 }
            color: win.s.tint("red")
          }
        }

        // Privacy indicator: orange dot while any app is capturing the mic.
        Rectangle {
          width: 6
          height: 6
          radius: 3
          x: parent.width - 14
          anchors.verticalCenter: parent.top
          anchors.verticalCenterOffset: win.s.notchHeight / 2
          color: win.s.tint("orange")
          opacity: win.s.micInUse && win.mode === "idle" ? 1 : 0
          Behavior on opacity { NumberAnimation { duration: 250 } }
        }

        // ------------------------------------------------ alert (wide pill)
        Reveal {
          shown: win.mode === "alert"
          width: win.geometryFor("alert").w
          height: win.geometryFor("alert").h
          anchors.horizontalCenter: parent.horizontalCenter

          Row {
            x: 18
            anchors.verticalCenter: parent.verticalCenter
            spacing: 10
            Text {
              width: 20
              horizontalAlignment: Text.AlignHCenter
              anchors.verticalCenter: parent.verticalCenter
              text: win.lastAlert.icon || ""
              font.family: win.s.iconFont
              font.pixelSize: 17
              color: win.s.tint(win.lastAlert.tint)
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: win.lastAlert.title || ""
              font: alertTitleMetrics.font
              color: win.s.textColor
              elide: Text.ElideRight
              width: Math.min(implicitWidth, 300)
            }
          }
          Text {
            anchors.right: parent.right
            anchors.rightMargin: 20
            anchors.verticalCenter: parent.verticalCenter
            text: win.lastAlert.value || ""
            font: alertValueMetrics.font
            color: win.lastAlert.tint === "white" || win.lastAlert.tint === "secondary" ? win.s.secondaryText : win.s.tint(win.lastAlert.tint)
          }
        }

        // ------------------------------------------------ HUD (volume, brightness…)
        Reveal {
          shown: win.mode === "hud"
          width: win.geometryFor("hud").w
          height: win.geometryFor("hud").h
          anchors.horizontalCenter: parent.horizontalCenter

          Item {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: 20
            anchors.rightMargin: 20
            y: win.s.notchHeight + 2
            height: parent.height - win.s.notchHeight - 12

            Text {
              id: hudIcon
              width: 22
              anchors.verticalCenter: parent.verticalCenter
              horizontalAlignment: Text.AlignHCenter
              text: win.lastHud.icon || ""
              font.family: win.s.iconFont
              font.pixelSize: 18
              color: win.s.tint(win.lastHud.tint)
            }
            Text {
              id: hudValue
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              width: 38
              horizontalAlignment: Text.AlignRight
              text: win.lastHud.value || ""
              font.family: win.s.textFont
              font.pixelSize: 13
              font.weight: Font.DemiBold
              font.features: { "tnum": 1 }
              color: win.s.secondaryText
            }
            Rectangle {
              anchors.left: hudIcon.right
              anchors.leftMargin: 14
              anchors.right: hudValue.left
              anchors.rightMargin: 12
              anchors.verticalCenter: parent.verticalCenter
              height: 6
              radius: 3
              color: win.s.trackColor
              Rectangle {
                height: parent.height
                radius: parent.radius
                width: Math.max(parent.height, parent.width * Model.clamp((win.lastHud.percent || 0) / 100, 0, 1))
                opacity: (win.lastHud.percent || 0) > 0 ? 1 : 0.0
                color: win.s.palette === "theme" ? win.s.tint("accent") : win.s.textColor
                Behavior on width { SpringAnimation { spring: 6; damping: 0.45; epsilon: 0.3 } }
              }
            }
          }
        }

        // ------------------------------------------------ notification peek
        Reveal {
          shown: win.mode === "notification"
          width: win.geometryFor("notification").w
          height: win.geometryFor("notification").h
          anchors.horizontalCenter: parent.horizontalCenter

          Artwork {
            id: notifImage
            x: 18
            y: Math.round((parent.height - height) / 2) + 4
            width: 44
            height: 44
            radius: 12
            source: win.lastNotif.image || ""
            fallbackGlyph: win.s.glyphs.bell
            glyphFont: win.s.iconFont
            glyphColor: win.lastNotif.urgent ? win.s.tint("red") : win.s.textColor
            fallbackColor: Qt.rgba(1, 1, 1, 0.12)
          }
          Column {
            anchors.left: notifImage.right
            anchors.leftMargin: 12
            anchors.right: parent.right
            anchors.rightMargin: 20
            anchors.verticalCenter: notifImage.verticalCenter
            spacing: 1

            Item {
              width: parent.width
              height: appLabel.implicitHeight
              Text {
                id: appLabel
                anchors.left: parent.left
                anchors.right: nowLabel.left
                anchors.rightMargin: 8
                text: win.lastNotif.app || ""
                font.family: win.s.textFont
                font.pixelSize: 11
                font.weight: Font.Medium
                color: win.s.secondaryText
                elide: Text.ElideRight
              }
              Text {
                id: nowLabel
                anchors.right: parent.right
                text: "now"
                font.family: win.s.textFont
                font.pixelSize: 11
                color: win.s.secondaryText
              }
            }
            Text {
              width: parent.width
              text: win.lastNotif.title || ""
              font.family: win.s.textFont
              font.pixelSize: 14
              font.weight: Font.DemiBold
              color: win.lastNotif.urgent ? win.s.tint("red") : win.s.textColor
              elide: Text.ElideRight
              maximumLineCount: 1
            }
            Text {
              width: parent.width
              visible: text !== ""
              text: win.lastNotif.body || ""
              font.family: win.s.textFont
              font.pixelSize: 12
              color: win.s.secondaryText
              elide: Text.ElideRight
              maximumLineCount: 1
            }
          }
        }

        // ------------------------------------------------ expanded
        Reveal {
          shown: win.mode === "expanded"
          width: win.geometryFor("expanded").w
          height: win.geometryFor("expanded").h
          anchors.horizontalCenter: parent.horizontalCenter
          inDelay: 130
          inDuration: 380

          ExpandedView {
            anchors.fill: parent
            s: win.s
            active: win.mode === "expanded"
          }
        }
      }
    }
  }
}
