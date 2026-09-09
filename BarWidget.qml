import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// OmaShield — bar entry.
//
// One shield glyph that opens the OmaShield popup. The panel owns the live
// status (it keeps process work out of the bar side of the contract), and the
// bar widget reads its state back through the loader so the icon reflects ON
// vs OFF without starting another probe itself.

BarWidget {
  id: root
  moduleName: "io.github.hogar1977.omashield"

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  // ---- Shape contract for shell.summon/hide/toggle routing.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  // Projected from the loaded panel so the bar glyph never starts a probe.
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

  function refresh() {
    if (panelLoader.item && panelLoader.item.reload) panelLoader.item.reload()
  }

  // Forwarded so this widget can stand in for the panel as the bar's popout
  // identity (KeyboardPanel reads popoutSwitchClosing off its owner).
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

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
    function refresh(): void { root.broadcast("refresh") }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.shieldOn ? "\uDB81\uDD65" : "\uF512"
    tooltipText: root.shieldOn ? "OmaShield — ON" : "OmaShield — OFF"
    // Off shields the icon: dimmed and tinted with the urgent colour so a
    // glance at the bar answers "am I protected?" as clearly as the popup.
    opacity: root.shieldOn ? 1 : 0.55
    active: !root.shieldOn

    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.refresh()
      else root.togglePanel()
    }
  }
}