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
  // Four styles, along one axis — how much chrome sits behind the magnifier —
  //   "icon"   — magnifier alone. No fill, no border, no label. (first install)
  //   "circle" — magnifier alone on a dark circle, the pill's shape without
  //              its wording. The compromise for a bar that wants a visible
  //              target without the width a label costs.
  //   "text"   — magnifier + "Find App", no chip. Same wording as "pill".
  //   "brand"  — magnifier + "FossFetch", no chip. Same chrome as "text", the
  //              product's own name instead of a description of what it does.
  //   "pill"   — magnifier + "Find App" on a filled, bordered chip.
  //
  // "icon" is the FIRST-INSTALL default, and the two cases are kept apart on
  // purpose: a fresh install has nobody's bar to restyle, whereas an existing
  // user whose settings file has no stored choice is on whatever they have
  // been looking at and must not be switched under them.
  property string toolbarDesign: "icon"
  readonly property var designs: ["pill", "icon", "circle", "text", "brand"]

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
        var raw = text()
        // No settings file: a first install. The declared default stands, and
        // nothing is written here -- creating an options file on a mere load
        // would do that for a user who has changed nothing.
        if (raw === undefined || raw === null || String(raw).trim() === "") return
        root.toolbarDesign = root.normalizeDesign(JSON.parse(raw).design)
      } catch (e) { /* keep default */ }
    }
  }

  // No label: the magnifier alone.
  readonly property bool bareIcon:
    root.toolbarDesign === "icon" || root.toolbarDesign === "circle"

  // No fill, no border, no glow. "icon", "text" and "brand" draw the SAME
  // chrome-free button and differ only in the label; keying the chrome helpers
  // off this rather than off bareIcon is what keeps them from drifting apart.
  // "circle" is excluded: it carries the pill's fill on purpose.
  // The shell's own bar icon box (Style.bar.iconSlot), which is what every
  // other circular button in the bar is sized from -- the coffee, clipboard
  // and tray icons. Matching it is the whole point of this style: a disc that
  // is even a pixel off reads as a different control sitting in the same bar,
  // and deriving the size from the icon canvas instead produced exactly that.
  readonly property int circleSize: Style.bar.iconSlot

  readonly property bool borderless:
    root.toolbarDesign === "icon" || root.toolbarDesign === "text"
    || root.toolbarDesign === "brand"

  // "brand" is the one style that does not use the user's configurable
  // buttonLabel: the whole point of it is to say what the thing is called.
  readonly property string labelText:
    root.toolbarDesign === "brand" ? "FossFetch" : root.buttonLabel
  readonly property bool hot: mouseArea.containsMouse || root.opened

  // ---- update badge ---------------------------------------------------------
  // One scan, one number. The scan lives on `updateScanner` below (always
  // loaded), so the badge and the Updates tab can never disagree -- and the
  // number stays current while the popup is closed, even though the panel
  // itself is not loaded until it is opened.
  readonly property int updateCount: updateScanner.updateCount

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
    // The circle is the pill's shape without its edge: filled like the pill so
    // it reads as the same control, unbordered so it does not read as identical.
    if (root.toolbarDesign === "circle") return 0
    if (root.borderless) return 0
    return root.hot ? 2 : 1
  }

  function btnBorder() {
    if (root.borderless) return "transparent"
    return root.hot
      ? Util.alpha(root.accentColor, 0.9)
      : Util.alpha(root.foregroundColor, 0.16)
  }

  function btnFillTop() {
    // A borderless button has no ring to light up, so hover is a soft tint
    // instead. Without this the "text" style would give the user no feedback
    // at all — the one thing that tells you the button is clickable.
    if (root.borderless)
      return (root.hot || mouseArea.pressed) ? Util.alpha(root.accentColor, 0.16) : "transparent"
    if (mouseArea.pressed || root.opened) return Util.alpha(root.accentColor, 0.30)
    return mouseArea.containsMouse ? Util.alpha(root.accentColor, 0.22) : Util.alpha(root.surfaceAlt, 0.90)
  }

  function btnFillBottom() {
    if (root.borderless)
      return (root.hot || mouseArea.pressed) ? Util.alpha(root.accentColor, 0.08) : "transparent"
    if (mouseArea.pressed || root.opened) return Util.alpha(root.accentColor, 0.20)
    return mouseArea.containsMouse ? Util.alpha(root.accentColor, 0.13) : Util.alpha(root.surfaceAlt, 0.55)
  }

  // The accent ring only suits a button that has a border to light up.
  function btnGlow() { return (root.hot && !root.borderless) ? 0.5 : 0 }

  function chipRadius() { return button.height / 2 }

  // The grey circle behind the magnifier survives on every style that still
  // carries a label. It is only dropped for "icon", which exists to be a bare
  // glyph, and for "circle", where the BUTTON is already that circle and a
  // second one inside it would read as a ring.
  function chipFill() {
    // Only the bare glyph drops it. The circle keeps the pill's chip tint on
    // top of the pill's fill, so the magnifier sits on exactly the grey the
    // pill shows -- the two are the same construction, not two tuned values
    // that have to be kept in step by hand.
    if (root.toolbarDesign === "icon") return "transparent"
    if (root.hot) return Util.alpha(root.accentColor, 0.30)
    // One value for every style that has a label, including the borderless
    // ones: same grey as the pill's own chip. Substituting a surface colour
    // here to compensate for the missing pill fill behind it made the chip
    // lighter than the control it is supposed to match.
    return Util.alpha(root.foregroundColor, 0.10)
  }

  // ------------------------------------------------------------------- panel
  // The panel is loaded only while it is open, and unloaded again shortly
  // after it closes. It holds no native editable text input: the query line
  // is a key-buffered Item, and the plugin's only cross-clipboard read — the
  // explicitly requested Ctrl+V paste — runs through a bounded child process
  // that can neither stall nor exhaust this one (see Panel.qml). The loader
  // still exists because a popup must not outlive its window, and everything
  // the bar shows while the panel is closed -- the update badge -- is served
  // by `updateScanner`, not the panel, so nothing here depends on it existing.
  property bool panelRequested: false
  property bool pendingOpen: false

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    root.panelRequested = true
    if (panelLoader.item) panelLoader.item.open()
    else root.pendingOpen = true
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function togglePanel() {
    if (panelLoader.item) panelLoader.item.toggle()
    else root.open()
  }

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  // Unload the panel shortly after it closes, so its search field does not sit
  // in the tree while nothing is shown. Delayed rather than immediate so a
  // popout switch (close, then reopen as the widget changes bar section) never
  // tears the panel down mid-move.
  Timer {
    id: unloadTimer
    interval: 400
    repeat: false
    onTriggered: {
      if (!root.opened && !root.popoutSwitchClosing) root.panelRequested = false
    }
  }

  onOpenedChanged: {
    unloadTimer.stop()
    if (root.opened) return
    if (root.panelRequested) unloadTimer.restart()
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
    if ("updates" in target) target.updates = updateScanner
  }

  implicitWidth: button.width + rootHorizontalPadding * 2
  implicitHeight: button.height
  readonly property real rootHorizontalPadding: 5

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    // Loaded only while the panel is open (see panelRequested above).
    active: root.panelRequested
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
      if (root.pendingOpen) { root.pendingOpen = false; root.open() }
    }
  }

  // The background update scan, kept on the always-loaded widget so the bar
  // badge stays live while the panel itself is unloaded.
  UpdateScan {
    id: updateScanner
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
    // Height tracks the bar's own slot size rather than a baked-in 26, so the
    // button fills its slot exactly like every shell bar widget does.
    // "circle" is sized to the magnifier's own canvas, not the bar's slot.
    // Filling the slot (26px) made the disc both oversized next to the pill's
    // 16px chip and tall enough that its lower edge met the bottom of the
    // toolbar, where the join against the bar edge was plainly visible.
    // Equal sides, or it would be an oval rather than a circle.
    width: root.toolbarDesign === "circle" ? root.circleSize
         : (root.bareIcon ? root.circleSize : rootLabel.implicitWidth + 22)
    height: root.toolbarDesign === "circle" ? root.circleSize : root.barSize
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
      //
      // Anchored INSIDE the button, not overhanging it. This used to sit at
      // topMargin: -4, which pushed it four pixels above a button that already
      // starts two pixels below the top of the screen — the badge was clipped by
      // the screen edge and the count was cut in half. The button is the one
      // thing guaranteed to be on-screen, so the badge is positioned relative to
      // it with a positive margin and cannot escape the bar.
      Rectangle {
        id: updateBadgeRect
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.rightMargin: -1
        anchors.topMargin: 0
        visible: root.updateBadge !== ""
        // Scaled down on the compact styles. At the pill's size a 12px badge
        // on a 20px circle covers the magnifier it is reporting on.
        readonly property bool compact: root.bareIcon
        width: badgeText.implicitWidth + (compact ? 5 : 8)
        height: compact ? 9 : 12
        radius: height / 2
        color: root.accentColor
        border.width: 1
        border.color: root.surfaceAlt

        Text {
          id: badgeText
          anchors.centerIn: parent
          text: root.updateBadge
          color: root.surfaceAlt
          font.family: Style.font.resolvedFamily
          font.pixelSize: Style.font.caption - (updateBadgeRect.compact ? 4 : 2)
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
          Layout.preferredWidth: Style.bar.iconCanvas
          Layout.preferredHeight: Style.bar.iconCanvas
          radius: root.chipRadius()
          color: root.chipFill()
          Behavior on color { ColorAnimation { duration: 150 } }

          // Rendered through the shell's own OpticalGlyph, on the same
          // iconCanvas / iconFont geometry as every other bar icon
          // (BarIconButton centres OpticalGlyph in opticalCanvas). This glyph
          // used to be a plain Text at font.caption + 1, which measured 1.9px
          // HIGHER than its neighbours and 2px smaller: Qt centres a Text's
          // LINE BOX, and this font's ascent/descent are asymmetric, so the
          // painted shape sat above the box centre. Every other bar icon has
          // the same drift — they just share one font size and one canvas, so
          // it cancels out. Matching that geometry fixes it by construction
          // instead of by nudging an offset that a future font change would
          // undo.
          OpticalGlyph {
            anchors.fill: parent
            text: root.searchIcon
            color: root.hot ? root.accentColor : root.foregroundColor
            fontFamily: Style.font.resolvedFamily
            // Style.font.body, NOT Style.bar.iconFont: BarIconButton never
            // overrides WidgetButton's fontSize, so every shell bar icon
            // renders at `body` (12). Using iconFont (13) put this glyph on a
            // different line box from its neighbours.
            fontSize: Style.font.body
            Behavior on color { ColorAnimation { duration: 150 } }
          }
        }

        Text {
          text: root.labelText
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
