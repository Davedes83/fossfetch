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

  // ---------------------------------------------------- toolbar icon design
  // Visual style of the launcher pill itself. One of: current | outline |
  // soft | bold | minimal | icon. Synced from the panel's settings menu (and
  // read straight from the shared state file at startup). The "icon" style is
  // a bare magnifying-glass glyph with no chip, label or border.
  property string toolbarDesign: "current"

  function setToolbarDesign(d) {
    var valid = ["current", "outline", "soft", "bold", "minimal", "icon"]
    if (valid.indexOf(d) === -1) return
    root.toolbarDesign = d
  }

  FileView {
    path: Quickshell.env("HOME") + "/.local/state/omarchy/settings/davedes.fossfetch.json"
    watchChanges: false
    printErrors: false
    onLoaded: {
      try {
        var data = JSON.parse(text())
        if (["current", "outline", "soft", "bold", "minimal", "icon"].indexOf(data.design) !== -1)
          root.toolbarDesign = data.design
      } catch (e) { /* keep default */ }
    }
  }

  function btnRadius() {
    if (root.toolbarDesign === "outline") return 6
    if (root.toolbarDesign === "bold") return 8
    if (root.toolbarDesign === "icon") return button.height / 2
    return button.height / 2
  }

  function btnBorderWidth() {
    var d = root.toolbarDesign
    var hot = mouseArea.containsMouse || root.opened
    if (d === "icon") return 0
    if (d === "bold") return 2
    if (d === "outline") return hot ? 2 : 1
    if (d === "soft" || d === "minimal") return hot ? 1 : 0
    return 1
  }

  function btnBorder() {
    var d = root.toolbarDesign
    var hot = mouseArea.containsMouse || root.opened
    if (d === "icon") return "transparent"
    if (d === "outline")
      return hot ? Util.alpha(root.accentColor, 0.9) : Util.alpha(root.foregroundColor, 0.4)
    if (d === "bold")
      return hot ? Util.alpha(root.accentColor, 1.0) : Util.alpha(root.accentColor, 0.55)
    if (d === "minimal")
      return hot ? Util.alpha(root.accentColor, 0.7) : "transparent"
    if (d === "soft")
      return hot ? Util.alpha(root.accentColor, 0.35) : "transparent"
    return mouseArea.containsMouse
      ? Util.alpha(root.accentColor, 0.9)
      : root.opened
        ? Util.alpha(root.accentColor, 0.55)
        : Util.alpha(root.foregroundColor, 0.16)
  }

  function btnFillTop() {
    var d = root.toolbarDesign
    var hot = mouseArea.containsMouse || root.opened
    if (d === "icon") return "transparent"
    if (d === "minimal") return hot ? Util.alpha(root.accentColor, 0.08) : "transparent"
    if (d === "soft") return hot ? Util.alpha(root.accentColor, 0.28) : Util.alpha(root.accentColor, 0.07)
    if (d === "bold") return hot ? Util.alpha(root.accentColor, 0.42) : Util.alpha(root.accentColor, 0.13)
    if (d === "outline") return hot ? Util.alpha(root.accentColor, 0.18) : Util.alpha(root.surfaceAlt, 0.75)
    return mouseArea.pressed || root.opened
      ? Util.alpha(root.accentColor, 0.30)
      : mouseArea.containsMouse ? Util.alpha(root.accentColor, 0.22) : Util.alpha(root.surfaceAlt, 0.9)
  }

  function btnFillBottom() {
    var d = root.toolbarDesign
    var hot = mouseArea.containsMouse || root.opened
    if (d === "icon") return "transparent"
    if (d === "minimal") return hot ? Util.alpha(root.accentColor, 0.04) : "transparent"
    if (d === "soft") return hot ? Util.alpha(root.accentColor, 0.18) : Util.alpha(root.accentColor, 0.04)
    if (d === "bold") return hot ? Util.alpha(root.accentColor, 0.28) : Util.alpha(root.accentColor, 0.08)
    if (d === "outline") return hot ? Util.alpha(root.accentColor, 0.10) : Util.alpha(root.surfaceAlt, 0.45)
    return mouseArea.pressed || root.opened
      ? Util.alpha(root.accentColor, 0.20)
      : mouseArea.containsMouse ? Util.alpha(root.accentColor, 0.13) : Util.alpha(root.surfaceAlt, 0.55)
  }

  function btnGlow() {
    var d = root.toolbarDesign
    var hot = mouseArea.containsMouse || root.opened
    if (d === "outline" || d === "minimal" || d === "icon") return 0
    if (d === "bold") return hot ? 0.9 : 0
    if (d === "soft") return hot ? 0.5 : 0.08
    return mouseArea.containsMouse ? 0.5 : 0
  }

  function chipRadius() {
    if (root.toolbarDesign === "minimal") return 2
    if (root.toolbarDesign === "icon") return 2
    if (root.toolbarDesign === "bold") return 4
    if (root.toolbarDesign === "soft") return 9
    if (root.toolbarDesign === "outline") return 6
    return 5
  }

  function chipFill() {
    var d = root.toolbarDesign
    var hot = mouseArea.containsMouse || root.opened
    if (d === "icon") return "transparent"
    if (d === "minimal") return hot ? Util.alpha(root.accentColor, 0.14) : "transparent"
    if (d === "soft") return hot ? Util.alpha(root.accentColor, 0.32) : Util.alpha(root.accentColor, 0.12)
    if (d === "bold") return hot ? Util.alpha(root.accentColor, 0.48) : Util.alpha(root.accentColor, 0.22)
    if (d === "outline") return hot ? Util.alpha(root.accentColor, 0.26) : Util.alpha(root.foregroundColor, 0.08)
    return mouseArea.containsMouse || root.opened
      ? Util.alpha(root.accentColor, 0.30)
      : Util.alpha(root.foregroundColor, 0.10)
  }

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
    // Icon-only style is a compact square pill holding just the magnifier.
    width: root.toolbarDesign === "icon" ? 26 : rootLabel.implicitWidth + 30
    height: 26
    anchors.verticalCenter: parent.verticalCenter

    // Let the bar's tooltip system treat this pill as a hoverable target.
    readonly property bool tooltipHovered: mouseArea.containsMouse && !root.opened

    // Styled by the toolbar icon design chosen in the panel's settings menu.
    Rectangle {
      anchors.fill: parent
      radius: root.btnRadius()
      gradient: Gradient {
        GradientStop {
          position: 0.0
          color: root.btnFillTop()
        }
        GradientStop {
          position: 1.0
          color: root.btnFillBottom()
        }
      }
      border.color: root.btnBorder()
      border.width: root.btnBorderWidth()

      Behavior on border.color { ColorAnimation { duration: 150 } }

      // Soft glow while hovered, matching the warm accent border.
      Rectangle {
        anchors.fill: parent
        radius: parent.radius
        color: "transparent"
        border.color: Util.alpha(root.accentColor, 0.5)
        border.width: 2
        opacity: root.btnGlow()
        Behavior on opacity { NumberAnimation { duration: 180 } }
      }

      RowLayout {
        id: rootLabel
        anchors.centerIn: parent
        spacing: 8
        layoutDirection: Qt.LeftToRight

        // Icon chip: accent-tinted squircle holding the search-plus glyph so
        // the button reads as an app/launcher tile rather than plain text.
        Rectangle {
          Layout.preferredWidth: 18
          Layout.preferredHeight: 18
          radius: root.chipRadius()
          color: root.chipFill()
          Behavior on color { ColorAnimation { duration: 150 } }

          Text {
            anchors.centerIn: parent
            text: "\uf00e"
            color: mouseArea.containsMouse || root.opened ? root.accentColor : root.foregroundColor
            font.pixelSize: root.toolbarDesign === "icon" ? 13 : 12
            Behavior on color { ColorAnimation { duration: 150 } }
          }
        }

        Text {
          text: root.buttonLabel
          visible: root.toolbarDesign !== "icon"
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
      onEntered: {
        if (root.bar && root.bar.showTooltip)
          root.bar.showTooltip(button, "Browse open-source packages")
      }
      onExited: {
        if (root.bar && root.bar.hideTooltip) root.bar.hideTooltip(button)
      }
      onPressed: function(mouse) { if (mouse.button !== Qt.LeftButton) return }
      onClicked: function(mouse) {
        if (mouse.button === Qt.RightButton) return
        root.togglePanel()
      }
    }
  }
}
