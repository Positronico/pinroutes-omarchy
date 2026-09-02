import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// PinRoutes bar widget: a pin icon that turns urgent when a pinned route has
// gone missing, with a popup panel to manage rules, re-apply routes, and
// tune monitoring — the Omarchy port of the macOS menu bar app.
Panel {
  id: root
  moduleName: "pinroutes"
  ipcTarget: "pinroutes"
  manageIpc: false

  property int routeCursor: -1
  property string editingId: ""     // rule being edited, or "" when the form adds
  property bool formOpen: false
  property string formError: ""

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Color.accent) : "transparent"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function statusColor(status) {
    if (status === "active") return foreground
    if (status === "missing") return urgent
    return dim
  }

  function statusLabel(status) {
    if (status === "active") return "pinned"
    if (status === "missing") return "missing"
    if (status === "standby") return "standby"
    if (status === "disabled") return "disabled"
    return "checking"
  }

  function openForm(rule) {
    editingId = rule ? rule.id : ""
    nameField.text = rule ? rule.name : ""
    networkField.text = rule ? rule.network : ""
    gatewayField.text = rule ? rule.gateway : ""
    formError = ""
    formOpen = true
    Qt.callLater(function() { nameField.forceActiveFocus() })
  }

  function closeForm() {
    formOpen = false
    editingId = ""
    formError = ""
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function submitForm() {
    var error = editingId !== ""
      ? pin.updateRoute(editingId, nameField.text, networkField.text, gatewayField.text)
      : pin.addRoute(nameField.text, networkField.text, gatewayField.text)
    if (error !== "") formError = error
    else closeForm()
  }

  function moveRouteCursor(delta) {
    if (pin.routes.length === 0) return
    if (routeCursor < 0) routeCursor = delta > 0 ? 0 : pin.routes.length - 1
    else routeCursor = Math.max(0, Math.min(pin.routes.length - 1, routeCursor + delta))
  }

  onOpenedChanged: if (opened) {
    routeCursor = -1
    formOpen = false
    editingId = ""
    pin.checkHelper()
    pin.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // Shared singleton engine — one instance across all per-monitor bar copies.
  readonly property QtObject pin: Service

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { pin.refresh(); return "ok" }
    function apply(): string { pin.applyMissing(true); return "ok" }
    function status(): string { return pin.statusText }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰐃"
    active: pin.missingCount > 0
    dimmed: !pin.monitorEnabled
    tooltipText: "PinRoutes — " + pin.statusText
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) pin.applyMissing(true)
      else if (buttonCode === Qt.MiddleButton) pin.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.formOpen
      onMoveRequested: function(dx, dy) { if (dy !== 0) root.moveRouteCursor(dy) }
      onActivateRequested: {
        if (root.routeCursor >= 0 && root.routeCursor < pin.routes.length)
          pin.applyRule(pin.routes[root.routeCursor])
      }
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "a" || t === "A") pin.applyMissing(true)
        else if (t === "n" || t === "N") root.openForm(null)
        else if (t === "r" || t === "R") pin.refresh()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            id: hero
            width: parent.width
            title: "PinRoutes"
            meta: pin.statusText
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: pin.monitorEnabled ? 1.0 : 0.5
            iconComponent: Component {
              Text {
                text: "󰐃"
                color: pin.missingCount > 0 ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
            trailingControl: Component {
              ToggleSwitch {
                id: monitorSwitch
                checked: pin.monitorEnabled
                busy: false
                foreground: hero.foreground
                onToggled: pin.setMonitorEnabled(!pin.monitorEnabled)

                PanelToolTip {
                  visible: monitorSwitch.containsMouse
                  text: pin.monitorEnabled ? "Turn monitoring off" : "Turn monitoring on"
                  fontFamily: root.fontFamily
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: pin.actionStatus !== "" || pin.lastError !== ""
            width: parent.width
            text: pin.actionStatus !== "" ? pin.actionStatus : pin.lastError
            color: pin.lastError !== "" && pin.actionStatus === "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          PanelSeparator { foreground: root.foreground }

          Column {
            width: parent.width
            spacing: Style.space(10)

            RowLayout {
              width: parent.width

              PanelSectionHeader {
                text: "ROUTES"
                foreground: root.foreground
                fontFamily: root.fontFamily
                Layout.fillWidth: true
              }

              PanelActionButton {
                iconText: "󰑐"
                tooltipText: "Re-apply missing routes"
                visible: pin.missingCount > 0
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: pin.applyMissing(true)
              }

              PanelActionButton {
                iconText: "󰐕"
                tooltipText: "Add route"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.openForm(null)
              }
            }

            Text {
              visible: pin.routes.length === 0
              width: parent.width
              text: "No routes yet — add one to keep it pinned."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }

            Column {
              id: routeColumn
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: pin.routes
                RouteRow {
                  required property var modelData
                  required property int index
                  width: routeColumn.width
                  rule: modelData
                  rowIndex: index
                }
              }
            }
          }

          Column {
            visible: root.formOpen
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: root.editingId !== "" ? "EDIT ROUTE" : "ADD ROUTE"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            TextField {
              id: nameField
              width: parent.width
              foreground: root.foreground
              placeholderText: "Name (e.g. Office VPN subnet)"
              onAccepted: networkField.forceActiveFocus()
              Keys.onEscapePressed: root.closeForm()
            }

            TextField {
              id: networkField
              width: parent.width
              foreground: root.foreground
              placeholderText: "Network CIDR (e.g. 10.255.0.0/16)"
              onAccepted: gatewayField.forceActiveFocus()
              Keys.onEscapePressed: root.closeForm()
            }

            TextField {
              id: gatewayField
              width: parent.width
              foreground: root.foreground
              placeholderText: "Gateway (e.g. 10.0.0.1)"
              onAccepted: root.submitForm()
              Keys.onEscapePressed: root.closeForm()
            }

            Text {
              textFormat: Text.PlainText
              visible: root.formError !== ""
              width: parent.width
              text: root.formError
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            RowLayout {
              width: parent.width
              spacing: Style.space(8)

              Item { Layout.fillWidth: true }

              Button {
                text: "Cancel"
                foreground: root.foreground
                fontFamily: root.fontFamily
                bordered: true
                onClicked: root.closeForm()
              }

              Button {
                text: root.editingId !== "" ? "Save" : "Add"
                foreground: root.foreground
                fontFamily: root.fontFamily
                bordered: true
                onClicked: root.submitForm()
              }
            }
          }

          PanelSeparator { foreground: root.foreground }

          Column {
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: "SETTINGS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Toggle {
              width: parent.width
              label: "Auto-reapply"
              description: pin.helperInstalled
                ? "Put missing routes back automatically"
                : "Needs the helper below for silent re-apply"
              checked: pin.autoReapply
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: pin.setAutoReapply(!pin.autoReapply)
            }

            Toggle {
              width: parent.width
              label: "Notify when missing"
              description: "Desktop notification when a route disappears"
              checked: pin.notifyOnMissing
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: pin.setNotifyOnMissing(!pin.notifyOnMissing)
            }

            NumberField {
              width: parent.width
              label: "Check interval (seconds)"
              value: pin.intervalSec
              from: 15
              to: 600
              stepSize: 15
              foreground: root.foreground
              fontFamily: root.fontFamily
              onModified: function(v) { pin.setIntervalSec(v) }
            }
          }

          PanelSeparator { foreground: root.foreground }

          Column {
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: "HELPER"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            CursorSurface {
              visible: !pin.helperInstalled
              width: parent.width
              implicitHeight: installRow.implicitHeight + Style.spacing.rowPaddingX
              foreground: root.foreground
              fill: root.hoverFill

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: pin.installHelper()
              }

              RowLayout {
                id: installRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(10)
                spacing: Style.space(8)

                Text {
                  text: "󰒃"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.heading
                  Layout.alignment: Qt.AlignVCenter
                }

                ColumnLayout {
                  Layout.fillWidth: true
                  spacing: Style.space(1)

                  Text {
                    Layout.fillWidth: true
                    text: "Install helper"
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                  }

                  Text {
                    Layout.fillWidth: true
                    text: "One password prompt now; silent route fixes forever after"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                  }
                }
              }
            }

            RowLayout {
              visible: pin.helperInstalled
              width: parent.width
              spacing: Style.space(8)

              Text {
                Layout.fillWidth: true
                text: "Helper installed — route fixes are silent"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }

              PanelActionButton {
                iconText: "󰆴"
                tooltipText: "Uninstall helper"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: pin.uninstallHelper()
              }
            }
          }
        }
      }
    }
  }

  // Route details need the row's full width to stay readable, so only the
  // status dot and the enable switch are permanent chrome. The action buttons
  // share the name line and fade in on hover / keyboard cursor — they always
  // occupy layout space so the row never jumps.
  component RouteRow: CursorSurface {
    id: routeRow
    property var rule: null
    property int rowIndex: 0
    readonly property string status: rule ? pin.statusOf(rule.id) : "unknown"
    readonly property bool hot: hasCursor

    hasCursor: root.routeCursor === rowIndex
    foreground: root.foreground
    fill: root.hoverFill

    implicitHeight: Math.max(routeContent.implicitHeight, enabledSwitch.implicitHeight) + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.ArrowCursor
      onContainsMouseChanged: if (containsMouse) root.routeCursor = routeRow.rowIndex
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(8)

      Rectangle {
        width: Style.space(8)
        height: Style.space(8)
        radius: width / 2
        color: root.statusColor(routeRow.status)
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        id: routeContent
        Layout.fillWidth: true
        spacing: Style.space(1)

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(2)

          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            text: routeRow.rule ? routeRow.rule.name : ""
            color: routeRow.status === "disabled" ? root.dim : root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }

          // Hover-revealed actions: they keep their slot when hidden so the
          // row never shifts, and only accept clicks while shown.
          PanelActionButton {
            readonly property bool usable: routeRow.hot && routeRow.status !== "disabled" && routeRow.status !== "standby"
            iconText: "󰑐"
            tooltipText: "Re-apply now"
            foreground: root.foreground
            fontFamily: root.fontFamily
            opacity: usable ? 1.0 : 0.0
            enabled: usable
            Layout.alignment: Qt.AlignVCenter
            Behavior on opacity { NumberAnimation { duration: 120 } }
            onClicked: pin.applyRule(routeRow.rule)
          }

          PanelActionButton {
            iconText: "󰏫"
            tooltipText: "Edit"
            foreground: root.foreground
            fontFamily: root.fontFamily
            opacity: routeRow.hot ? 1.0 : 0.0
            enabled: routeRow.hot
            Layout.alignment: Qt.AlignVCenter
            Behavior on opacity { NumberAnimation { duration: 120 } }
            onClicked: root.openForm(routeRow.rule)
          }

          PanelActionButton {
            iconText: "󰆴"
            tooltipText: "Delete"
            foreground: root.foreground
            fontFamily: root.fontFamily
            opacity: routeRow.hot ? 1.0 : 0.0
            enabled: routeRow.hot
            Layout.alignment: Qt.AlignVCenter
            Behavior on opacity { NumberAnimation { duration: 120 } }
            onClicked: pin.removeRoute(routeRow.rule.id)
          }
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          // Standby gets its own line below; keep this one to the route itself.
          text: {
            if (!routeRow.rule) return ""
            if (routeRow.status === "standby") return routeRow.rule.network + " via " + routeRow.rule.gateway
            return routeRow.rule.network + " via " + routeRow.rule.gateway + " · " + root.statusLabel(routeRow.status)
          }
          color: routeRow.status === "missing" ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          visible: routeRow.status === "standby"
          text: "󰒲 gateway unreachable"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      ToggleSwitch {
        id: enabledSwitch
        checked: routeRow.rule ? routeRow.rule.enabled : false
        foreground: root.foreground
        Layout.alignment: Qt.AlignVCenter
        onToggled: pin.setRouteEnabled(routeRow.rule.id, !routeRow.rule.enabled)

        PanelToolTip {
          visible: enabledSwitch.containsMouse
          text: routeRow.rule && routeRow.rule.enabled ? "Disable" : "Enable"
          fontFamily: root.fontFamily
        }
      }
    }

  }
}
