import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// OmaShield — popup.
//
// The faceplate for the guarded flow. It shows the current state (ON/OFF),
// the guard tools it found, and the entry points the Main Menu routes through
// (Update and Install > AUR), plus the uninstall action.
//
// All real work happens in the omarchy-omashield CLI, never in QML. The
// panel runs short, fast commands and parses their plain output; anything
// that needs a terminal (the interactive pickers) is launched through
// omarchy's floating-terminal-with-presentation helper so it keeps sudo and
// interactive UI, and nothing here ever blocks on it.

Panel {
  id: root
  moduleName: "io.github.hogar1977.omashield"
  ipcTarget: "io.github.hogar1977.omashield"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // Absolute path to our own CLI. The panel reaches it directly so first-ON
  // wiring works before ~/.local/bin/omarchy-omashield exists; the menu
  // keeps using the bare name once the symlink is in place.
  readonly property string cliBin: {
    var u = String(Qt.resolvedUrl("scripts/aur-shield"))
    if (u.substring(0, 7) === "file://") u = decodeURIComponent(u.substring(7))
    return u
  }

  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color secondaryForeground: Util.alpha(contentForeground, 0.54)

  // ---- Live status --------------------------------------------------------

  property bool shieldOn: true
  property string scanState: "missing"
  property string guardState: "missing"
  property string hookState: "absent"
  property string menuState: "stock"
  property string widgetState: "unknown"
  property string pendingText: "0"
  property bool statusLoaded: false
  property bool statusFailed: false
  property string actionMessage: ""

  function reload() {
    if (!statusProcess.running) statusProcess.running = true
  }

  function applyStatus(text) {
    shieldOn = true
    scanState = "missing"
    guardState = "missing"
    hookState = "absent"
    menuState = "stock"
    widgetState = "unknown"
    pendingText = "0"
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var m = lines[i].match(/^([^:]+):\s*(.*)$/)
      if (!m) continue
      var key = m[1]
      var value = m[2]
      if (key === "state") shieldOn = value === "on"
      else if (key === "aur-scan") scanState = value
      else if (key === "yay-guard") guardState = value
      else if (key === "native-hook") hookState = value
      else if (key === "menu") menuState = value
      else if (key === "widget") widgetState = value
      else if (key === "pending-updates") pendingText = value
    }
    statusLoaded = true
    statusFailed = false
  }

  // The ON gate: with a fresh status showing missing tools, show the
  // dependencies dialog instead of flipping. Otherwise the CLI enforces the
  // same gate headlessly (exit 3) and the dialog opens from there.
  function tryToggle() {
    if (!root.shieldOn && root.statusLoaded
        && (root.scanState !== "installed" || root.guardState !== "installed")) {
      depsDialog.opened = true
      return
    }
    root.setShield(!root.shieldOn)
  }

  function setShield(on) {
    var label = on ? "on" : "off"
    shieldOn = on  // optimistic
    actionMessage = ""
    setProcess.command = [root.cliBin, "set", label]
    setProcess.running = true
  }

  // A terminal owns the interactive flows, exactly like the Main Menu entries
  // did before the override — so sudo prompts stay on screen and gum/fzf can
  // use them.
  function launchFlow(mode) {
    var cli = Util.shellQuote(root.cliBin)
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation",
      "bash", "-c",
      "omarchy-show-logo; " + cli + " " + mode +
      "; if (($? != 130)); then omarchy-show-done; fi"])
    root.close()
  }

  function askUninstall() {
    uninstallConfirm.opened = true
  }

  function runUninstall() {
    actionMessage = ""
    uninstallProcess.command = [root.cliBin, "uninstall", "--yes"]
    uninstallProcess.running = true
    root.close()
  }

  // ---- Surface ------------------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(430))

    // Size to the card's own needs, capped by what the host allows.
    contentHeight: panel.cappedContentHeight(column.childrenRect.height + Style.space(40))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: uninstallConfirm.opened || depsDialog.opened

      onCloseRequested: root.close()
      onActivateRequested: root.tryToggle()
      onTextKey: function(t) {
        if (t === "u" || t === "U") root.launchFlow("update")
        else if (t === "i" || t === "I") root.launchFlow("install-aur")
        else if (t === "a" || t === "A") root.launchFlow("audit")
      }
    }

    Column {
      id: column
      anchors.left: parent.left
      anchors.leftMargin: Style.space(22)
      anchors.right: parent.right
      anchors.rightMargin: Style.space(22)
      anchors.top: parent.top
      anchors.topMargin: Style.space(20)
      spacing: Style.space(18)

      // ---- Header ---------------------------------------------------------
      Item {
        width: parent.width
        height: titleRow.height + Style.space(4) + Math.max(statusLine.implicitHeight, Style.space(12))

        Item {
          id: titleRow
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          height: Math.max(titleIcon.implicitHeight, title.implicitHeight, switchRow.height)

          Text {
            id: titleIcon
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.baseline: title.baseline
            text: root.shieldOn ? "\uDB81\uDD65" : "\uF512"
            color: root.shieldOn ? Color.accent : Util.alpha(root.contentForeground, 0.4)
            font.family: root.contentFontFamily
            font.pixelSize: title.font.pixelSize
          }

          Text {
            id: title
            textFormat: Text.PlainText
            anchors.left: titleIcon.right
            anchors.leftMargin: Style.space(8)
            anchors.top: parent.top
            text: "OmaShield"
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.display
            font.bold: true
          }

          Row {
            id: switchRow
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(8)

            Text {
              textFormat: Text.PlainText
              text: root.shieldOn ? "ON" : "OFF"
              color: root.shieldOn ? Color.accent : root.secondaryForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              verticalAlignment: Text.AlignVCenter
            }

            ToggleSwitch {
              checked: root.shieldOn
              busy: setProcess.running
              accent: Color.accent
              foreground: root.contentForeground
              onToggled: root.tryToggle()
            }
          }
        }

        // The status line, on its own line under the title so it spans the
        // full popup width with nothing boxing it in on either side.
        Text {
          id: statusLine
          textFormat: Text.PlainText
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: titleRow.bottom
          text: root.widgetState === "disabled"
            ? "Widget disabled — running stock"
            : (root.statusLoaded
              ? (root.shieldOn
                  ? "On — updates are reviewed"
                  : "Off — stock omarchy flow")
              : (root.statusFailed ? "status unavailable" : "reading status…"))
          elide: Text.ElideRight
          color: root.statusFailed || root.widgetState === "disabled" ? Color.urgent : root.secondaryForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
        }
      }

      PanelSeparator { foreground: root.contentForeground }

      // ---- Guard stack ----------------------------------------------------
      Text {
        id: stackCaption
        textFormat: Text.PlainText
        width: parent.width
        text: "GUARD CHAIN"
        color: root.secondaryForeground
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }

      Column {
        width: parent.width
        spacing: Style.space(6)

        Repeater {
          model: [
            { label: "aur-scan (static analysis)", good: root.scanState === "installed" },
            { label: "yay-guard (heuristics)",     good: root.guardState === "installed" },
            { label: "native yay hooks",           good: root.hookState === "active" },
            { label: "Menu routed through shield", good: root.menuState === "overridden" }
          ]

          Item {
            required property var modelData
            width: parent.width
            height: Style.space(20)

            readonly property bool rowOn: root.shieldOn
            readonly property bool rowGood: modelData.good

            Text {
              textFormat: Text.PlainText
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: parent.rowOn
                ? (parent.rowGood ? "✓" : "✗") + "  " + parent.modelData.label
                : "–  " + parent.modelData.label
              color: !parent.rowOn
                ? root.secondaryForeground
                : (parent.rowGood ? root.contentForeground : Color.urgent)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.body
            }

            Text {
              textFormat: Text.PlainText
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: parent.rowOn ? (parent.rowGood ? "ready" : "missing") : "off"
              color: !parent.rowOn
                ? root.secondaryForeground
                : (parent.rowGood ? secondaryForeground : Util.alpha(Color.urgent, 0.9))
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
      }

      Item {
        width: parent.width
        height: Style.space(20)
        visible: root.pendingText !== "0"

        Text {
          textFormat: Text.PlainText
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          // A saved selection is waiting for the next omarchy update.
          text: "→ " + root.pendingText + " update(s) preselected for the next update."
          color: Color.accent
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }

      Item {
        width: parent.width
        height: Style.space(20)
        visible: root.actionMessage !== ""

        Text {
          textFormat: Text.PlainText
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: root.actionMessage
          color: root.secondaryForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }

      // ---- Actions ---------------------------------------------------------
      Row {
        width: parent.width
        spacing: Style.space(8)

        Button {
          id: updateButton
          text: "Update"
          foreground: root.contentForeground
          fontFamily: root.contentFontFamily
          onClicked: root.launchFlow("update")
        }
        Button {
          text: "Install AUR"
          foreground: root.contentForeground
          fontFamily: root.contentFontFamily
          onClicked: root.launchFlow("install-aur")
        }
        Button {
          text: "Audit AUR"
          foreground: root.contentForeground
          fontFamily: root.contentFontFamily
          onClicked: root.launchFlow("audit")
        }
        Item { width: 4; height: 1 }

        Button {
          text: "Uninstall"
          foreground: Color.urgent
          fontFamily: root.contentFontFamily
          accent: Color.urgent
          onClicked: root.askUninstall()
        }
      }

      // ---- Key hints -------------------------------------------------------
      Column {
        width: parent.width
        spacing: Style.space(4)

        PanelSeparator { foreground: root.contentForeground }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: "toggle  ·  u update  ·  i install  ·  a audit  ·  esc close"
          color: root.secondaryForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }

    // ---- Dependencies dialog: the ON gate ----------------------------------
    // Lives inside the popup card (same window layer): OmaShield stays OFF
    // until aur-scanner and yay-guard are installed through the standard
    // procedure. Confirming only dismisses; switching ON again re-checks.

    ConfirmDialog {
      id: depsDialog
      anchors.fill: parent
      z: 10
      opened: false
      message: "OmaShield needs aur-scanner and yay-guard before it can switch ON. " +
               "Install them through the standard procedure (Main Menu > Install > Package, " +
               "or yay -S aur-scanner yay-guard), then switch ON again. " +
               "OmaShield stays OFF until then."
      cancelText: "Later"
      confirmText: "Understood"
      foreground: root.contentForeground
      fontFamily: root.contentFontFamily
      onCanceled: depsDialog.opened = false
      onConfirmed: depsDialog.opened = false
    }

    // ---- Confirmation: uninstalling removes every integration, then the ----
    // ---- plugin itself (the bar icon goes with the shell's disable step). -
    // Also inside the card so it actually renders.

    ConfirmDialog {
      id: uninstallConfirm
      anchors.fill: parent
      z: 10
      opened: false
      message: "Uninstall OmaShield? This restores the stock " +
               "Update / Install menu, removes the native yay guard hooks and the " +
               "omarchy-omashield command, and removes the plugin itself. " +
               "aur-scanner and yay-guard stay installed."
      cancelText: "Keep"
      confirmText: "Uninstall"
      foreground: root.contentForeground
      fontFamily: root.contentFontFamily
      onCanceled: uninstallConfirm.opened = false
      onConfirmed: root.runUninstall()
    }
  }

  // ---- Process wiring -----------------------------------------------------

  Process {
    id: statusProcess
    running: false
    command: [root.cliBin, "status"]
    stdout: StdioCollector { id: statusStdout; waitForEnd: true }
    stderr: StdioCollector { id: statusStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.applyStatus(String(statusStdout.text || ""))
      } else {
        root.statusFailed = true
        root.statusLoaded = true
      }
    }
  }

  Process {
    id: setProcess
    running: false
    command: []
    stdout: StdioCollector { id: setStdout; waitForEnd: true }
    stderr: StdioCollector { id: setStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 3) {
        root.shieldOn = !root.shieldOn  // ON gate refused, roll the flip back
        depsDialog.opened = true
      } else if (exitCode !== 0) {
        root.shieldOn = !root.shieldOn  // roll the optimistic flip back
        root.actionMessage = "The switch could not be changed."
      }
      Qt.callLater(function() { root.reload() })
    }
  }

  Process {
    id: uninstallProcess
    running: false
    command: []
    stdout: StdioCollector { id: uninstallStdout; waitForEnd: true }
    stderr: StdioCollector { id: uninstallStderr; waitForEnd: true }
    onExited: function(exitCode) {
      // The plugin directory is deleted by `omarchy plugin remove` while this
      // QML instance is already loaded. Leave a plain message behind.
      if (exitCode === 0) {
        root.actionMessage = "Uninstall done."
      } else {
        root.actionMessage = "Uninstall failed — see the output in a terminal (omarchy-omashield uninstall)."
      }
    }
  }

  onOpenedChanged: {
    if (root.opened) root.reload()
  }

  Component.onCompleted: reload()
}
