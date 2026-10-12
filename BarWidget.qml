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
  // Two styles, not six. `outline` / `soft` / `bold` / `minimal` were all the
  // same pill at different alphas, and asking a user to pick between four
  // greys is a decision they should never have to make — the row of near
  // identical options was itself the thing making the bar look provisional.
  // One opinionated default, plus one compact alternative.
  //
  //   "pill" — magnifier chip + "Find App" label (default)
  //   "icon" — bare magnifier, no chip, no label, no border
  property string toolbarDesign: "pill"
  readonly property var designs: ["pill", "icon"]

  // Material Design magnify, U+F0349 — the same glyph as `icons.search` in
  // Panel.qml, read out of the installed JetBrainsMono Nerd Font and written as
  // a surrogate pair, because a `\uXXXX` escape is exactly four hex digits and
  // would silently truncate an astral codepoint.
  readonly property string searchIcon: "\uDB80\uDF49"

  // Anything persisted by an older build (or anything unrecognised) lands on the
  // default rather than leaving the button unstyled.
  function normalizeDesign(d) {
    return root.designs.indexOf(d) !== -1 ? d : "pill"
  }

  function setToolbarDesign(d) {
    root.toolbarDesign = root.normalizeDesign(d)
  }

  FileView {
    path: Quickshell.env("HOME") + "/.local/state/omarchy/settings/davedes.fossfetch.json"
    watchChanges: false
    printErrors: false
    onLoaded: {
      try {
        root.toolbarDesign = root.normalizeDesign(JSON.parse(text()).design)
      } catch (e) { /* keep default */ }
    }
  }

  readonly property bool bareIcon: root.toolbarDesign === "icon"
  readonly property bool hot: mouseArea.containsMouse || root.opened

  // ---- update badge ---------------------------------------------------------
  // The count lives on the panel (one scan, one number) and is read back here
  // rather than re-scanned in the bar, so the badge and the Updates tab can
  // never disagree. The panel is loaded at all times, so this stays current
  // while the popup is closed.
  readonly property int updateCount: panelLoader.item
    ? (panelLoader.item.updateCount || 0)
    : 0

  // 99+ rather than the real number: the badge is a nudge, not a report, and a
  // four-digit pill would blow the button's width out.
  readonly property string updateBadge: root.updateCount > 99
    ? "99+"
    : (root.updateCount > 0 ? String(root.updateCount) : "")

  function tooltipText() {
    return root.updateCount > 0
      ? "Browse open-source packages — " + root.updateCount
        + (root.updateCount === 1 ? " update available" : " updates available")
      : "Browse open-source packages"
  }

  function btnRadius() { return button.height / 2 }

  function btnBorderWidth() {
    if (root.bareIcon) return 0
    return root.hot ? 2 : 1
  }

  function btnBorder() {
    if (root.bareIcon) return "transparent"
    return root.hot
      ? Util.alpha(root.accentColor, 0.9)
      : Util.alpha(root.foregroundColor, 0.16)
  }

  function btnFillTop() {
    if (root.bareIcon) return "transparent"
    if (mouseArea.pressed || root.opened) return Util.alpha(root.accentColor, 0.30)
    return mouseArea.containsMouse ? Util.alpha(root.accentColor, 0.22) : Util.alpha(root.surfaceAlt, 0.90)
  }

  function btnFillBottom() {
    if (root.bareIcon) return "transparent"
    if (mouseArea.pressed || root.opened) return Util.alpha(root.accentColor, 0.20)
    return mouseArea.containsMouse ? Util.alpha(root.accentColor, 0.13) : Util.alpha(root.surfaceAlt, 0.55)
  }

  function btnGlow() { return root.hot ? 0.5 : 0 }

  function chipRadius() { return button.height / 2 }

  function chipFill() {
    if (root.bareIcon) return "transparent"
    return root.hot
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
  // Enabled by binding in Hyprland, e.g.:
  //   bind = SUPER ALT, F, global, quickshell:toggle_alt_finder
  GlobalShortcut {
    id: globalShortcut
    appid: "quickshell"
    name: "toggle_alt_finder"
    description: "Toggle FossFetch package search"
    onPressed: root.togglePanel()
  }

  Item {
    id: button
    // Icon-only style is a compact square pill holding just the magnifier.
    width: root.bareIcon ? 26 : rootLabel.implicitWidth + 22
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

      // Update count badge. Drawn as an overlay on the pill's top-right rather
      // than as a third item in rootLabel: adding it to the RowLayout would
      // resize the button every time the count changed, so the bar would visibly
      // twitch as updates were applied. Overlaying keeps the layout fixed.
      Rectangle {
        id: updateBadgeRect
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.rightMargin: -3
        anchors.topMargin: -4
        visible: root.updateBadge !== ""
        width: badgeText.implicitWidth + 9
        height: 14
        radius: 7
        color: root.accentColor
        border.width: 1
        border.color: root.surfaceAlt

        Text {
          id: badgeText
          anchors.centerIn: parent
          text: root.updateBadge
          color: root.surfaceAlt
          font.family: Style.font.resolvedFamily
          font.pixelSize: Style.font.caption - 2
          font.bold: true
        }
      }

      RowLayout {
        id: rootLabel
        anchors.centerIn: parent
        spacing: 6
        layoutDirection: Qt.LeftToRight

        // Icon chip: accent-tinted squircle holding the search-plus glyph so
        // the button reads as an app/launcher tile rather than plain text.
        Rectangle {
          Layout.preferredWidth: 16
          Layout.preferredHeight: 16
          radius: root.chipRadius()
          color: root.chipFill()
          Behavior on color { ColorAnimation { duration: 150 } }

          // font.family is bound explicitly. It was previously unset, so this
          // one glyph fell back to whatever family the process happened to
          // resolve — which is why the toolbar icon looked like it came from a
          // different app than everything around it.
          Text {
            anchors.centerIn: parent
            text: root.searchIcon
            color: root.hot ? root.accentColor : root.foregroundColor
            font.family: Style.font.resolvedFamily
            font.pixelSize: Style.font.caption + 1
            Behavior on color { ColorAnimation { duration: 150 } }
          }
        }

        Text {
          text: root.buttonLabel
          visible: !root.bareIcon
          color: root.hot ? root.accentColor : Util.alpha(root.foregroundColor, 0.85)
          font.family: Style.font.resolvedFamily
          font.pixelSize: Style.font.caption + 1
          font.bold: false
          Behavior on color { ColorAnimation { duration: 150 } }
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
          root.bar.showTooltip(button, root.tooltipText())
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
