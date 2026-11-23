import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QC
import Quickshell
import qs.Commons
import qs.Ui
import "CategoryModel.js" as CategoryModel

// CategorySidebar — a toggleable sidebar for browsing packages by category.
// Clicking a category sets the search query to that category's primary keyword
// and switches to the appropriate tab (Pacman/Flatpak both support category search).

Item {
    id: root
    property bool sidebarVisible: false
    readonly property int sidebarWidth: 240
    // Signal emitted when a category is selected (sidebar should close)
    signal categorySelected(string categoryId, string keyword)
    // Signal emitted when sidebar should close
    signal requestClose()

    // Internal filter for the category list
    property string filterText: ""

    // Fade in/out (the item is anchored to the panel's right edge)
    Behavior on opacity { NumberAnimation { duration: 150 } }

    opacity: root.sidebarVisible ? 1 : 0
    clip: true
    visible: root.sidebarVisible
    implicitWidth: root.sidebarWidth

    // Background with frosted effect matching panel
    Rectangle {
        anchors.fill: parent
        color: Util.alpha(Color.popups.background, 0.98)
        border.color: Util.alpha(Color.popups.text, 0.08)
        border.width: 1
        radius: Style.space(12)
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // Header with filter input
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: Style.space(48)
            color: "transparent"
            border.color: Util.alpha(Color.popups.text, 0.06)
            border.width: 1
            radius: Style.space(8)

            RowLayout {
                anchors.fill: parent
                anchors.margins: Style.space(10)
                spacing: Style.space(8)

                // Filter icon
                Text {
                    Layout.alignment: Qt.AlignVCenter
                    font.family: Style.font.resolvedFamily
                    font.pixelSize: Style.font.body
                    color: Util.alpha(Color.popups.text, 0.5)
                    text: "\uDB80\uDF49" // magnify
                }

                // Filter input (key-buffered, no native text field)
                Item {
                    id: filterInput
                    Layout.fillWidth: true
                    Layout.preferredHeight: Style.space(28)
                    property string text: ""
                    property bool focused: false
                    focus: true
                    onTextChanged: root.refreshCategoryModel()

                    Rectangle {
                        anchors.fill: parent
                        color: Util.alpha(Color.popups.background, 0.6)
                        radius: Style.space(6)
                        border.color: filterInput.focused ? Color.accent : "transparent"
                        border.width: filterInput.focused ? 1.5 : 0
                        Behavior on border.color { ColorAnimation { duration: 120 } }
                    }

                    Text {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.margins: Style.space(8)
                        font.family: Style.font.resolvedFamily
                        font.pixelSize: Style.font.caption + 1
                        color: filterInput.text ? Color.popups.text : Util.alpha(Color.popups.text, 0.4)
                        text: filterInput.text || "Filter categories…"
                        elide: Text.ElideRight
                    }

                    // Caret when focused
                    Rectangle {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.margins: Style.space(10)
                        width: 1.5
                        height: Style.font.body * 1.2
                        color: Color.accent
                        visible: filterInput.focused && (Math.floor(Date.now() / 500) % 2 === 0)
                    }

                    Keys.onPressed: {
                        if (event.key === Qt.Key_Backspace) {
                            if (filterInput.text.length > 0) {
                                filterInput.text = filterInput.text.slice(0, -1);
                                root.filterText = filterInput.text;
                            }
                        } else if (event.key === Qt.Key_Escape) {
                            filterInput.text = "";
                            root.filterText = "";
                            filterInput.focus = false;
                        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                            filterInput.focus = false;
                        } else if (event.text && event.text.length === 1) {
                            filterInput.text += event.text;
                            root.filterText = filterInput.text;
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        onClicked: filterInput.focus = true
                    }
                }

                // Clear filter button — only shows while a filter is active
                MouseArea {
                    Layout.preferredWidth: Style.space(28)
                    Layout.preferredHeight: Style.space(28)
                    visible: filterInput.text.length > 0
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        filterInput.text = "";
                        root.filterText = "";
                        filterInput.focus = true;
                    }
                    Rectangle {
                        anchors.centerIn: parent
                        width: Style.space(18)
                        height: Style.space(18)
                        radius: Style.space(9)
                        color: parent.hovered ? Util.alpha(Color.popups.text, 0.12) : "transparent"
                        Text {
                            anchors.centerIn: parent
                            font.family: Style.font.family
                            font.pixelSize: Style.font.caption
                            color: Util.alpha(Color.popups.text, 0.6)
                            text: "\u00D7"
                        }
                    }
                }

                // Close the sidebar. This is the button that was previously
                // (incorrectly) wired to clear the filter, so clicking the X
                // did nothing visible when the filter was empty.
                MouseArea {
                    id: closeBtn
                    Layout.preferredWidth: Style.space(28)
                    Layout.preferredHeight: Style.space(28)
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.requestClose()
                    Rectangle {
                        anchors.centerIn: parent
                        width: Style.space(18)
                        height: Style.space(18)
                        radius: Style.space(9)
                        color: parent.hovered ? Util.alpha(Color.popups.text, 0.12) : "transparent"
                        Text {
                            anchors.centerIn: parent
                            font.family: Style.font.resolvedFamily
                            font.pixelSize: Style.font.caption
                            color: Util.alpha(Color.popups.text, 0.6)
                            text: "\uDB80\uDD56" // close
                        }
                    }
                }
            }
        }

        // Category list
        ListView {
            id: categoryList
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: Style.space(2)
            model: categoryModel
            // focus: true  -- removed to allow mouse clicks on delegates
            pressDelay: 200  // Give delegate MouseArea time to handle click before scrolling starts

            // Key navigation
            Keys.onPressed: {
                if (event.key === Qt.Key_Up) {
                    event.accepted = true;
                    categoryList.decrementCurrentIndex();
                } else if (event.key === Qt.Key_Down) {
                    event.accepted = true;
                    categoryList.incrementCurrentIndex();
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    event.accepted = true;
                    var idx = categoryList.currentIndex;
                    if (idx >= 0 && idx < categoryList.count) {
                        var cat = categoryList.model.get(idx);
                        if (cat && cat.id) {
                            var keywords = CategoryModel.categoryKeywords(cat.id);
                            var primaryKeyword = keywords.length > 0 ? keywords[0] : cat.label.toLowerCase();
                            root.categorySelected(cat.id, primaryKeyword);
                            root.requestClose();
                        }
                    }
                } else if (event.key === Qt.Key_Escape) {
                    event.accepted = true;
                    filterInput.focus = true;
                }
            }

            delegate: QC.ItemDelegate {
                id: catDelegate
                width: ListView.view.width
                height: Style.space(40)
                highlighted: ListView.isCurrentItem
                checkable: false
                padding: Style.space(10)
                contentItem: MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    preventStealing: true
                    onClicked: {
                        if (!model || !model.id) return;
                        var keywords = CategoryModel.categoryKeywords(model.id);
                        var primaryKeyword = keywords.length > 0 ? keywords[0] : model.label.toLowerCase();
                        root.categorySelected(model.id, primaryKeyword);
                        root.requestClose();
                    }
                    Row {
                        spacing: Style.space(10)
                        // Category icon
                        Text {
                            width: Style.space(22)
                            height: Style.space(22)
                            verticalAlignment: Text.AlignVCenter
                            horizontalAlignment: Text.AlignHCenter
                            font.family: Style.font.resolvedFamily
                            font.pixelSize: Style.font.body
                            color: catDelegate.highlighted ? Color.accent : Util.alpha(Color.popups.text, 0.7)
                            text: model.icon
                        }
                        // Category label
                        Text {
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                            font.family: Style.font.resolvedFamily
                            font.pixelSize: Style.font.caption + 1
                            color: catDelegate.highlighted ? Color.popups.text : Util.alpha(Color.popups.text, 0.85)
                            text: model.label
                        }
                    }
                }
                background: Rectangle {
                    anchors.fill: parent
                    anchors.margins: Style.space(2)
                    radius: Style.space(6)
                    color: catDelegate.highlighted ? Util.alpha(Color.accent, 0.14) : "transparent"
                    Behavior on color { ColorAnimation { duration: 100 } }
                }
            }
        }

        // Footer with hint
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: Style.space(36)
            color: "transparent"
            border.color: Util.alpha(Color.popups.text, 0.06)
            border.width: 1

            Text {
                anchors.centerIn: parent
                font.family: Style.font.resolvedFamily
                font.pixelSize: Style.font.caption - 1
                color: Util.alpha(Color.popups.text, 0.45)
                text: "↑↓ navigate · Enter select · Esc clear filter"
            }
        }
    }

    // Category list model - populated from CategoryModel
    ListModel {
        id: categoryModel
    }

    function refreshCategoryModel() {
        categoryModel.clear()
        var cats = CategoryModel.searchCategories(root.filterText)
        for (var i = 0; i < cats.length; i++) {
            categoryModel.append(cats[i])
        }
    }

    Component.onCompleted: refreshCategoryModel()

    function selectCategory(cat) {
        if (!cat || !cat.id) return;
        var keywords = CategoryModel.categoryKeywords(cat.id);
        var primaryKeyword = keywords.length > 0 ? keywords[0] : cat.label.toLowerCase();
        root.categorySelected(cat.id, primaryKeyword);
        root.requestClose();
    }
}
