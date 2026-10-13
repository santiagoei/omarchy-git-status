import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar widget: a git glyph that turns urgent when any watched repository has
// uncommitted changes or unpushed commits, plus a popup listing them.
//
// All the work happens in core/git-status.sh, which prints one JSON object.
// This file only schedules it and draws the result.
Panel {
  id: root

  ipcTarget: moduleName
  manageIpc: false  // this file declares its own IpcHandler, with refresh/status

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string scriptPath: localPathFromUrl(Qt.resolvedUrl("core/git-status.sh"))
  readonly property string supervisorPath: localPathFromUrl(Qt.resolvedUrl("core/supervise.sh"))
  readonly property string watchDirs: String(setting("watchDirs", "~/code"))
  readonly property int maxDepth: Number(setting("maxDepth", 4))
  readonly property int refreshIntervalSec: Math.max(30, Number(setting("refreshIntervalSec", 60)))
  readonly property string homeDir: String(Quickshell.env("HOME") || "")

  // Ceilings that mirror the ones in core/git-status.sh. The script rejects an
  // oversized job; this side refuses to hand it one, and refuses to parse an
  // oversized answer instead of buffering whatever arrives.
  readonly property int maxWatchDirs: 24
  readonly property int maxOutputBytes: 1048576
  readonly property int scanTimeoutSec: 25

  property var pending: []
  property var watched: []
  property int scanned: 0
  property bool scanning: false
  property string lastError: ""

  // Name of the agent configured through `omarchy default agent`, read from its
  // defaults file whenever the panel opens. Empty until read (and when nothing
  // is configured), which leaves the folder menu's agent row generically
  // labelled instead of naming an agent the user never picked.
  property string defaultAgent: ""

  readonly property bool unsynced: pending.length > 0
  readonly property color barIconColor: unsynced ? urgent : barForeground
  readonly property string summary: {
    if (lastError !== "") return "scan failed"
    if (scanned === 0) return "nothing scanned"
    if (!unsynced) return scanned + (scanned === 1 ? " repo synced" : " repos synced")
    return pending.length + (pending.length === 1 ? " repo pending" : " repos pending")
  }

  // Cursor state. Mouse hover and keyboard navigation drive the same index so
  // only one row is ever highlighted (the CursorSurface contract).
  property bool cursorActive: false
  property int rowIndex: 0

  // True while a folder's ⋯ popup is open: the key catcher stands down so its
  // arrows and Escape reach the menu instead of the repo list, exactly the way
  // the tailscale panel parks its copy popup (KeyboardPanel blocked flag).
  property bool folderMenuOpen: false

  function localPathFromUrl(url) {
    var value = String(url || "")
    if (value.indexOf("file://") === 0) value = value.slice(7)
    return decodeURIComponent(value)
  }

  // Persist the watched folders into this widget's inline shell.json entry.
  // Same round-trip the first-party panels use, so the bar's widget settings
  // UI and this panel stay one source of truth instead of two.
  function persistDirs(dirs) {
    if (!bar || !bar.shell || typeof bar.shell.updateEntryInline !== "function") return
    var entry = { id: moduleName }
    for (var key in settings) if (key !== "id") entry[key] = settings[key]
    entry.watchDirs = dirs.join(", ")
    bar.shell.updateEntryInline(moduleName, entry)
  }

  // The script shows every watched folder with $HOME collapsed back to `~`
  // (git-status.sh's display_dir), so the row a removal click hands removeDir()
  // rarely equals the string stored in shell.json. Both sides are mapped
  // through canonDir() before being compared, and new entries are stored in
  // the same ~ form the panel displays, so one shape round-trips.
  function canonDir(dir) {
    var value = String(dir || "").trim().replace(/\/+$/, "")
    if (value === "" || homeDir === "") return value
    if (value === "~") return homeDir
    if (value.indexOf("~/") === 0) return homeDir + value.slice(1)
    return value
  }

  function displayDir(dir) {
    var value = canonDir(dir)
    if (value === "" || homeDir === "") return value
    if (value === homeDir) return "~"
    if (value.indexOf(homeDir + "/") === 0) return "~" + value.slice(homeDir.length)
    return value
  }

  // A pattern with * or ? is a bulk add: every matching folder lands in the
  // stored list as if it had been typed on its own row, so each keeps its own
  // folder menu and its own missing/empty state. Resolution is one bash tick --
  // compgen -G expands the pattern without word splitting, and only real
  // directories survive. Zero matches persist nothing, matching the plan that
  // a typo shows up nowhere rather than as a dead row.
  function addDir(raw) {
    var dir = String(raw || "").trim()
    if (dir === "") return
    if (dir.indexOf("*") !== -1 || dir.indexOf("?") !== -1) {
      glob.command = ["/usr/bin/bash", "-c",
                      "shopt -s nullglob; mapfile -t m < <(compgen -G \"$1\" | /usr/bin/head -n 64); for d in \"${m[@]}\"; do [ -d \"$d\" ] && printf '%s\\n' \"$d\"; done",
                      "qsglob", canonDir(dir)]
      glob.running = true
      return
    }
    addDirs([dir])
  }

  function globDirs(text) {
    var lines = String(text || "").split("\n")
    var out = []
    for (var i = 0; i < lines.length; i++) {
      var dir = lines[i]
      if (dir.trim() !== "") out.push(dir)
    }
    return out
  }

  // Bulk entry point behind both add paths: dedupe by canonical shape, store
  // in the displayed ~ form, refuse the whole batch if it would cross the
  // folder cap the scanner enforces.
  function addDirs(list) {
    var dirs = dirArgs()
    var added = 0
    for (var i = 0; i < list.length; i++) {
      var dir = displayDir(list[i])
      if (dir === "") continue
      var dup = false
      for (var j = 0; j < dirs.length; j++) {
        if (canonDir(dirs[j]) === canonDir(dir)) { dup = true; break }
      }
      if (dup) continue
      if (dirs.length + 1 > maxWatchDirs) {
        lastError = "too many watched folders (limit " + maxWatchDirs + ")"
        return
      }
      dirs.push(dir)
      added = added + 1
    }
    if (added === 0) return
    persistDirs(dirs)
  }

  function removeDir(dir) {
    var key = canonDir(dir)
    var dirs = dirArgs()
    for (var i = 0; i < dirs.length; i++) {
      if (canonDir(dirs[i]) !== key) continue
      dirs.splice(i, 1)
      persistDirs(dirs)
      return
    }
  }

  function dirArgs() {
    var parts = watchDirs.split(",")
    var out = []
    for (var i = 0; i < parts.length; i++) {
      var dir = parts[i].trim()
      if (dir !== "") out.push(dir)
    }
    return out
  }

  function refresh() {
    if (scan.running) return
    var dirs = dirArgs()
    if (dirs.length === 0) {
      pending = []
      watched = []
      scanned = 0
      scanning = false
      return
    }
    if (dirs.length > maxWatchDirs) {
      lastError = "too many watched folders (limit " + maxWatchDirs + ")"
      return
    }
    scanning = true
    // Absolute paths, not PATH lookups: this refreshes on a timer for the whole
    // session, so an earlier writable PATH entry would otherwise get to run its
    // own `bash` here every minute.
    //
    // timeout(1) makes itself the leader of a new process group and the script
    // with its find/git children inherits it, so its TERM reaches the whole
    // tree. supervise.sh sits between the two and turns that TERM into a KILL
    // of the group five seconds later, from inside it -- see abortScan().
    scan.command = ["/usr/bin/timeout", scanTimeoutSec + "s",
                    "/usr/bin/bash", supervisorPath, "5",
                    "/usr/bin/bash", scriptPath, String(maxDepth)].concat(dirs)
    scan.running = true
    watchdog.restart()
  }

  // lazygit's -p opens a specific repository, so each row gets its own window
  // rather than stealing focus from a lazygit already open on another repo.
  // execArgv over bar.run: the path reaches bash as a positional parameter, so
  // a folder named with a space or a $(...) stays a literal path.
  function openRepo(repo) {
    if (!repo) return
    Util.execArgv(["omarchy-launch-tui", "lazygit", "-p", String(repo.path)])
    close()
  }

  // The folder menu's openers, same execArgv-over-bar.run reasoning as
  // openRepo: the path is one argv entry, never text a shell re-reads. Each
  // uses the default Omarchy configures rather than a hardcoded app:
  // xdg-terminal-exec for the terminal, omarchy-launch-editor for the editor,
  // omarchy-agent for the default agent, xdg-open for the file manager. The
  // agent gets --dir and --inline rather than a path argument, which it would
  // refuse: --dir puts its terminal in the folder, and --inline runs the agent
  // in that terminal instead of spawning a second one and leaving the first
  // to flash empty.
  function openFolder(path, argv) {
    if (path === "") return
    Util.execArgv(argv)
    close()
  }

  // Abort the scan so that nothing it spawned outlives it. Stopping the Process
  // sends TERM to timeout(1) -- by pid, to a child Quickshell has not reaped
  // yet, so it cannot be anyone else -- and timeout forwards it to the group.
  //
  // The KILL that follows is deliberately not sent from here. By the time it
  // is due the group may have emptied, and a group id with no members is free
  // for the kernel to hand out again, so a KILL by number could land on an
  // unrelated process group of the user's. supervise.sh sends it instead, from
  // inside the group, which keeps the id pinned for as long as that matters.
  function abortScan(reason) {
    if (!scan.running) return
    lastError = reason
    scan.running = false
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    if (dy === 0 || pending.length === 0) return
    rowIndex = Math.max(0, Math.min(pending.length - 1, rowIndex + dy))
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    rowIndex = 0
    if (panelFlick) panelFlick.contentY = 0
    if (!agentFile.running) agentFile.running = true
    refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  onWatchDirsChanged: refresh()
  Component.onCompleted: refresh()

  // Deliberately read fresh on every open: `omarchy default agent` can change
  // between opens without the panel noticing, and a stale name on the menu is
  // a menu that lies about what it will launch. A missing file is the unset
  // case, not an error to surface: cat simply answers with nothing.
  // Process rather than the newer FileReader/FileView: this reads on a bar
  // panel of every Quickshell the host might run.
  Process {
    id: agentFile
    command: ["/usr/bin/timeout", "5s", "/usr/bin/cat",
              root.homeDir + "/.config/omarchy/defaults/agent"]
    clearEnvironment: true
    stdout: StdioCollector {
      onStreamFinished: root.defaultAgent = text.trim()
    }
  }

  Process {
    id: scan
    // The scan wants nothing from the session environment except the home
    // directory the watch roots are written against. The rest of what it used
    // to inherit was just so many ways to redirect the helpers it runs.
    clearEnvironment: true
    environment: ({ PATH: "/usr/bin:/bin", HOME: String(Quickshell.env("HOME") || "") })
    stdout: StdioCollector {
      waitForEnd: true
      // waitForEnd holds the whole answer in memory and the collector has no cap
      // of its own, so watch it grow and stop the producer on the way past the
      // limit rather than after having swallowed whatever it sent.
      onDataChanged: if (text.length > root.maxOutputBytes) root.abortScan("scan output too large")
      onStreamFinished: {
        watchdog.stop()
        // waitForEnd buffers the whole answer before this runs, so the size of
        // the answer is the producer's choice, not ours. Refuse it rather than
        // hand a megabyte-plus string to JSON.parse.
        if (text.length > root.maxOutputBytes) {
          root.lastError = "scan output too large"
          return
        }
        try {
          var result = JSON.parse(text)
          // The script reports a crossed ceiling instead of a partial scan:
          // keep the last known list on screen and say why it is stale.
          if (result.state === "error") {
            root.lastError = String(result.error || "scan rejected")
            return
          }
          root.pending = result.pending || []
          root.watched = result.watched || []
          root.scanned = Number(result.scanned || 0)
          root.lastError = ""
        } catch (error) {
          root.lastError = "could not read the scan output"
        }
        if (root.rowIndex >= root.pending.length) root.rowIndex = Math.max(0, root.pending.length - 1)
      }
    }
    onExited: function(exitCode) {
      root.scanning = false
      watchdog.stop()
      if (exitCode !== 0 && root.lastError === "") root.lastError = "scan exited with code " + exitCode
    }
  }

  // One-shot glob resolver behind addDir(): same pinned environment as the
  // scan, so a pattern cannot smuggle a different bash or head into play.
  Process {
    id: glob
    clearEnvironment: true
    environment: ({ PATH: "/usr/bin:/bin", HOME: String(Quickshell.env("HOME") || "") })
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.addDirs(root.globDirs(text))
    }
  }

  // Belt and braces behind timeout(1)'s own deadline, for a job somehow still
  // alive past it.
  Timer {
    id: watchdog
    interval: (root.scanTimeoutSec + 10) * 1000
    onTriggered: root.abortScan("scan timed out")
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  IpcHandler {
    // Guarded the way the Ui/Panel base guards its own: moduleName is injected
    // by the host, so an unguarded handler can register an empty target.
    enabled: root.ipcTarget !== ""
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(); return "ok" }
    function status(): string { return root.summary }
    function watch(dir: string): string { root.addDir(dir); return root.watchDirs }
    function unwatch(dir: string): string { root.removeDir(dir); return root.watchDirs }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    foreground: root.barIconColor
    tooltipText: root.summary
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.refresh()
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
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(520))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // Keys.BeforeItem means this catcher sees keys even when the add field
      // has focus, so every letter typed into it would drive the cursor
      // instead. Stand down while the field is being edited.
      blocked: addField.activeFocus || root.folderMenuOpen
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive && root.pending.length > 0) root.openRepo(root.pending[root.rowIndex])
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) { if (t === "r" || t === "R") root.refresh() }

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
            width: parent.width
            title: "Git"
            meta: root.scanning ? "Scanning" : root.summary
            detail: root.unsynced ? String(root.pending.length) : ""
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: ""
                color: root.unsynced ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
            trailingControl: Component {
              PanelActionButton {
                iconText: ""
                foreground: root.foreground
                fontFamily: root.fontFamily
                enabled: !root.scanning
                onClicked: root.refresh()
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.lastError !== ""
            width: parent.width
            text: root.lastError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          PanelSeparator { foreground: root.foreground }

          Column {
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "PENDING TO SYNC"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              textFormat: Text.PlainText
              visible: !root.unsynced && root.lastError === ""
              width: parent.width
              text: root.watched.length === 0
                ? "No folders watched yet. Add one below."
                : "Everything is committed and pushed."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
            }

            Column {
              id: repoColumn
              visible: root.unsynced
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: root.pending
                RepoRow {
                  required property var modelData
                  required property int index
                  width: repoColumn.width
                  repo: modelData
                  row: index
                }
              }
            }
          }

          PanelSeparator { foreground: root.foreground }

          Column {
            id: folderSection
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: "WATCHED FOLDERS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Column {
              width: parent.width
              spacing: Style.space(2)

              Repeater {
                model: root.watched
                FolderRow {
                  required property var modelData
                  width: folderSection.width
                  folder: modelData
                }
              }
            }

            // Typing a path is the whole editor: no config file, no picker
            // process. The folder's own row reports back whether it exists.
            TextField {
              id: addField
              width: parent.width
              foreground: root.foreground
              placeholderText: "Add a folder, e.g. ~/work"
              onAccepted: {
                root.addDir(text)
                text = ""
              }
              // Escape leaves the field rather than closing the panel, so a
              // half-typed path can be abandoned without losing the popup.
              Keys.onEscapePressed: {
                text = ""
                keyCatcher.forceActiveFocus()
              }

              // The key catcher holds focus for the whole panel, and a press on
              // the field alone does not take it back, so the field stays deaf
              // to typing. Claim focus on press and let the event fall through
              // so the caret still lands where the click did.
              MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.LeftButton
                onPressed: function(mouse) {
                  addField.forceActiveFocus()
                  mouse.accepted = false
                }
              }
            }
          }
        }
      }
    }
  }

  component FolderRow: Item {
    id: folderRow
    property var folder: null
    readonly property string folderPath: folder ? String(folder.path) : ""
    readonly property string folderState: folder ? String(folder.state) : "ok"
    // The rows speak the displayed ~ form; launchers want the real path, so
    // every action runs against the canonicalised one.
    readonly property string absPath: root.canonDir(folderPath)
    readonly property string meta: {
      if (folderState === "missing") return "does not exist"
      if (folderState === "empty") return "no git repos"
      var repos = folder ? Number(folder.repos) : 0
      var pending = folder ? Number(folder.pending) : 0
      var count = repos + (repos === 1 ? " repo" : " repos")
      return pending > 0 ? count + " · " + pending + " pending" : count + " · all synced"
    }

    implicitHeight: Math.max(folderLabels.implicitHeight, folderMenuButton.implicitHeight)
      + Style.space(4)

    Column {
      id: folderLabels
      anchors.left: parent.left
      anchors.right: folderMenuButton.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(1)

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: folderRow.folderPath
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: folderRow.meta
        color: folderRow.folderState === "missing" ? root.urgent : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    PanelActionButton {
      id: folderMenuButton
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      iconText: "\uf141"
      tooltipText: "Folder actions"
      foreground: root.foreground
      hoverColor: root.urgent
      fontFamily: root.fontFamily
      onClicked: folderMenu.open()
    }

    // The popup's place in the shared cursor. pickMenu is the one place that
    // knows what each index launches; the rows only report their index.
    property int menuIndex: 0
    readonly property int menuCount: 6

    function pickMenu(i) {
      if (i === 0)
        root.openFolder(absPath, ["setsid", "uwsm-app", "--",
                                  "xdg-terminal-exec", "--dir=" + absPath])
      else if (i === 1)
        root.openFolder(absPath, ["omarchy-launch-editor", absPath])
      else if (i === 2)
        root.openFolder(absPath, ["setsid", "uwsm-app", "--", "xdg-terminal-exec",
                                  "--dir=" + absPath, "-e", "omarchy-agent", "--inline"])
      else if (i === 3)
        root.openFolder(absPath, ["setsid", "uwsm-app", "--", "xdg-open", absPath])
      else if (i === 4) {
        // Copying is a grab, not a departure: the panel stays open on purpose,
        // and wl-copy takes the path as its own argv entry, same as everywhere
        // else here, so a folder named with a space stays a literal path.
        if (absPath === "") return
        Util.execArgv(["wl-copy", absPath])
        folderMenu.close()
      } else if (i === 5) {
        root.removeDir(folderPath)
        folderMenu.close()
      }
    }

    // The folder menu, drawn the way the shell draws its own in-panel popups
    // (see the tailscale copy list): a Popup whose background is a
    // BorderSurface and whose rows are CursorSurfaces, so colours, radius,
    // hover fill and fonts all come from the active theme instead of the
    // QtQuick.Controls default menu style, which ignores it entirely.
    //
    // Openers first, the destructive removal last behind a separator: stop
    // watching should not sit one careless click under the old × position.
    Popup {
      id: folderMenu
      x: folderMenuButton.x + folderMenuButton.width - width
      y: folderMenuButton.y + folderMenuButton.height + Style.space(4)
      width: Style.space(300)
      height: contentItem.implicitHeight + topPadding + bottomPadding
      padding: Style.space(4)
      modal: false
      focus: true
      closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

      onOpenedChanged: {
        root.folderMenuOpen = opened
        if (opened) {
          folderRow.menuIndex = 0
          Qt.callLater(function() { folderMenuContent.forceActiveFocus() })
        } else if (root.opened) {
          Qt.callLater(function() { keyCatcher.forceActiveFocus() })
        }
      }

      background: BorderSurface {
        color: Color.background
        borderSpec: Border.flat(root.dim, 1)
        radius: Style.cornerRadius
      }

      contentItem: Column {
        id: folderMenuContent
        width: parent.width
        spacing: 0
        focus: true
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Down || event.text === "j") {
            folderRow.menuIndex = (folderRow.menuIndex + 1) % folderRow.menuCount
            event.accepted = true
          } else if (event.key === Qt.Key_Up || event.text === "k") {
            folderRow.menuIndex = (folderRow.menuIndex + folderRow.menuCount - 1) % folderRow.menuCount
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                     || event.key === Qt.Key_Space) {
            folderRow.pickMenu(folderRow.menuIndex)
            event.accepted = true
          } else if (event.text >= "1" && event.text <= "6") {
            folderRow.pickMenu(Number(event.text) - 1)
            event.accepted = true
          }
        }

        // The header is the whole path, which the row itself has to elide:
        // a menu should say what it acts on before it acts on it. Middle
        // elision keeps both ends of the path, home prefix and folder name.
        Text {
          textFormat: Text.PlainText
          width: parent.width
          leftPadding: Style.space(12)
          rightPadding: Style.space(12)
          topPadding: Style.space(6)
          bottomPadding: Style.space(6)
          text: folderRow.folderPath
          color: folderRow.folderState === "missing" ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          elide: Text.ElideMiddle
        }

        PanelSeparator { foreground: root.foreground }

        FolderMenuRow {
          width: parent.width
          label: "Open in terminal"
          glyph: "\uf120"
          hint: "1"
          selected: folderMenu.opened && folderRow.menuIndex === 0
          onHovered: folderRow.menuIndex = 0
          onChosen: folderRow.pickMenu(0)
        }
        FolderMenuRow {
          width: parent.width
          label: "Open in code"
          glyph: "\uf121"
          hint: "2"
          selected: folderMenu.opened && folderRow.menuIndex === 1
          onHovered: folderRow.menuIndex = 1
          onChosen: folderRow.pickMenu(1)
        }
        FolderMenuRow {
          width: parent.width
          label: root.defaultAgent === "" ? "Open in agent" : "Open in " + root.defaultAgent
          glyph: "\uf5fd"
          hint: "3"
          selected: folderMenu.opened && folderRow.menuIndex === 2
          onHovered: folderRow.menuIndex = 2
          onChosen: folderRow.pickMenu(2)
        }
        FolderMenuRow {
          width: parent.width
          label: "Open in file explorer"
          glyph: "\uf07b"
          hint: "4"
          selected: folderMenu.opened && folderRow.menuIndex === 3
          onHovered: folderRow.menuIndex = 3
          onChosen: folderRow.pickMenu(3)
        }
        FolderMenuRow {
          width: parent.width
          label: "Copy path"
          glyph: "\uf0c5"
          hint: "5"
          selected: folderMenu.opened && folderRow.menuIndex === 4
          onHovered: folderRow.menuIndex = 4
          onChosen: folderRow.pickMenu(4)
        }

        PanelSeparator { foreground: root.foreground }

        FolderMenuRow {
          width: parent.width
          label: "Stop watching"
          glyph: "\uf00d"
          hint: "6"
          urgent: true
          selected: folderMenu.opened && folderRow.menuIndex === 5
          onHovered: folderRow.menuIndex = 5
          onChosen: folderRow.pickMenu(5)
        }
      }
    }
  }

  // One menu row of the folder popup. The cursor highlight is the same
  // CursorSurface contract the rest of the panel uses; hover and clicks leave
  // as signals and FolderRow alone knows what the index means -- the shape of
  // tailscale's CopyChoice. The glyph says what the action does, the hint
  // says which digit does it while the menu is open.
  component FolderMenuRow: CursorSurface {
    id: menuRow
    property string label: ""
    property string glyph: ""
    property string hint: ""
    property bool urgent: false
    property bool selected: false

    signal hovered()
    signal chosen()

    hasCursor: menuRow.selected
    foreground: root.foreground
    implicitHeight: Style.space(40)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: menuRow.hovered()
      onClicked: menuRow.chosen()
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.space(12)
      anchors.rightMargin: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(10)

      Text {
        textFormat: Text.PlainText
        text: menuRow.glyph
        color: menuRow.urgent ? root.urgent : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }

      Text {
        textFormat: Text.PlainText
        Layout.fillWidth: true
        text: menuRow.label
        color: menuRow.urgent ? root.urgent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }

      Text {
        textFormat: Text.PlainText
        text: menuRow.hint
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        Layout.alignment: Qt.AlignVCenter
      }
    }
  }
  component RepoRow: CursorSurface {
    id: repoRow
    property var repo: null
    property int row: 0

    hasCursor: root.cursorActive && root.rowIndex === row
    foreground: root.foreground
    implicitHeight: repoContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: {
        root.cursorActive = true
        root.rowIndex = repoRow.row
      }
      onClicked: root.openRepo(repoRow.repo)
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        id: repoContent
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: repoRow.repo ? String(repoRow.repo.name) : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: repoRow.repo ? String(repoRow.repo.dir) + " · " + String(repoRow.repo.issues) : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
  }
}
