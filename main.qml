import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import QtQuick.Layouts
import Qt.labs.folderlistmodel
import org.qfield
import org.qgis
import Theme
import "qrc:/qml" as QFieldItems

Item {
    id: plugin

    property var mainWindow: iface.mainWindow()
    property string exportPickerPath:     ""     // path chosen via export file picker (empty = not used)
    property bool   _isExportMode:        false  // toggles Import/Export view in the combined dialog
    property bool   _exportLabelUpdating: false  // guard against model-rebuild triggering reload

    // ── Loaded GPX file info (set in readAndLoadGpxFile; used in field mapping)
    property string _importedFileName:   ""   // filename without extension
    property string _importedFolderName: ""   // parent folder name

    // ── Recursive GPX scan state ──────────────────────────────────────────────
    property var    _gpxScanQueue:       []   // dirs still to scan: [{path, label}, …]
    property bool   _gpxScanning:        false
    property string _gpxCurrentDirLabel: ""   // label prefix for current subdir scan
    property int    _gpxScanVersion:     0    // incremented on each refreshGpxFolder()

    // Field names of the currently selected import layer (for mapping UI)
    property var layerFieldNames: []

    // ── Device file picker (Browse device storage…) ──────────────────────────
    // Holds the in-flight ResourceSource while platformUtilities.getFile() is
    // waiting for the user to pick a file via the OS file picker / SAF.
    property ResourceSource _gpxResourceSource: null

    // ── Last successful export (for "Export to folder…" / "Send…") ───────────
    property string _lastExportedPath: ""

    // GPX tags we know how to detect and map

    Component.onCompleted: {
        iface.addItemToPluginsToolbar(gpxButton)
    }

    // React to a file picked via platformUtilities.getFile() (Browse device
    // storage). The picked file is copied by QField into
    // <project>/tmp/<relativePath>; we then load it like any other GPX file.
    Connections {
        target: _gpxResourceSource
        function onResourceReceived(path) {
            if (path) {
                readAndLoadGpxFile(qgisProject.homePath + "/tmp/" + path)
            } else {
                statusLabel.text = qsTr("No file selected.")
            }
        }
    }

    // Open the OS-native file picker (SAF on Android, native dialog on
    // desktop) so the user can pick a GPX file from anywhere on the device,
    // not just the project folder. The picked file is copied into
    // <project>/tmp/ and then read normally.
    function browseDeviceGpxFile() {
        platformUtilities.requestStoragePermission()
        _gpxResourceSource = platformUtilities.getFile(qgisProject.homePath + "/tmp/", "{filename}", "*/*", plugin)
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  Recursive GPX file scanner
    //  Scans project root + all immediate sub-directories; results collected
    //  into gpxFilesModel which drives the import ComboBox.
    // ══════════════════════════════════════════════════════════════════════════

    // Aggregated results: { displayName: string, filePath: string }
    ListModel { id: gpxFilesModel }

    // ── Project root: GPX files + sub-directories (one model, one Instantiator)
    // nameFilters filters files only — directories always pass through in Qt's
    // FolderListModel, so showDirs:true gives us dirs alongside matching files.
    FolderListModel {
        id: gpxRootScanModel
        nameFilters: ["*.gpx", "*.GPX"]
        showDirs:   true
        showFiles:  true
        showHidden: false
    }
    Instantiator {
        model: gpxRootScanModel
        delegate: QtObject {
            property bool   _isDir: fileIsDir
            property string _dn:    fileName
            property string _dp:    filePath
            Component.onCompleted: {
                if (_isDir) {
                    // Queue the sub-directory for a GPX scan
                    _gpxScanQueue.push({ path: _dp, label: _dn })
                    if (!_gpxScanning) _gpxProcessNextDir()
                } else {
                    // It's a GPX file — add directly to the dropdown
                    gpxFilesModel.append({ displayName: _dn, filePath: _dp })
                }
            }
        }
    }

    // ── Scan one sub-directory at a time ──────────────────────────────────────
    FolderListModel {
        id: gpxSubdirScanModel
        nameFilters: ["*.gpx", "*.GPX"]
        showDirs:   false
        showHidden: false
        onStatusChanged: {
            if (status !== FolderListModel.Ready) return
            var v = _gpxScanVersion
            Qt.callLater(function() {
                if (_gpxScanVersion !== v) return   // stale — a new refresh started
                _gpxScanning = false
                _gpxProcessNextDir()
            })
        }
    }
    Instantiator {
        model: gpxSubdirScanModel
        delegate: QtObject {
            property string _dp: filePath
            property string _dn: fileName
            property string _dl: _gpxCurrentDirLabel   // label captured at creation time
            Component.onCompleted: {
                gpxFilesModel.append({ displayName: _dl + "/" + _dn, filePath: _dp })
            }
        }
    }

    // ── FeatureModel for import (batch mode) ─────────────────────────────────
    FeatureModel {
        id: importFeatureModel
        project: qgisProject
    }

    // ── Feature checklist for selective export ────────────────────────────────
    // items: { wkt: string, label: string, checked: bool }
    ListModel { id: exportFeaturesModel }

    // ── Field-mapping state (one row per detected GPX tag) ───────────────────
    ListModel {
        id: fieldMappingModel
        // items: { fieldName: string, sourceTag: string }
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  Single toolbar button — opens the combined Import / Export dialog
    // ══════════════════════════════════════════════════════════════════════════

    QfToolButton {
        id: gpxButton
        bgcolor: Theme.darkGray
        iconSource: "icon.svg"
        iconColor: Theme.mainColor
        round: true
        onClicked: {
            // Default to Import mode; reset import state
            _isExportMode = false
            refreshLayers()
            fileLabel.text = qsTr("No file selected")
            gpxTextArea.text = ""
            fieldMappingModel.clear()
            statusLabel.text = ""
            progressBar.visible = false
            refreshGpxFolder()
            gpxDialog.open()
        }
    }

    Dialog {
        id: gpxDialog
        parent: mainWindow.contentItem
        title: qsTr("GPX Appender v0.1")
        standardButtons: Dialog.Close
        closePolicy: Popup.CloseOnEscape

        onClosed: {
            progressBar.indeterminate = false
            progressBar.visible = false
        }

        anchors.centerIn: parent
        width:  parent.width - 20
        height: Math.min(implicitHeight, parent.height - Theme.popupScreenEdgeMargin * 2)

        // FileDialog lives here (non-visual, accessible from all tabs)
        FileDialog {
            id: gpxFileDialog
            title: qsTr("Select a GPX file")
            nameFilters: ["GPX files (*.gpx)", "All files (*)"]
            onAccepted: {
                var url  = gpxFileDialog.selectedFile.toString()
                var path = url.replace(/^file:\/\/\/(?=[a-zA-Z]:)/, "").replace(/^file:\/\//, "")
                readAndLoadGpxFile(path)
            }
        }

        ColumnLayout {
            id: dialogLayout
            anchors.left:  parent.left
            anchors.right: parent.right
            spacing: 8

            // ── Import / Export toggle ────────────────────────────────────────
            RowLayout {
                Layout.fillWidth: true
                spacing: 4
                Button {
                    text: qsTr("Import")
                    Layout.fillWidth: true
                    highlighted: !_isExportMode
                    font: Theme.defaultFont
                    onClicked: _isExportMode = false
                }
                Button {
                    text: qsTr("Export")
                    Layout.fillWidth: true
                    highlighted: _isExportMode
                    font: Theme.defaultFont
                    onClicked: {
                        _isExportMode = true
                        exportPickerPath = ""
                        _lastExportedPath = ""
                        refreshLayersForExport()
                        exportStatusLabel.text = ""
                        exportProgressBar.visible = false
                        var ln = exportLayerSelector.currentText
                        if (ln && exportFilenameField.text.trim() === "")
                            exportFilenameField.text = ln.replace(/[\\/:*?"<>|]/g, "_")
                    }
                }
            }

            // ══════════════════════════════════════════════════════════════════
            //  IMPORT section
            // ══════════════════════════════════════════════════════════════════
            ColumnLayout {
                visible: !_isExportMode
                Layout.fillWidth: true
                spacing: 8

            // ── Scrollable content (everything except progress/status) ────────
            ScrollView {
                id: importScrollView
                Layout.fillWidth: true
                Layout.preferredHeight: Math.min(importContent.implicitHeight, mainWindow.height * 0.45)
                clip: true
                ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                ScrollBar.vertical.policy:   ScrollBar.AsNeeded

            ColumnLayout {
                id: importContent
                width: importScrollView.width - importScrollView.ScrollBar.vertical.width - 4
                spacing: 8

            // ── Destination layer ─────────────────────────────────────────────
            Label { text: qsTr("Destination layer"); font: Theme.defaultFont; color: Theme.mainTextColor }
            ComboBox {
                id: layerSelector
                Layout.fillWidth: true
                model: []
                font: Theme.defaultFont
                onCurrentTextChanged: {
                    if (gpxTextArea.text.trim() !== "")
                        buildFieldMapping(gpxTextArea.text)
                }
            }

            // ── Tab bar ───────────────────────────────────────────────────────
            TabBar {
                id: importTabBar
                Layout.fillWidth: true
                font: Theme.tipFont
                TabButton { text: qsTr("File") }
                TabButton { text: qsTr("Content") }
                TabButton { text: qsTr("Field Map") }
            }

            // ── Tab pages ────────────────────────────────────────────────────
            StackLayout {
                Layout.fillWidth: true
                currentIndex: importTabBar.currentIndex

                // ── Tab 0 : File ──────────────────────────────────────────────
                ColumnLayout {
                    width: parent.width
                    spacing: 10

                    Label {
                        Layout.fillWidth: true
                        text: qsTr("From project folder:")
                        font: Theme.tipFont; color: Theme.secondaryTextColor
                    }
                    ComboBox {
                        id: gpxFileCombo
                        Layout.fillWidth: true
                        font: Theme.defaultFont
                        model: gpxFilesModel
                        textRole: "displayName"
                        enabled: gpxFilesModel.count > 0
                        displayText: gpxFilesModel.count > 0 ? currentText
                                                             : qsTr("(no .gpx files found)")
                        onActivated: {
                            if (currentIndex >= 0 && currentIndex < gpxFilesModel.count) {
                                var fp = gpxFilesModel.get(currentIndex).filePath
                                if (fp) readAndLoadGpxFile(fp)
                            }
                        }
                    }
                    Label {
                        text: qsTr("— or browse —")
                        font: Theme.tipFont; color: Theme.secondaryTextColor
                        Layout.fillWidth: true
                        horizontalAlignment: Text.AlignHCenter
                    }
                    Label {
                        Layout.fillWidth: true
                        font: Theme.tipFont; color: Theme.secondaryTextColor
                        wrapMode: Text.Wrap; opacity: 0.7
                        text: qsTr("Note: 'Browse…' may not reach files outside the project folder on some devices — use 'Browse device storage…' instead.")
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        Button {
                            text: qsTr("Browse…")
                            font: Theme.defaultFont
                            onClicked: gpxFileDialog.open()
                        }
                        Label {
                            id: fileLabel
                            Layout.fillWidth: true
                            text: qsTr("No file selected")
                            font: Theme.tipFont
                            color: Theme.secondaryTextColor
                            elide: Text.ElideMiddle
                        }
                    }
                    Button {
                        Layout.fillWidth: true
                        text: qsTr("Browse device storage…")
                        font: Theme.defaultFont
                        visible: platformUtilities.capabilities & PlatformUtilities.FilePicker
                        onClicked: browseDeviceGpxFile()
                    }
                    Button {
                        Layout.fillWidth: true
                        text: qsTr("📋  Paste from clipboard")
                        font: Theme.defaultFont
                        onClicked: {
                            progressBar.indeterminate = true
                            progressBar.visible = true
                            gpxTextArea.selectAll()
                            gpxTextArea.paste()
                            Qt.callLater(function() {
                                progressBar.indeterminate = false
                                progressBar.visible = false
                                if (gpxTextArea.text.trim().length > 0) {
                                    gpxTextArea.cursorPosition = 0
                                    onGpxLoaded(gpxTextArea.text)
                                    importTabBar.currentIndex = 1  // jump to Content tab
                                }
                            })
                        }
                    }
                    Button {
                        Layout.fillWidth: true
                        text: qsTr("Import")
                        font: Theme.defaultFont
                        enabled: gpxTextArea.text.trim() !== "" && layerSelector.currentIndex >= 0
                        onClicked: startImport()
                    }
                }   // end Tab 0

                // ── Tab 1 : Content ───────────────────────────────────────────
                ColumnLayout {
                    width: parent.width
                    spacing: 10

                    Label {
                        Layout.fillWidth: true
                        text: qsTr("GPX content — paste or edit below:")
                        font: Theme.tipFont; color: Theme.secondaryTextColor
                    }
                    // Full-width divider line
                    Rectangle {
                        Layout.fillWidth: true
                        height: 1
                        color: Theme.secondaryTextColor
                        opacity: 0.3
                    }
                    ScrollView {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 260
                        clip: true
                        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                        ScrollBar.vertical.policy:   ScrollBar.AsNeeded

                        TextArea {
                            id: gpxTextArea
                            width: parent.width
                            topPadding: 4; bottomPadding: 4
                            leftPadding: 6; rightPadding: 6
                            placeholderText: text.length > 0 ? "" : qsTr("<?xml version=\"1.0\"?>\n<gpx …>\n  …\n</gpx>")
                            wrapMode: TextArea.WrapAnywhere
                            font.family: "monospace"
                            font.pointSize: Theme.tipFont.pointSize
                            background: Rectangle { color: "transparent" }
                            onTextChanged: {
                                if (text.trim().length > 0 && !activeFocus)
                                    onGpxLoaded(text)
                            }
                        }
                    }
                    Button {
                        Layout.fillWidth: true
                        text: qsTr("Import")
                        font: Theme.defaultFont
                        enabled: gpxTextArea.text.trim() !== "" && layerSelector.currentIndex >= 0
                        onClicked: startImport()
                    }
                }   // end Tab 1

                // ── Tab 2 : Field mapping ─────────────────────────────────────
                ColumnLayout {
                    width: parent.width
                    spacing: 10

                    Label {
                        Layout.fillWidth: true
                        text: fieldMappingModel.count > 0
                              ? qsTr("Layer field  →  GPX source  (or ignore):")
                              : qsTr("Load a file first to see field mapping.")
                        font: Theme.tipFont; color: Theme.secondaryTextColor; wrapMode: Text.Wrap
                    }
                    // No inner ScrollView here — the outer importScrollView
                    // handles scrolling for the whole tab, so the field
                    // mapping rows just lay out at their natural height.
                    ColumnLayout {
                        Layout.fillWidth: true
                        visible: fieldMappingModel.count > 0
                        spacing: 0
                        Repeater {
                            model: fieldMappingModel
                            delegate: RowLayout {
                                Layout.fillWidth: true
                                spacing: 8
                                property int rowIdx: index
                                property var sources: ["(ignore)","name","time","desc","cmt","ele",
                                                       "sat","hdop","vdop","pdop","sym","type",
                                                       "fix","speed","course","magvar",
                                                       "filename","foldername"]
                                Label {
                                    text: fieldName
                                    font: Theme.defaultFont
                                    color: Theme.mainTextColor
                                    Layout.preferredWidth: 90
                                    elide: Text.ElideRight
                                }
                                ComboBox {
                                    Layout.fillWidth: true
                                    font: Theme.tipFont
                                    model: parent.sources
                                    currentIndex: {
                                        var idx = parent.sources.indexOf(sourceTag)
                                        return idx >= 0 ? idx : 0
                                    }
                                    onCurrentIndexChanged: {
                                        fieldMappingModel.setProperty(rowIdx, "sourceTag",
                                                                      parent.sources[currentIndex])
                                    }
                                }
                            }
                        }
                    }
                    Button {
                        Layout.fillWidth: true
                        text: qsTr("Import")
                        font: Theme.defaultFont
                        enabled: gpxTextArea.text.trim() !== "" && layerSelector.currentIndex >= 0
                        onClicked: startImport()
                    }
                }   // end Tab 2

            }   // end StackLayout

            }   // end importContent ColumnLayout
            }   // end importScrollView

            // ── Status / progress (always visible, below tabs) ────────────────
            ProgressBar {
                id: progressBar
                Layout.fillWidth: true
                visible: false
                from: 0; to: 1; value: 0
                indeterminate: false
            }
            Label {
                id: statusLabel
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                font: Theme.tipFont
                color: Theme.secondaryTextColor
                text: ""
            }

            }   // end import ColumnLayout

            // ══════════════════════════════════════════════════════════════════
            //  EXPORT section
            // ══════════════════════════════════════════════════════════════════
            ColumnLayout {
                visible: _isExportMode
                Layout.fillWidth: true
                spacing: 12

            // ── Scrollable content (everything except Export/status/share) ────
            ScrollView {
                id: exportScrollView
                Layout.fillWidth: true
                Layout.preferredHeight: Math.min(exportContent.implicitHeight, mainWindow.height * 0.45)
                clip: true
                ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                ScrollBar.vertical.policy:   ScrollBar.AsNeeded

            ColumnLayout {
                id: exportContent
                width: exportScrollView.width - exportScrollView.ScrollBar.vertical.width - 4
                spacing: 12

                Label { text: qsTr("Layer to export"); font: Theme.defaultFont; color: Theme.mainTextColor }
                ComboBox {
                    id: exportLayerSelector
                    Layout.fillWidth: true
                    model: []
                    font: Theme.defaultFont
                    onCurrentTextChanged: {
                        updateExportLabelSelector()
                        loadExportFeatures()
                        if (exportFilenameField.text.trim() === "" && currentText !== "")
                            exportFilenameField.text = currentText.replace(/[\\/:*?"<>|]/g, "_")
                    }
                }

                // ── Label field ───────────────────────────────────────────────
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 6
                    Label { text: qsTr("Label field:"); font: Theme.tipFont; color: Theme.secondaryTextColor }
                    ComboBox {
                        id: exportLabelSelector
                        Layout.fillWidth: true
                        font: Theme.tipFont
                        model: ["(auto)"]
                        onCurrentTextChanged: {
                            if (_exportLabelUpdating) return
                            if (exportFeaturesModel.count > 0) loadExportFeatures()
                        }
                    }
                }

                // ── Feature checklist ─────────────────────────────────────────
                RowLayout {
                    Layout.fillWidth: true
                    Label {
                        id: exportFeaturesLabel
                        Layout.fillWidth: true
                        text: exportFeaturesModel.count > 0
                              ? qsTr("%1 feature(s) — tick to select:").arg(exportFeaturesModel.count)
                              : qsTr("No features loaded")
                        font: Theme.tipFont; color: Theme.secondaryTextColor; wrapMode: Text.Wrap
                    }
                    Button {
                        text: qsTr("All"); font: Theme.tipFont
                        visible: exportFeaturesModel.count > 0
                        onClicked: { for (var i = 0; i < exportFeaturesModel.count; i++) exportFeaturesModel.setProperty(i, "checked", true) }
                    }
                    Button {
                        text: qsTr("None"); font: Theme.tipFont
                        visible: exportFeaturesModel.count > 0
                        onClicked: { for (var i = 0; i < exportFeaturesModel.count; i++) exportFeaturesModel.setProperty(i, "checked", false) }
                    }
                }
                // No inner ScrollView here — the outer exportScrollView
                // handles scrolling for the whole export tab.
                ColumnLayout {
                    Layout.fillWidth: true
                    visible: exportFeaturesModel.count > 0
                    spacing: 0
                    Repeater {
                        model: exportFeaturesModel
                        delegate: CheckBox {
                            Layout.fillWidth: true
                            text: label
                            checked: model.checked
                            font: Theme.tipFont
                            onCheckedChanged: exportFeaturesModel.setProperty(index, "checked", checked)
                        }
                    }
                }

                // ── File name → project/GPX/ ──────────────────────────────────
                Label {
                    text: qsTr("File name  (saved to project GPX folder)")
                    font: Theme.defaultFont; color: Theme.mainTextColor
                }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 4
                    TextField {
                        id: exportFilenameField
                        Layout.fillWidth: true
                        font: Theme.defaultFont
                        placeholderText: qsTr("e.g. my_track")
                    }
                    Label { text: qsTr(".gpx"); font: Theme.defaultFont; color: Theme.secondaryTextColor }
                }
                // ── File picker (optional, works well on Windows/desktop) ────────
                Label {
                    Layout.fillWidth: true
                    text: qsTr("— or choose a specific save location —")
                    font: Theme.tipFont; color: Theme.secondaryTextColor
                    horizontalAlignment: Text.AlignHCenter
                }
                Label {
                    Layout.fillWidth: true
                    font: Theme.tipFont; color: Theme.secondaryTextColor
                    wrapMode: Text.Wrap; opacity: 0.7
                    text: qsTr("Note: locations outside the project folder may not be accessible on all devices.")
                }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Button {
                        text: qsTr("Choose…")
                        font: Theme.defaultFont
                        onClicked: exportSaveDialog.open()
                    }
                    Label {
                        id: exportPathLabel
                        Layout.fillWidth: true
                        text: exportPickerPath !== "" ? exportPickerPath : qsTr("No location chosen")
                        font: Theme.tipFont
                        color: exportPickerPath !== "" ? Theme.mainTextColor : Theme.secondaryTextColor
                        elide: Text.ElideMiddle
                        wrapMode: Text.Wrap
                    }
                    Button {
                        text: qsTr("✕")
                        font: Theme.tipFont
                        visible: exportPickerPath !== ""
                        onClicked: exportPickerPath = ""
                    }
                }
                FileDialog {
                    id: exportSaveDialog
                    title: qsTr("Save GPX as…")
                    fileMode: FileDialog.SaveFile
                    nameFilters: ["GPX files (*.gpx)", "All files (*)"]
                    onAccepted: {
                        var url = exportSaveDialog.selectedFile.toString()
                        exportPickerPath = url.replace(/^file:\/\/\/(?=[a-zA-Z]:)/, "")
                                             .replace(/^file:\/\//, "")
                    }
                }

            }   // end exportContent ColumnLayout
            }   // end exportScrollView

                Button {
                    id: exportButton2
                    Layout.fillWidth: true
                    text: qsTr("Export")
                    font: Theme.defaultFont
                    enabled: exportLayerSelector.currentIndex >= 0
                          && (exportFilenameField.text.trim() !== "" || exportPickerPath !== "")
                    onClicked: startExport()
                }
                ProgressBar {
                    id: exportProgressBar
                    Layout.fillWidth: true
                    visible: false
                    from: 0; to: 1; value: 0
                    indeterminate: false
                }
                Label {
                    id: exportStatusLabel
                    Layout.fillWidth: true
                    wrapMode: Text.Wrap
                    font: Theme.tipFont; color: Theme.secondaryTextColor
                    text: ""
                }

                // ── Hand the exported file to the OS (Android) ────────────────
                // exportDatasetTo opens the native "save to folder" picker
                // (SAF), letting the user copy the file anywhere on the
                // device — including outside the project folder.
                // sendDatasetTo opens the native share sheet (email, Drive,
                // Bluetooth, etc.). Neither is available on desktop, where
                // the file picker above already covers this.
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    visible: _lastExportedPath !== ""
                          && (platformUtilities.capabilities & (PlatformUtilities.CustomExport | PlatformUtilities.CustomSend))
                    Button {
                        Layout.fillWidth: true
                        text: qsTr("Export to folder…")
                        font: Theme.defaultFont
                        visible: platformUtilities.capabilities & PlatformUtilities.CustomExport
                        onClicked: platformUtilities.exportDatasetTo(_lastExportedPath)
                    }
                    Button {
                        Layout.fillWidth: true
                        text: qsTr("Send…")
                        font: Theme.defaultFont
                        visible: platformUtilities.capabilities & PlatformUtilities.CustomSend
                        onClicked: platformUtilities.sendDatasetTo(_lastExportedPath)
                    }
                }
            }   // end export ColumnLayout

        }   // end outer ColumnLayout
    }   // end gpxDialog

    // ══════════════════════════════════════════════════════════════════════════
    //  IMPORT logic
    // ══════════════════════════════════════════════════════════════════════════

    // Build a correctly-formed file:// URL from a plain path or an existing URL.
    // Handles Windows (C:\...), Unix/Android (/storage/...) and file:// inputs.
    function toFolderUrl(plainPath) {
        if (!plainPath) return ""
        var s = plainPath.toString()
        if (s.startsWith("file://"))
            return s.replace(/\/?$/, "")          // strip any trailing slash
        var p = s.replace(/\\/g, "/").replace(/\/$/, "")
        var prefix = p.match(/^[a-zA-Z]:/) ? "file:///" : "file://"
        var encoded = p.split("/").map(function(seg) {
            return seg.replace(/ /g, "%20")
        }).join("/")
        return prefix + encoded
    }

    // Kick off a fresh recursive scan of the project home directory.
    function refreshGpxFolder() {
        var raw = qgisProject.homePath || ""

        // Reset scan state
        _gpxScanVersion++
        _gpxScanQueue  = []
        _gpxScanning   = false
        _gpxCurrentDirLabel = ""
        gpxFilesModel.clear()

        // Clear all models before pointing at the new location
        gpxRootScanModel.folder   = ""
        gpxSubdirScanModel.folder = ""

        var rootUrl = toFolderUrl(raw)

        // Defer so model clearing takes effect before we set the new URL
        Qt.callLater(function() {
            gpxRootScanModel.folder = rootUrl   // files + sub-dirs in root
        })
    }

    // Advance to the next queued sub-directory scan.
    // Called when a sub-directory scan completes or when a new dir is enqueued
    // and nothing is currently scanning.
    function _gpxProcessNextDir() {
        if (_gpxScanQueue.length === 0) return
        var next = _gpxScanQueue.shift()
        _gpxCurrentDirLabel = next.label
        _gpxScanning = true
        gpxSubdirScanModel.folder = ""
        // Convert the plain filePath to a proper file:// URL before assigning
        var url = toFolderUrl(next.path)
        Qt.callLater(function() { gpxSubdirScanModel.folder = url })
    }

    // Read a GPX file from any path and load it into the import dialog.
    // If the file is outside the project directory (e.g. on Android external
    // storage), it is temporarily copied into the project folder to read it,
    // then moved back.  Files already inside the project are read directly.
    function readAndLoadGpxFile(path) {
        // Capture filename (no extension) and parent folder for field mapping
        var cleanPath = path.replace(/\\/g, "/")
        var parts = cleanPath.split("/").filter(function(s) { return s !== "" })
        _importedFileName   = parts.length > 0
            ? parts[parts.length - 1].replace(/\.gpx$/i, "") : ""
        _importedFolderName = parts.length > 1 ? parts[parts.length - 2] : ""

        fileLabel.text = FileUtils.fileName(path)
        statusLabel.text = qsTr("Reading file…")
        progressBar.indeterminate = true
        progressBar.visible = true

        var readPath = path
        var tempPath = ""
        if (!FileUtils.isWithinProjectDirectory(path)) {
            var projDir = qgisProject.homePath
            tempPath = projDir + "/_gpx_tmp_" + FileUtils.fileName(path)
            if (!platformUtilities.renameFile(path, tempPath, true)) {
                statusLabel.text = qsTr("Could not access file. Paste content below.")
                progressBar.visible = false
                return
            }
            readPath = tempPath
        }
        try {
            var raw   = FileUtils.readFileContent(readPath)
            var text  = ""
            var asStr = String(raw)
            if (asStr && asStr.trim().startsWith("<")) {
                text = asStr
            } else if (raw && raw.length > 0) {
                for (var i = 0; i < raw.length; i++)
                    text += String.fromCharCode(raw[i])
            }
            if (text.trim().startsWith("<")) {
                gpxTextArea.text = text
                Qt.callLater(function() { gpxTextArea.cursorPosition = 0 })
                onGpxLoaded(text)
            } else {
                statusLabel.text = qsTr("File not found or content looks wrong. Try Browse or paste below.")
            }
        } catch(e) {
            statusLabel.text = qsTr("Could not read file: ") + e
        }
        if (tempPath !== "")
            platformUtilities.renameFile(tempPath, path, true)
        progressBar.indeterminate = false
        progressBar.value = 1
        progressBar.visible = false
    }

    function onGpxLoaded(xml) {
        // Distinguish true standalone waypoints (<wpt>) from track/route vertices
        // (<trkpt>, <rtept>) which are internal to a line geometry.
        // Only <wpt> elements justify showing point layers in the selector.
        var hasTracks    = xml.indexOf("<trkseg") !== -1 || xml.indexOf("<trk>") !== -1
                        || xml.indexOf("<trk ")   !== -1
        var hasRoutes    = xml.indexOf("<rte>") !== -1 || xml.indexOf("<rte ") !== -1
        var hasLines     = hasTracks || hasRoutes
        var hasWaypoints = xml.indexOf("<wpt ") !== -1 || xml.indexOf("<wpt>") !== -1
        refreshLayers()
        filterLayersByGpx(hasLines, hasWaypoints)
        buildFieldMapping(xml)
        statusLabel.text = summariseGpx(xml)
    }

    // Filter the destination layer selector to types that match the GPX content.
    // hasLines  → include line layers  (tracks and routes import as polylines)
    // hasPoints → include point layers (only true <wpt> waypoints, not trkpt/rtept)
    // If no matching layers exist the full list is left unchanged with a note.
    function filterLayersByGpx(hasLines, hasPoints) {
        if (!hasLines && !hasPoints) return
        var allNames = layerSelector.model
        if (!allNames || allNames.length === 0) return
        var filtered = []
        for (var i = 0; i < allNames.length; i++) {
            var arr = qgisProject.mapLayersByName(allNames[i])
            if (!arr || arr.length === 0) continue
            var gt = arr[0].geometryType ? arr[0].geometryType() : -1
            if (hasLines  && gt === Qgis.GeometryType.Line)  filtered.push(allNames[i])
            if (hasPoints && gt === Qgis.GeometryType.Point) filtered.push(allNames[i])
        }
        if (filtered.length > 0) {
            filtered.sort()
            layerSelector.model = filtered
            layerSelector.currentIndex = 0
        }
        // If no matching layer exists, leave the full list and warn via status
        if (filtered.length === 0) {
            statusLabel.text = hasLines && !hasPoints
                ? qsTr("GPX contains tracks/routes — select a line layer.")
                : hasPoints && !hasLines
                    ? qsTr("GPX contains waypoints — select a point layer.")
                    : ""
        }
    }

    // Build the field mapping model: one row per layer field, source = GPX tag
    // (or "filename" / "foldername" / "(ignore)").
    function buildFieldMapping(xml) {
        fieldMappingModel.clear()
        var layerName = layerSelector.currentText
        if (!layerName) return
        var layer = qgisProject.mapLayersByName(layerName)[0]
        if (!layer) return

        layerFieldNames = layer.fields.names

        for (var fi = 0; fi < layerFieldNames.length; fi++) {
            var fn  = layerFieldNames[fi]
            var src = autoMatchTagForField(fn)
            fieldMappingModel.append({ fieldName: fn, sourceTag: src })
        }
    }

    // Reverse alias lookup: given a layer field name, return the best GPX source tag
    // (or "(ignore)" if no match).
    function autoMatchTagForField(fieldName) {
        var aliases = {
            "ele":    ["ele","elevation","elev","altitude","alt","height"],
            "time":   ["time","timestamp","datetime","date_time","date"],
            "name":   ["name","label"],
            "desc":   ["desc","description","notes"],
            "cmt":    ["cmt","comment","comments","note"],
            "sat":    ["sat","satellites","num_sat"],
            "hdop":   ["hdop"],
            "vdop":   ["vdop"],
            "pdop":   ["pdop"],
            "sym":    ["sym","symbol","icon"],
            "type":   ["type","feature_type","feat_type"],
            "fix":    ["fix","fix_type"],
            "speed":  ["speed"],
            "course": ["course","bearing","direction"],
            "magvar": ["magvar","magnetic_variation"]
        }
        var fn = fieldName.toLowerCase()
        for (var tag in aliases) {
            if (aliases[tag].indexOf(fn) !== -1) return tag
        }
        return "(ignore)"
    }

    function refreshLayers() {
        var layers = ProjectUtils.mapLayers(qgisProject)
        var names = []
        for (var id in layers) {
            var layer = layers[id]
            if (!layer || !layer.supportsEditing) continue
            var gt = layer.geometryType ? layer.geometryType() : -1
            if (gt === Qgis.GeometryType.Point || gt === Qgis.GeometryType.Line)
                names.push(layer.name)
        }
        names.sort()
        layerSelector.model = names
        layerSelector.currentIndex = names.length > 0 ? 0 : -1
    }

    function startImport() {
        var layerName = layerSelector.currentText
        if (!layerName) { statusLabel.text = qsTr("Please select a layer."); return }
        var layer = qgisProject.mapLayersByName(layerName)[0]
        if (!layer) { statusLabel.text = qsTr("Layer not found: ") + layerName; return }
        var xml = gpxTextArea.text.trim()
        if (!xml) { statusLabel.text = qsTr("Please paste GPX content first."); return }

        var gt = layer.geometryType ? layer.geometryType() : -1

        // ── Type-mismatch guard ──────────────────────────────────────────────
        // Detect what the GPX actually contains and warn if the layer type
        // won't produce useful results.
        var hasTracks    = xml.indexOf("<trkseg") !== -1 || xml.indexOf("<trk") !== -1
        var hasRoutes    = xml.indexOf("<rte>")   !== -1 || xml.indexOf("<rte ") !== -1
        var hasWaypoints = xml.indexOf("<wpt ")   !== -1 || xml.indexOf("<wpt>") !== -1

        if (gt === Qgis.GeometryType.Line && !hasTracks && !hasRoutes) {
            statusLabel.text = qsTr("GPX has no tracks or routes — nothing to import into a line layer. Use a point layer for waypoints.")
            return
        }
        if (gt === Qgis.GeometryType.Point && !hasWaypoints && (hasTracks || hasRoutes)) {
            statusLabel.text = qsTr("GPX has tracks/routes but no waypoints — importing into a point layer would create one point per track vertex. Switch to a line layer for a polyline result.")
            return
        }

        statusLabel.text = qsTr("Parsing GPX…")
        progressBar.indeterminate = true
        progressBar.visible = true
        importButton.enabled = false

        var count = (gt === Qgis.GeometryType.Line)
            ? importAsLines(layer, xml)
            : importAsPoints(layer, xml)

        progressBar.indeterminate = false
        progressBar.value = 1.0
        importButton.enabled = true

        if (count > 0) {
            var note = ""
            // Warn when mixed GPX imported into a line layer — waypoints are silently skipped
            if (gt === Qgis.GeometryType.Line && hasWaypoints && (hasTracks || hasRoutes))
                note = qsTr(" (waypoints in this GPX were skipped — line layer only accepts tracks/routes)")
            statusLabel.text = qsTr("%1 feature(s) imported into '%2'.").arg(count).arg(layerName) + note
            mainWindow.displayToast(qsTr("%1 feature(s) imported").arg(count))
        } else {
            statusLabel.text = qsTr("No features found — check the GPX is valid.")
        }
    }

    function gpxPointToLayerCrs(p, layerCrs) {
        var wgs84 = CoordinateReferenceSystemUtils.wgs84Crs()
        var src = (p.ele !== null)
            ? GeometryUtils.point(p.lon, p.lat, p.ele)
            : GeometryUtils.point(p.lon, p.lat)
        return GeometryUtils.reprojectPoint(src, wgs84, layerCrs)
    }

    // Use field mapping model to stamp attributes onto a feature.
    // sourceTag can be a GPX tag name, "filename", "foldername", or "(ignore)".
    function stampMappedFields(feat, p) {
        for (var i = 0; i < fieldMappingModel.count; i++) {
            var item = fieldMappingModel.get(i)
            if (item.sourceTag === "(ignore)") continue
            var val = null
            if      (item.sourceTag === "filename")   val = _importedFileName
            else if (item.sourceTag === "foldername") val = _importedFolderName
            else                                      val = p[item.sourceTag]
            if (val === undefined || val === null || val === "") continue
            var fieldIdx = layerFieldNames.indexOf(item.fieldName)
            if (fieldIdx >= 0) feat.setAttribute(fieldIdx, String(val))
        }
    }

    function importAsPoints(layer, xml) {
        var pts = []
        pts = pts.concat(parsePointElements(xml, "wpt"))
        pts = pts.concat(parsePointElements(xml, "trkpt"))
        pts = pts.concat(parsePointElements(xml, "rtept"))
        if (pts.length === 0) return 0

        var layerCrs = layer.crs
        importFeatureModel.currentLayer = layer
        importFeatureModel.batchMode = true
        var count = 0
        for (var i = 0; i < pts.length; i++) {
            try {
                var p = pts[i]
                var lp = gpxPointToLayerCrs(p, layerCrs)
                if (!lp) continue
                var wkt = (p.ele !== null)
                    ? "POINT Z(" + lp.x + " " + lp.y + " " + lp.z + ")"
                    : "POINT("   + lp.x + " " + lp.y + ")"
                var geom = GeometryUtils.createGeometryFromWkt(wkt)
                if (!geom && p.ele !== null) {
                    wkt  = "POINT(" + lp.x + " " + lp.y + ")"
                    geom = GeometryUtils.createGeometryFromWkt(wkt)
                }
                if (!geom) continue
                var feat = FeatureUtils.createBlankFeature(layer.fields, geom)
                stampMappedFields(feat, p)
                importFeatureModel.feature = feat
                if (importFeatureModel.create()) count++
            } catch(e) {
                iface.logMessage("GPX import point error: " + e)
            }
        }
        importFeatureModel.batchMode = false
        return count
    }

    function importAsLines(layer, xml) {
        var layerCrs = layer.crs
        importFeatureModel.currentLayer = layer
        importFeatureModel.batchMode = true
        var count = 0
        var segs = splitByTag(xml, "trkseg")
        for (var i = 0; i < segs.length; i++) {
            var pts = parsePointElements(segs[i], "trkpt")
            if (pts.length < 2) continue
            var feat = buildLineFeature(layer, pts, "", layerCrs)
            if (feat) { importFeatureModel.feature = feat; if (importFeatureModel.create()) count++ }
        }
        var rtes = splitByTag(xml, "rte")
        for (var j = 0; j < rtes.length; j++) {
            var rpts = parsePointElements(rtes[j], "rtept")
            if (rpts.length < 2) continue
            var rf = buildLineFeature(layer, rpts, extractTagValue(rtes[j], "name") || "", layerCrs)
            if (rf) { importFeatureModel.feature = rf; if (importFeatureModel.create()) count++ }
        }
        importFeatureModel.batchMode = false
        return count
    }

    function buildLineFeature(layer, pts, name, layerCrs) {
        var hasZ = pts.some(function(p) { return p.ele !== null })
        var coords = pts.map(function(p) {
            var lp = gpxPointToLayerCrs(p, layerCrs)
            return hasZ ? (lp.x + " " + lp.y + " " + (p.ele !== null ? lp.z : 0))
                        : (lp.x + " " + lp.y)
        }).join(", ")
        var wkt = hasZ ? "LINESTRING Z(" + coords + ")" : "LINESTRING(" + coords + ")"
        var geom = GeometryUtils.createGeometryFromWkt(wkt)
        if (!geom) return null
        var feat = FeatureUtils.createBlankFeature(layer.fields, geom)
        if (name) trySetField(feat, layer.fields, ["name"], name)
        return feat
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  EXPORT logic
    // ══════════════════════════════════════════════════════════════════════════

    function refreshLayersForExport() {
        var layers = ProjectUtils.mapLayers(qgisProject)
        var names = []
        for (var id in layers) {
            var layer = layers[id]
            if (!layer) continue
            var gt = layer.geometryType ? layer.geometryType() : -1
            if (gt === Qgis.GeometryType.Point || gt === Qgis.GeometryType.Line)
                names.push(layer.name)
        }
        names.sort()
        exportLayerSelector.model = names
        exportLayerSelector.currentIndex = names.length > 0 ? 0 : -1
        updateExportLabelSelector()
        loadExportFeatures()
    }

    // Populate the label-field selector for the current export layer
    function updateExportLabelSelector() {
        var layerName = exportLayerSelector.currentText
        var layer = layerName ? qgisProject.mapLayersByName(layerName)[0] : null
        _exportLabelUpdating = true
        if (!layer || !layer.fields) {
            exportLabelSelector.model = ["(auto)"]
            exportLabelSelector.currentIndex = 0
        } else {
            var names = []
            try { names = layer.fields.names ? layer.fields.names.slice() : [] } catch(e) {}
            names.sort()
            exportLabelSelector.model = ["(auto)"].concat(names)
            exportLabelSelector.currentIndex = 0
        }
        _exportLabelUpdating = false
    }

    // Load all layer features into the checklist model (called on layer/label-field change)
    function loadExportFeatures() {
        exportFeaturesModel.clear()
        var layerName = exportLayerSelector.currentText
        if (!layerName) return
        var layer = qgisProject.mapLayersByName(layerName)[0]
        if (!layer) return

        layer.selectAll()
        var features = null
        try { features = layer.selectedFeatures ? layer.selectedFeatures() : null } catch(e) {}
        layer.removeSelection()
        if (!features || features.length === 0) return

        var chosenField = exportLabelSelector.currentText
        var useAuto = (!chosenField || chosenField === "(auto)")
        var nameCandidates = ["name","label","desc","description","title","id","fid"]

        for (var i = 0; i < features.length; i++) {
            var f   = features[i]
            var wkt = ""
            var label = qsTr("Feature %1").arg(i + 1)

            if (useAuto) {
                for (var nc = 0; nc < nameCandidates.length; nc++) {
                    try {
                        var val = f.attribute(nameCandidates[nc])
                        if (val !== null && val !== undefined && String(val).trim() !== "") {
                            label = String(val).trim(); break
                        }
                    } catch(e) {}
                }
            } else {
                try {
                    var cv = f.attribute(chosenField)
                    if (cv !== null && cv !== undefined && String(cv).trim() !== "")
                        label = String(cv).trim()
                } catch(e) {}
            }

            try { wkt = f.geometry.asWkt ? f.geometry.asWkt() : "" } catch(e) {}
            exportFeaturesModel.append({ wkt: wkt, label: label, checked: true })
        }
    }

    function startExport() {
        var layerName = exportLayerSelector.currentText
        if (!layerName) { exportStatusLabel.text = qsTr("Please select a layer."); return }
        var layer = qgisProject.mapLayersByName(layerName)[0]
        if (!layer) { exportStatusLabel.text = qsTr("Layer not found."); return }

        var projDir  = qgisProject.homePath
        var destPath = ""
        var safeName = ""
        var fallbackPath = ""

        if (exportPickerPath !== "") {
            // Specific location chosen via file picker
            destPath = exportPickerPath
            safeName = destPath.replace(/\\/g, "/").split("/").pop()
            if (!safeName) safeName = "export.gpx"
            fallbackPath = projDir + "/" + safeName
        } else {
            // Default: save to <project>/GPX/
            var rawName = exportFilenameField.text.trim()
            if (!rawName) { exportStatusLabel.text = qsTr("Enter a file name or choose a location."); return }
            safeName     = rawName.replace(/[\\/:*?"<>|]/g, "_").replace(/\.gpx$/i, "") + ".gpx"
            destPath     = projDir + "/GPX/" + safeName
            fallbackPath = projDir + "/" + safeName
        }

        exportProgressBar.indeterminate = true
        exportProgressBar.visible = true
        exportButton2.enabled = false
        exportStatusLabel.text = qsTr("Exporting…")
        _lastExportedPath = ""

        var gt    = layer.geometryType ? layer.geometryType() : -1
        var wgs84 = CoordinateReferenceSystemUtils.wgs84Crs()
        var lCrs  = layer.crs

        doExport(layer, gt, lCrs, wgs84, destPath, fallbackPath)
    }

    function doExport(layer, gt, lCrs, wgs84, destPath, fallbackPath) {
        // ── Build WKT filter from checklist ───────────────────────────────────
        // exportFeaturesModel contains { wkt, label, checked } for every feature.
        // If everything is checked (or model is empty) → export all.
        // If any box is unchecked → export only checked WKTs.
        var checkedWkts = {}
        var anyUnchecked = false
        for (var mi = 0; mi < exportFeaturesModel.count; mi++) {
            var item = exportFeaturesModel.get(mi)
            if (item.checked) checkedWkts[item.wkt] = true
            else              anyUnchecked = true
        }
        var useFilter = anyUnchecked && Object.keys(checkedWkts).length > 0

        if (anyUnchecked && Object.keys(checkedWkts).length === 0) {
            exportStatusLabel.text = qsTr("No features ticked — tick at least one to export.")
            exportProgressBar.visible = false
            exportButton2.enabled = true
            return
        }

        // ── Get all features (only reliable path in QField QML) ───────────────
        layer.selectAll()
        var allFeatures = null
        try { allFeatures = layer.selectedFeatures ? layer.selectedFeatures() : null } catch(e) {}
        layer.removeSelection()

        if (!allFeatures || allFeatures.length === 0) {
            exportStatusLabel.text = qsTr("No features found in layer.")
            exportProgressBar.visible = false
            exportButton2.enabled = true
            return
        }

        // ── Filter to ticked features ─────────────────────────────────────────
        var featureList = []
        if (useFilter) {
            for (var fi = 0; fi < allFeatures.length; fi++) {
                var wktF = ""
                try { wktF = allFeatures[fi].geometry.asWkt ? allFeatures[fi].geometry.asWkt() : "" } catch(e) {}
                if (checkedWkts[wktF]) featureList.push(allFeatures[fi])
            }
        } else {
            featureList = allFeatures
        }

        // ── Build GPX ─────────────────────────────────────────────────────────
        var xml      = '<?xml version="1.0" encoding="UTF-8"?>\n'
        xml         += '<gpx version="1.1" creator="QField GPX Appender">\n'
        var exported = 0
        var skipped  = 0

        for (var i = 0; i < featureList.length; i++) {
            var feature = featureList[i]
            if (!feature) { skipped++; continue }

            if (gt === Qgis.GeometryType.Point) {
                try {
                    // Detect Z from WKT type keyword before reading coordinates.
                    // Avoids writing M (measure) values as elevation and correctly
                    // handles Z=0 (sea level) which the old wPt.z !== 0 guard dropped.
                    var ptWkt = ""
                    try { ptWkt = feature.geometry.asWkt ? feature.geometry.asWkt() : "" } catch(e2) {}
                    var ptType = ptWkt.replace(/\s*\([\s\S]*$/, "").trim().toUpperCase()
                    var ptHasZ = ptType.indexOf("Z") !== -1  // Z or ZM → elevation exists

                    var pt  = GeometryUtils.centroid(feature.geometry)
                    var wPt = GeometryUtils.reprojectPoint(pt, lCrs, wgs84)
                    xml += '  <wpt lat="' + wPt.y + '" lon="' + wPt.x + '">\n'
                    if (ptHasZ && !isNaN(wPt.z) && isFinite(wPt.z))
                        xml += '    <ele>' + wPt.z.toFixed(3) + '</ele>\n'
                    xml += buildAttributeTags(feature, layer.fields, "    ")
                    xml += '  </wpt>\n'
                    exported++
                } catch(e) { skipped++ }

            } else if (gt === Qgis.GeometryType.Line) {
                try {
                    xml += '  <trk>\n'
                    xml += buildAttributeTags(feature, layer.fields, "    ")
                    xml += '    <trkseg>\n'
                    var wktStr = ""
                    try { wktStr = feature.geometry.asWkt ? feature.geometry.asWkt() : "" } catch(e2) {}
                    var verts = parseWktVertices(wktStr, lCrs, wgs84)
                    for (var v = 0; v < verts.length; v++) {
                        xml += '      <trkpt lat="' + verts[v].lat + '" lon="' + verts[v].lon + '">'
                        if (verts[v].ele !== null) xml += '<ele>' + verts[v].ele.toFixed(3) + '</ele>'
                        xml += '</trkpt>\n'
                    }
                    xml += '    </trkseg>\n  </trk>\n'
                    exported++
                } catch(e) { skipped++ }
            }
        }
        xml += '</gpx>\n'

        if (exported === 0) {
            exportStatusLabel.text = qsTr("No features exported (skipped %1).").arg(skipped)
            exportProgressBar.visible = false
            exportButton2.enabled = true
            return
        }

        // ── Write the GPX file ────────────────────────────────────────────────
        // Try destPath first (either the picker path or <project>/GPX/<name>.gpx).
        // If that fails, try fallbackPath (<project>/<name>.gpx), which always
        // stays inside the project directory and works on Android.
        var wrote = false
        try { wrote = FileUtils.writeFileContent(destPath, xml) } catch(e) {}

        if (wrote) {
            exportStatusLabel.text = qsTr("Exported %1 feature(s) to:\n%2").arg(exported).arg(destPath)
            mainWindow.displayToast(qsTr("GPX exported: %1 feature(s)").arg(exported))
            _lastExportedPath = destPath
        } else if (fallbackPath && fallbackPath !== destPath) {
            var wroteFallback = false
            try { wroteFallback = FileUtils.writeFileContent(fallbackPath, xml) } catch(e) {}
            if (wroteFallback) {
                exportStatusLabel.text = qsTr("Exported %1 feature(s).\nCould not write to chosen location — saved to:\n%2")
                    .arg(exported).arg(fallbackPath)
                mainWindow.displayToast(qsTr("GPX saved to project folder"))
                _lastExportedPath = fallbackPath
            } else {
                exportStatusLabel.text = qsTr("Could not write GPX file.\nCheck the folder exists and is writable.")
            }
        } else {
            exportStatusLabel.text = qsTr("Could not write GPX file.\nCheck the folder exists and is writable.")
        }

        exportProgressBar.indeterminate = false
        exportProgressBar.value = 1
        exportButton2.enabled = true
    }

    // Escape characters that are illegal inside XML text content.
    // Prevents malformed GPX when feature attributes contain < > & " '
    function escapeXml(str) {
        if (str === null || str === undefined) return ""
        return String(str)
            .replace(/&/g, "&amp;")
            .replace(/</g, "&lt;")
            .replace(/>/g, "&gt;")
            .replace(/"/g, "&quot;")
    }

    // Build GPX child tags for well-known attribute fields
    function buildAttributeTags(feature, fields, indent) {
        var tagMap = [
            { fields: ["name","label"],                          tag: "name"  },
            { fields: ["desc","description","notes"],            tag: "desc"  },
            { fields: ["cmt","comment","comments"],              tag: "cmt"   },
            { fields: ["sym","symbol"],                          tag: "sym"   },
            { fields: ["type","feature_type"],                   tag: "type"  },
        ]
        var out = ""
        for (var i = 0; i < tagMap.length; i++) {
            var val = findFieldValue(feature, fields, tagMap[i].fields)
            if (val !== null && val !== "") out += indent + "<" + tagMap[i].tag + ">" + escapeXml(val) + "</" + tagMap[i].tag + ">\n"
        }
        return out
    }

    function findFieldValue(feature, fields, candidates) {
        for (var i = 0; i < candidates.length; i++) {
            var idx = fields.indexOf(candidates[i])
            if (idx !== -1) {
                var val = feature.attribute(candidates[i])
                if (val !== null && val !== undefined && val !== "") return String(val)
            }
        }
        return null
    }

    // Parse WKT vertices and reproject to WGS84.
    // Handles 2D, Z, M, and ZM geometry types:
    //   LINESTRING (x y)            → no elevation
    //   LINESTRING Z (x y z)        → coords[2] = elevation  ✓
    //   LINESTRING M (x y m)        → coords[2] = measure; GPX has no M field → skipped
    //   LINESTRING ZM (x y z m)     → coords[2] = elevation, coords[3] = measure (ignored)
    // Note: M values cannot be represented in GPX and are always discarded.
    function parseWktVertices(wkt, srcCrs, dstCrs) {
        if (!wkt) return []
        // Determine dimensionality from the WKT type keyword (before the first '(')
        var typeStr   = wkt.replace(/\s*\([\s\S]*$/, "").trim().toUpperCase()
        var hasZ      = typeStr.indexOf("Z") !== -1   // Z or ZM → elevation in coords[2]
        var hasMOnly  = typeStr.indexOf("M") !== -1 && !hasZ  // M but no Z → coords[2] is measure

        // Strip type prefix, keep everything inside the outer parentheses
        var inner = wkt.replace(/^[^(]+\(/, "").replace(/\)$/, "").trim()
        // Strip inner parens (for MULTILINESTRING etc.) - take first ring
        if (inner.charAt(0) === "(") inner = inner.substring(1, inner.indexOf(")"))
        var verts = []
        var parts = inner.split(",")
        for (var i = 0; i < parts.length; i++) {
            var coords = parts[i].trim().split(/\s+/)
            if (coords.length < 2) continue
            var x = parseFloat(coords[0])
            var y = parseFloat(coords[1])
            // Only use coords[2] as elevation when the type declares Z (not M-only)
            var z = (hasZ && !hasMOnly && coords.length >= 3) ? parseFloat(coords[2]) : null
            var srcPt = (z !== null) ? GeometryUtils.point(x, y, z) : GeometryUtils.point(x, y)
            var dstPt = GeometryUtils.reprojectPoint(srcPt, srcCrs, dstCrs)
            verts.push({ lat: dstPt.y, lon: dstPt.x, ele: (z !== null) ? dstPt.z : null })
        }
        return verts
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  GPX PARSING helpers
    // ══════════════════════════════════════════════════════════════════════════

    function parsePointElements(xml, tagName) {
        var results = [], pos = 0
        var openTag = "<" + tagName, closeTag = "</" + tagName + ">"
        while (true) {
            var tagStart = xml.indexOf(openTag, pos)
            if (tagStart === -1) break
            var tagEnd = xml.indexOf(">", tagStart)
            if (tagEnd === -1) break
            var header = xml.substring(tagStart, tagEnd + 1)
            var latM = header.match(/lat="([^"]+)"/)
            var lonM = header.match(/lon="([^"]+)"/)
            if (!latM || !lonM) { pos = tagEnd + 1; continue }
            var closePos = xml.indexOf(closeTag, tagEnd)
            var inner = ""
            if (closePos !== -1) { inner = xml.substring(tagEnd + 1, closePos); pos = closePos + closeTag.length }
            else { pos = tagEnd + 1 }
            var eleStr = extractTagValue(inner, "ele")
            results.push({
                lat:    parseFloat(latM[1]),
                lon:    parseFloat(lonM[1]),
                ele:    eleStr !== null ? parseFloat(eleStr) : null,
                time:   extractTagValue(inner, "time")   || "",
                name:   extractTagValue(inner, "name")   || "",
                desc:   extractTagValue(inner, "desc")   || "",
                cmt:    extractTagValue(inner, "cmt")    || "",
                sat:    extractTagValue(inner, "sat")    || "",
                hdop:   extractTagValue(inner, "hdop")   || "",
                vdop:   extractTagValue(inner, "vdop")   || "",
                pdop:   extractTagValue(inner, "pdop")   || "",
                sym:    extractTagValue(inner, "sym")    || "",
                type:   extractTagValue(inner, "type")   || "",
                fix:    extractTagValue(inner, "fix")    || "",
                speed:  extractTagValue(inner, "speed")  || "",
                course: extractTagValue(inner, "course") || "",
                magvar: extractTagValue(inner, "magvar") || ""
            })
        }
        return results
    }

    function splitByTag(xml, tagName) {
        var results = [], pos = 0
        var open = "<" + tagName + ">", close = "</" + tagName + ">"
        while (true) {
            var s = xml.indexOf(open, pos); if (s === -1) break
            var e = xml.indexOf(close, s);  if (e === -1) break
            results.push(xml.substring(s + open.length, e))
            pos = e + close.length
        }
        return results
    }

    function extractTagValue(xml, tag) {
        var s = xml.indexOf("<" + tag); if (s === -1) return null
        var e = xml.indexOf(">", s);   if (e === -1) return null
        if (xml[e - 1] === "/") return null
        var c = xml.indexOf("</" + tag + ">", e); if (c === -1) return null
        return xml.substring(e + 1, c).trim()
    }

    function trySetField(feat, fields, candidates, value) {
        if (value === undefined || value === null || value === "") return
        for (var i = 0; i < candidates.length; i++) {
            var idx = fields.indexOf(candidates[i])
            if (idx !== -1) { feat.setAttribute(idx, value); return }
        }
    }

    // ── GPX summary for status label ─────────────────────────────────────────
    function summariseGpx(xml) {
        var lines = []
        var wpts = countTag(xml, "wpt")
        if (wpts > 0) lines.push(wpts + " " + (wpts === 1 ? qsTr("waypoint") : qsTr("waypoints")))
        var trks = countTag(xml, "trk"), segs = countTag(xml, "trkseg"), trkpts = countTag(xml, "trkpt")
        if (trks > 0 || segs > 0) {
            var s = trks + " " + (trks === 1 ? qsTr("track") : qsTr("tracks"))
            if (segs > 0)   s += " (" + segs + " " + (segs === 1 ? qsTr("segment") : qsTr("segments")) + ")"
            if (trkpts > 0) s += " · " + trkpts + " " + qsTr("track points")
            lines.push(s)
        }
        var rtes = countTag(xml, "rte"), rtepts = countTag(xml, "rtept")
        if (rtes > 0) {
            var r = rtes + " " + (rtes === 1 ? qsTr("route") : qsTr("routes"))
            if (rtepts > 0) r += " · " + rtepts + " " + qsTr("route points")
            lines.push(r)
        }
        if (lines.length === 0) return qsTr("No tracks, routes or waypoints found.")
        return qsTr("Found: ") + lines.join("  |  ") + "\n" + qsTr("Press Import when ready.")
    }

    function countTag(xml, tagName) {
        var count = 0, search = "<" + tagName, pos = 0
        while (true) {
            var idx = xml.indexOf(search, pos)
            if (idx === -1) break
            var nc = xml.charAt(idx + search.length)
            if (nc === ">" || nc === " " || nc === "\t" || nc === "\n" || nc === "\r" || nc === "/") count++
            pos = idx + 1
        }
        return count
    }
}
