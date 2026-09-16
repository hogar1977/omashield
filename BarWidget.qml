import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// OmaShield bar entry: availability glyph + shield glyph, both opening the
// popup. Availability mirrors the stock Omarchy-update widget (same probe,
// same glyph, same polling) — disable the stock widget to avoid two updaters.

BarWidget {
  id: root
  moduleName: "io.github.hogar1977.omashield"

  property bool updatesAvailable: false

  // Absolute CLI path (mirrors the panel's resolver).
  readonly property string cliBin: {
    var u = String(Qt.resolvedUrl("scripts/aur-shield"))
    if (u.substring(0, 7) === "file://") u = decodeURIComponent(u.substring(7))
    return u
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = glyphRow
    if ("hostWidget" in target) target.hostWidget = root
  }

  // ---- Shape contract for shell.summon/hide/toggle routing.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool shieldOn: panelLoader.item ? panelLoader.item.shieldOn === true : true

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function togglePanel() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  // Re-probe availability and re-read panel status.
  function probeUpdates() {
    if (!updateProc.running) updateProc.running = true
  }

  function refresh() {
    root.probeUpdates()
    if (panelLoader.item && panelLoader.item.reload) panelLoader.item.reload()
  }

  // Popout identity forwarded so the widget can stand in for the panel.
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  implicitWidth: glyphRow.implicitWidth
  implicitHeight: Math.max(updatesButton.implicitHeight, shieldButton.implicitHeight)

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "io.github.hogar1977.omashield"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function refresh(): void { root.probeUpdates() }
  }

  Process {
    id: updateProc
    running: false
    command: [root.cliBin, "pending"]
    stdout: StdioCollector { id: pendingStdout; waitForEnd: true }
    stderr: StdioCollector { id: pendingStderr; waitForEnd: true }
    onExited: function(exitCode) {
      var total = 0
      var lines = String(pendingStdout.text || "").split("\n")
      for (var i = 0; i < lines.length; i++) {
        var m = lines[i].match(/^total:\s*(\d+)$/)
        if (m) total = parseInt(m[1], 10)
      }
      root.updatesAvailable = exitCode === 0 && total > 0
    }
  }

  Timer {
    interval: 21600000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.probeUpdates()
  }

  Row {
    id: glyphRow
    anchors.verticalCenter: parent.verticalCenter

    // Stolen from the stock Omarchy-update widget: same glyph, same sizing,
    // shown only while updates are available. Opens our popup instead of the
    // stock upgrader.
    BarIconButton {
      id: updatesButton
      bar: root.bar
      visible: root.updatesAvailable
      text: "\uf021"
      slotSize: Style.bar.statusSlot
      fontSize: Style.font.caption
      tooltipText: "Updates available — open OmaShield"

      onPressed: function(b) {
        if (b === Qt.MiddleButton) root.refresh()
        else root.togglePanel()
      }
    }

    BarIconButton {
      id: shieldButton
      bar: root.bar
      text: root.shieldOn ? "\uDB81\uDD65" : "\uF512"
      tooltipText: root.shieldOn ? "OmaShield — ON" : "OmaShield — OFF"
      // Dimmed and tinted while OFF so the bar answers "am I protected?".
      opacity: root.shieldOn ? 1 : 0.55
      active: !root.shieldOn

      onPressed: function(b) {
        if (b === Qt.MiddleButton) root.refresh()
        else root.togglePanel()
      }
    }
  }
}
