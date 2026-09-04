import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "davedes.fossfetch"

  // ------------------------------------------------------------------ colours
  // Shell-theme-aware palette drawn from the host bar + Commons theme.
  readonly property color foregroundColor: bar ? bar.foreground : Color.foreground
  readonly property color accentColor: Color.accent
  readonly property color surfaceAlt: bar ? bar.background : Color.background

  readonly property int panelWidth: setting("panelWidth", 560)
  readonly property int debounceMs: setting("debounceMs", 150)
  readonly property string buttonLabel: setting("buttonLabel", "Find App")

  // ------------------------------------------------------------------- panel
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function togglePanel() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("panelWidth" in target) target.panelWidth = root.panelWidth
    if ("debounceMs" in target) target.debounceMs = root.debounceMs
    if ("palette" in target && "palette" in root) target.palette = root.palette
  }

  implicitWidth: button.width + rootHorizontalPadding * 2
  implicitHeight: button.height
  readonly property real rootHorizontalPadding: 5

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

  // IPC bridge so the Hyprland hotkey (omarchy-shell shell toggle fossfetch)
  // and any external caller can open/close the popup. The Panel disables its
  // built-in handler (manageIpc: false) so this is the single target owner,
  // then relays to the loaded panel (mirrors the dictionary plugin).
  IpcHandler {
    target: "fossfetch"

    function open(): void { root.open() }
    function show(): void { root.open() }
    function close(): void { root.close() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
  }

  // Optional native Hyprland global-shortcut alternative to the IPC hotkey.
  // Enabled by binding in Hyprland: bind = SUPER ALT, A, global, quickshell:toggle_alt_finder
  GlobalShortcut {
    id: globalShortcut
    appid: "quickshell"
    name: "toggle_alt_finder"
    description: "Toggle Open Source Alternative Finder"
    onPressed: root.togglePanel()
  }

  Item {
    id: button
    width: rootLabel.implicitWidth + 22
    height: 24
    anchors.verticalCenter: parent.verticalCenter

    Rectangle {
      anchors.fill: parent
      radius: 6
      color: mouseArea.containsMouse ? Util.alpha(root.foregroundColor, 0.12) : Util.alpha(root.surfaceAlt, 0.6)
      border.color: mouseArea.containsMouse ? root.accentColor : Util.alpha(root.foregroundColor, 0.25)
      border.width: 1

      Behavior on color { ColorAnimation { duration: 150 } }
      Behavior on border.color { ColorAnimation { duration: 150 } }

      RowLayout {
        id: rootLabel
        anchors.centerIn: parent
        spacing: 7
        layoutDirection: Qt.LeftToRight

        Text {
          text: "\uf002"
          color: root.foregroundColor
          font.pixelSize: 13
        }

        Text {
          text: root.buttonLabel
          color: root.foregroundColor
          font.pixelSize: 12
          font.bold: true
        }
      }
    }

    MouseArea {
      id: mouseArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
      onClicked: function(mouse) {
        if (mouse.button === Qt.RightButton) return
        root.togglePanel()
      }
    }
  }
}
