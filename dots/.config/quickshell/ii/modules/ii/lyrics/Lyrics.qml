pragma ComponentBehavior: Bound
import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import Quickshell.Wayland

Scope {
    id: root

    property var text: LyricsText {}
    property var cache: LyricsCache {}
    property var sources: LyricsSources {
        active: GlobalStates.lyricsOpen
        matchThreshold: root.matchThreshold
    }
    readonly property string browserIntegrationBusPrefix: "org.mpris.MediaPlayer2.plasma-browser-integration"

    readonly property MprisPlayer activePlayer: {
        const playing = Mpris.players.values.filter(p => p.isPlaying);
        const native = p => !String(p.dbusName ?? "").startsWith(root.browserIntegrationBusPrefix);
        const real = p => String(p.trackTitle ?? "").trim() !== "";
        const withArtist = p => String(p.trackArtist ?? "").trim() !== "";
        const sameTrack = (a, b) => {
            if (a === b) return false;
            const la = a.length, lb = b.length;
            if (!(la > 0 && lb > 0) || Math.abs(la - lb) > 2) return false;
            const pa = a.position, pb = b.position;
            if (pa > 0 && pb > 0 && Math.abs(pa - pb) > 5) return false;
            return true;
        };
        for (const p of playing)
            if (native(p) && real(p) && p.length > p.position && withArtist(p)) return p;
        for (const p of playing)
            if (native(p) && real(p) && p.length > p.position && !withArtist(p)) {
                const twin = playing.find(q => sameTrack(q, p) && withArtist(q));
                if (twin) return twin;
            }
        for (const p of playing)
            if (real(p) && p.length > p.position && withArtist(p)) return p;
        for (const p of playing)
            if (native(p) && real(p) && p.length > p.position) return p;
        for (const p of playing)
            if (real(p) && p.length > p.position) return p;
        for (const p of playing)
            if (p.length > p.position) return p;
        if (playing.length > 0) return playing[0];
        return MprisController.activePlayer;
    }
    property var lines: []
    property int shownIndex: -1
    property real lyricSpacing: 10
    property int matchThreshold: 80
    property string contextTitle: ""
    property string contextArtist: ""
    property string contextAlbum: ""
    property real contextLength: 0
    property real contextPosition: 0
    property string shownTitle: ""
    property string shownArtist: ""
    property var fetchContext: null
    property string fetchedKey: ""
    property string fetchingKey: ""
    property int fetchGen: 0
    property int fetchAttempts: 0
    property bool noLyrics: false
    property string noLyricsText: "No lyrics found"

    property bool lyricsOpen: GlobalStates.lyricsOpen

    property bool userDragged: false
    property bool dragging: false
    property point grabOffset: Qt.point(0, 0)
    property real draggedCenterLeft: 0
    property real draggedTop: 0

    property real defaultTopMargin: Appearance.sizes.barHeight

    Timer {
        id: positionTimer
        running: GlobalStates.lyricsOpen
        interval: 100
        repeat: true
        onTriggered: root.advance()
    }

    Timer {
        id: refetchTimer
        running: GlobalStates.lyricsOpen
        interval: 3000
        repeat: true
        onTriggered: root.fetchLyrics()
    }

    Connections {
        target: MprisController

        function onTrackChanged() {
            if (GlobalStates.lyricsOpen)
                root.fetchLyrics();
        }
    }

    Connections {
        target: root.activePlayer

        function onPositionChanged() {
            root.advance();
        }

        function onTrackTitleChanged() {
            if (GlobalStates.lyricsOpen)
                root.fetchLyrics();
        }
    }

    Connections {
        target: root.sources

        function onResolved(lines) { root.finishFetch(lines); }
        function onEmpty() { root.finishFetch([]); }
    }

    Connections {
        target: root.cache
        function onHit(key, lines) {
            if (!root.fetchContext || key !== root.cache.key(root.fetchContext)) return;
            root.sources.generation++;
            root.sources.cancel();
            if (!GlobalStates.lyricsOpen) GlobalStates.lyricsOpen = true;
            root.lines = lines;
            root.shownIndex = -1;
            root.fetchingKey = "";
            root.fetchedKey = key;
            root.shownTitle = root.contextTitle;
            root.shownArtist = root.contextArtist;
            fetchWatchdog.stop();
            root.normalizeRest();
            root.applyCurrent();
        }
        function onMiss(key) {
            if (!root.fetchContext || key !== root.cache.key(root.fetchContext)) return;
            root.startSourceFetch();
        }
    }

    function applyChosenLyrics(lines): void {
            const context = root.currentTrackContext();
            if (!context) return;
            root.cache.save(context, lines);
            root.lines = lines;
            root.shownIndex = -1;
            root.fetchingKey = "";
            root.fetchedKey = root.cache.key(context);
            root.shownTitle = context.title;
            root.shownArtist = context.artist;
            root.noLyrics = false;
            root.normalizeRest();
            GlobalStates.lyricsPickerOpen = false;
            if (!GlobalStates.lyricsOpen) GlobalStates.lyricsOpen = true;
            root.applyCurrent();
    }

    onLyricsOpenChanged: {
        if (GlobalStates.lyricsOpen) {
            root.userDragged = false;
            root.fetchLyrics();
            root.applyCurrent();
        } else {
            root.shownIndex = -1;
            root.preRolled = false;
            root.lines = [];
            root.noLyrics = false;
            root.fetchingKey = "";
            root.fetchedKey = "";
            root.cancelAllFetches();
            root.normalizeRest();
        }
    }

    function currentTrackContext(): var {
        const player = root.activePlayer;
        if (!player) return null;
        const title = String(player.trackTitle ?? "").trim();
        const artist = String(player.trackArtist ?? "").trim();
        const album = String(player.trackAlbum ?? "").trim();
        const length = Number(player.length ?? 0);
        return {
            title: title,
            artist: artist,
            album: album,
            length: length,
            position: Number(player.position ?? 0),
            url: String(player.trackUrl ?? ""),
            key: [title.toLowerCase(), artist.toLowerCase(),
                length > 0 ? Math.round(length) : 0].join("\u001f")
        };
    }

    function fetchLyrics(): void {
        const context = root.currentTrackContext();
        if (!context) return;
        const title = context.title;
        if (!title) {
            root.cancelAllFetches();
            root.contextTitle = "";
            root.contextArtist = "";
            root.contextAlbum = "";
            root.contextLength = 0;
            root.contextPosition = 0;
            root.fetchingKey = "";
            root.fetchedKey = "";
            root.fetchAttempts = 0;
            root.lines = [];
            root.shownIndex = -1;
            root.preRolled = false;
            root.noLyrics = false;
            fetchRetryTimer.stop();
            fetchWatchdog.stop();
            root.normalizeRest();
            return;
        }
        if (context.key === root.fetchedKey || context.key === root.fetchingKey) return;
        // Keep the current display when the same song re-emits (e.g. length updates).
        const sameSong = root.shownTitle === context.title
            && root.shownArtist === context.artist
            && root.shownTitle !== "";
        root.fetchGen++;
        root.cancelAllFetches();
        root.contextTitle = context.title;
        root.contextArtist = context.artist;
        root.contextAlbum = context.album;
        root.contextLength = context.length;
        root.contextPosition = context.position;
        root.fetchingKey = context.key;
        root.fetchContext = context;
        root.fetchAttempts = 0;
        root.sources.title = context.title;
        root.sources.artist = context.artist;
        root.sources.album = context.album;
        root.sources.length = context.length;
        root.sources.position = context.position;
        root.sources.generation = root.fetchGen;
        fetchRetryTimer.stop();
        if (!sameSong) {
            root.noLyrics = false;
            root.lines = [];
            root.shownIndex = -1;
            root.normalizeRest();
        }
        root.cache.lookup(context);
        fetchWatchdog.restart();
    }

    function startSourceFetch(): void {
        if (!GlobalStates.lyricsOpen) return;
        if (root.fetchingKey === "") return;
        fetchWatchdog.restart();
        root.sources.generation = root.fetchGen;
        root.sources.start();
    }

    function cancelAllFetches(): void {
        root.sources.cancel();
    }

    Timer {
        id: fetchRetryTimer
        interval: 1500
        repeat: false
        onTriggered: {
            if (!GlobalStates.lyricsOpen) return;
            if (root.fetchAttempts >= 5) { root.giveUpNoLyrics(); root.normalizeRest(); return; }
            fetchWatchdog.restart();
            root.sources.generation = root.fetchGen;
            root.sources.start();
        }
    }

    Timer {
        id: fetchWatchdog
        interval: 8000
        repeat: false
        onTriggered: {
            if (!GlobalStates.lyricsOpen) return;
            if (root.fetchingKey === "") return;
            root.fetchGen++;
            root.cancelAllFetches();
            root.fetchAttempts = 0;
            root.sources.generation = root.fetchGen;
            root.sources.start();
        }
    }

    function finishFetch(parsed): void {
        root.lines = parsed;
        root.shownIndex = -1;
        root.preRolled = false;
        if (parsed.length > 0) {
            root.fetchedKey = root.fetchingKey;
            root.shownTitle = root.contextTitle;
            root.shownArtist = root.contextArtist;
            if (root.fetchContext)
                root.cache.save(root.fetchContext, parsed);
            root.fetchingKey = "";
            root.noLyrics = false;
            root.fetchAttempts = 0;
            fetchRetryTimer.stop();
            fetchWatchdog.stop();
        } else if (root.fetchAttempts < 5) {
            root.fetchAttempts++;
            fetchRetryTimer.restart();
        } else {
            root.giveUpNoLyrics();
        }
        root.normalizeRest();
        root.applyCurrent();
    }

    function giveUpNoLyrics(): void {
        root.noLyrics = true;
        root.fetchedKey = "";
        root.fetchingKey = "";
        fetchWatchdog.stop();
    }

    Timer {
        id: bgSampleTimer
        running: GlobalStates.lyricsOpen
        interval: 700
        repeat: true
        onTriggered: root.sampleBackground()
    }
    Process {
        id: bgSampleProc
        stdout: StdioCollector {
            id: bgSampleCol
            waitForEnd: true
            onStreamFinished: root.onBgSampleDone(bgSampleCol.text)
        }
    }

    function sampleBackground(): void {
        if (!lyricsWindow || bgSampleProc.running) return;
        const screen = lyricsWindow.screen;
        if (!screen) return;
        const textWidth = Math.max(currentLine ? currentLine.width : 0, nextLine ? nextLine.width : 0);
        const sampleW = textWidth > 0 ? textWidth : lyricsWindow.width;
        const cx = lyricsWindow.margins.left + lyricsWindow.width / 2;
        const left = Math.max(screen.x, Math.round(cx - sampleW / 2));
        const top = Math.max(screen.y, Math.round(screen.y + lyricsWindow.margins.top));
        const right = Math.min(screen.x + screen.width, left + Math.round(sampleW));
        const bottom = Math.min(screen.y + screen.height, top + Math.round(lyricsWindow.implicitHeight));
        const w = right - left;
        const h = bottom - top;
        if (w <= 0 || h <= 0) return;
        const geom = Math.round(left) + "," + Math.round(top) + " " + Math.round(w) + "x" + Math.round(h);
        bgSampleProc.command = ["sh", "-c",
            "grim -g \"$1\" - | python3 -W ignore -c \"import sys,PIL.Image as I,io; im=I.open(io.BytesIO(sys.stdin.buffer.read())).convert('RGB'); d=list(im.getdata()); n=len(d); t=d[:n//2]; b=d[n//2:]; print(*(sorted(p[i] for p in t)[len(t)//2] for i in range(3)), *(sorted(p[i] for p in b)[len(b)//2] for i in range(3)))\"",
            "sh", geom];
        bgSampleProc.running = false;
        bgSampleProc.running = true;
    }

    function onBgSampleDone(out): void {
        bgSampleProc.running = false;
        const parts = String(out).trim().split(/[\s,]+/);
        const v = parts.slice(0, 6).map(parseFloat);
        if (v.length < 6 || v.some(x => isNaN(x))) return;
        root.updateColors(
            Qt.rgba(v[0] / 255, v[1] / 255, v[2] / 255, 1),
            Qt.rgba(v[3] / 255, v[4] / 255, v[5] / 255, 1));
    }

    property bool bgIsDark: true
    property bool hasBgSample: false
    property var lastAppliedBg: null
    property var pendingBg: null
    property bool nextIsDark: true
    property bool hasNextSample: false

    function colorClose(a, b): bool {
        return (Math.abs(a.r - b.r) + Math.abs(a.g - b.g) + Math.abs(a.b - b.b)) / 3 < 0.15;
    }

    function updateColors(bg, bgNext): void {
        if (root.hasBgSample) {
            if (root.bgIsDark && bg.hslLightness > 0.62) root.bgIsDark = false;
            else if (!root.bgIsDark && bg.hslLightness < 0.38) root.bgIsDark = true;
        } else {
            root.bgIsDark = bg.hslLightness < 0.5;
            root.hasBgSample = true;
        }
        const dark = root.bgIsDark;

        const applied = root.lastAppliedBg;
        if (applied === null) {
            root.lastAppliedBg = bg;
        } else if (root.colorClose(bg, applied)) {
            root.pendingBg = null;
        } else if (root.pendingBg !== null && root.colorClose(root.pendingBg, bg)) {
            root.lastAppliedBg = bg;
            root.pendingBg = null;
        } else {
            root.pendingBg = bg;
        }

        const base = root.lastAppliedBg;
        const hue = base.hslSaturation < 0.15
            ? Qt.color(Appearance.colors.colPrimary).hslHue
            : (base.hslHue + 0.5) % 1.0;
        root.currentLineColorBottom = Qt.hsla(hue, 0.9, dark ? 0.58 : 0.42, 1);

        if (root.hasNextSample) {
            if (root.nextIsDark && bgNext.hslLightness > 0.62) root.nextIsDark = false;
            else if (!root.nextIsDark && bgNext.hslLightness < 0.38) root.nextIsDark = true;
        } else {
            root.nextIsDark = bgNext.hslLightness < 0.5;
            root.hasNextSample = true;
        }
        root.nextLineColor = root.nextIsDark ? Qt.rgba(1, 1, 1, 1) : Qt.rgba(0, 0, 0, 1);
        if (!scrollAnim.running) nextLine.color = root.nextLineColor;
    }

    // Keep surface geometry stable to prevent compositor jitter.
    property real lyricSlotWidth: (lyricsWindow && lyricsWindow.screen) ? lyricsWindow.screen.width : 1280
    property real lyricLineHeight: root.currentLineSize * 1.35
    property real rowHeight: root.lyricLineHeight + root.lyricSpacing
    property real centeredLeft: Math.max(0, Math.floor((((lyricsWindow && lyricsWindow.screen) ? lyricsWindow.screen.width : 0) - root.lyricSlotWidth) / 2))
    property real currentLineSize: 24
    property real nextLineSize: 20
    property real nextLineScale: root.nextLineSize / root.currentLineSize
    property color currentLineColorBottom: Qt.hsla(Qt.color(Appearance.colors.colPrimary).hslHue, 0.9, 0.5, 1)
    property color nextLineColor: Qt.hsla(0, 0, 0.75, 1)
    property int scrollLead: 500
    property bool preRolled: false
    property real lastPositionMs: -1

    function lineIndexAt(positionMs): int {
        let index = -1;
        for (let i = 0; i < root.lines.length; ++i) {
            if (root.lines[i].time <= positionMs)
                index = i;
        }
        return index;
    }

    function advance(): void {
        if (!GlobalStates.lyricsOpen) return;
        if (!root.activePlayer) return;
        const positionMs = root.activePlayer.position * 1000;
        const index = root.lineIndexAt(positionMs);
        if (root.preRolled && positionMs < root.lastPositionMs - 250) {
            root.preRolled = false;
            root.lastPositionMs = positionMs;
            root.resetLines(index);
            return;
        }
        root.lastPositionMs = positionMs;
        if (index === root.shownIndex) {
            if (root.preRolled) {
                root.preRolled = false;
            } else if (index >= 0 && index + 1 < root.lines.length) {
                const nextTime = root.lines[index + 1].time;
                if (positionMs >= nextTime - root.scrollLead) {
                    root.preRolled = true;
                    root.showIndex(index + 1);
                }
            }
            return;
        }
        if (root.preRolled && index === root.shownIndex - 1) return;
        root.preRolled = false;
        if (index === root.shownIndex + 1)
            root.showIndex(index);
        else
            root.resetLines(index);
    }

    function applyCurrent(): void {
        if (!GlobalStates.lyricsOpen) return;
        if (!root.activePlayer) return;
        root.resetLines(root.lineIndexAt(root.activePlayer.position * 1000));
    }

    function resetLines(i): void {
        if (i === root.shownIndex) return;
        root.shownIndex = i;
        root.preRolled = false;
        scrollAnim.stop();
        root.normalizeRest();
    }

    function showIndex(i): void {
        if (i === root.shownIndex || i < 0 || i >= root.lines.length) return;
        root.shownIndex = i;
        if (scrollAnim.running) {
            scrollAnim.stop();
            root.normalizeRest();
        }
        scrollYAnim.from = 0;
        scrollYAnim.to = -root.rowHeight;
        scrollScaleAnim.from = root.nextLineScale;
        scrollScaleAnim.to = 1;
        scrollColorAnim.from = root.nextLineColor;
        scrollColorAnim.to = root.currentLineColorBottom;
        scrollAnim.restart();
    }

    function normalizeRest(): void {
        const index = root.shownIndex;
        if (index >= 0 && index < root.lines.length) {
            currentLine.text = root.lines[index].text;
            nextLine.text = index + 1 < root.lines.length ? root.lines[index + 1].text : "";
        } else if (root.noLyrics) {
            currentLine.text = root.noLyricsText;
            nextLine.text = "";
        } else {
            currentLine.text = "";
            nextLine.text = "";
        }
        currentLine.y = 0;
        currentLine.opacity = 1;
        nextLine.y = root.rowHeight;
        nextLine.opacity = 1;
        nextLine.color = root.nextLineColor;
        nextLine.scale = root.nextLineScale;
        content.y = 0;
    }

    Timer {
        id: dragPollTimer
        running: root.dragging
        interval: 30
        repeat: true
        onTriggered: {
            if (!cursorPollProc.running)
                cursorPollProc.running = true;
        }
    }
    Process {
        id: cursorPollProc
        command: ["hyprctl", "cursorpos"]
        stdout: StdioCollector {
            id: cursorPollCol
            waitForEnd: true
            onStreamFinished: root.onCursorRead(cursorPollCol.text)
        }
    }

    function parseCursorPos(data): var {
        const parts = String(data).trim().split(",");
        if (parts.length !== 2) return null;
        const x = parseFloat(parts[0]);
        const y = parseFloat(parts[1]);
        if (isNaN(x) || isNaN(y)) return null;
        return Qt.point(x, y);
    }

    function onCursorRead(data): void {
        const pos = root.parseCursorPos(data);
        if (!pos) return;
        if (!root.dragging) return;
        const screen = lyricsWindow.screen;
        root.draggedCenterLeft = pos.x - (screen ? screen.x : 0) - root.grabOffset.x + lyricsWindow.width / 2;
        root.draggedTop = pos.y - (screen ? screen.y : 0) - root.grabOffset.y;
    }

    PanelWindow {
        id: lyricsWindow
        visible: true
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        exclusiveZone: 0
        focusable: true
        WlrLayershell.namespace: "quickshell:lyrics"
        WlrLayershell.layer: WlrLayer.Overlay

        anchors {
            top: true
            left: true
        }
        margins {
            top: root.userDragged ? root.draggedTop : root.defaultTopMargin
            left: root.userDragged ? (root.draggedCenterLeft - lyricsWindow.width / 2) : root.centeredLeft
        }

        implicitWidth: root.lyricSlotWidth
        implicitHeight: root.lyricLineHeight * 2 + root.lyricSpacing

        Item {
            id: content
            width: parent.width
            height: parent.height

            StyledText {
                id: currentLine
                anchors.horizontalCenter: parent.horizontalCenter
                height: root.lyricLineHeight
                horizontalAlignment: Text.AlignHCenter
                renderType: Text.QtRendering
                wrapMode: Text.NoWrap
                font.pixelSize: root.currentLineSize
                color: root.currentLineColorBottom
                Behavior on color { ColorAnimation { duration: 300 } }
            }
            StyledText {
                id: nextLine
                anchors.horizontalCenter: parent.horizontalCenter
                height: root.lyricLineHeight
                horizontalAlignment: Text.AlignHCenter
                renderType: Text.QtRendering
                wrapMode: Text.NoWrap
                font.pixelSize: root.currentLineSize
                transformOrigin: Item.Top
            }
        }

        mask: Region {
            item: currentLine

            Region {
                item: nextLine
            }
        }

        ParallelAnimation {
            id: scrollAnim
            NumberAnimation {
                id: scrollYAnim
                target: content
                property: "y"
                duration: 400
                easing.type: Easing.OutCubic
            }
            NumberAnimation {
                id: scrollScaleAnim
                target: nextLine
                property: "scale"
                duration: 400
                easing.type: Easing.OutCubic
            }
            ColorAnimation {
                id: scrollColorAnim
                target: nextLine
                property: "color"
                duration: 400
                easing.type: Easing.OutCubic
            }
            onFinished: root.normalizeRest()
        }

        MouseArea {
            id: dragArea
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton
            cursorShape: Qt.SizeAllCursor

            onPressed: (event) => {
                root.grabOffset = Qt.point(event.x, event.y);
                root.draggedCenterLeft = lyricsWindow.margins.left + lyricsWindow.width / 2;
                root.draggedTop = lyricsWindow.margins.top;
                root.userDragged = true;
                root.dragging = true;
                if (!cursorPollProc.running)
                    cursorPollProc.running = true;
            }
            onReleased: (event) => {
                root.dragging = false;
            }
            onCanceled: (event) => {
                root.dragging = false;
            }
        }
    }

    PanelWindow {
        id: pickerWindow
        visible: GlobalStates.lyricsPickerOpen
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        exclusiveZone: 0
        focusable: true
        WlrLayershell.namespace: "quickshell:lyrics-picker"
        WlrLayershell.layer: WlrLayer.Overlay
        anchors { top: true; bottom: true; left: true; right: true }

        LyricsPicker {
            id: picker
            anchors.fill: parent
            color: "transparent"
            show: GlobalStates.lyricsPickerOpen
            context: root.currentTrackContext()
            textTools: root.text
            initialQuery: context?.title ?? ""
            onDismiss: GlobalStates.lyricsPickerOpen = false
            onChosen: root.applyChosenLyrics(lines)
        }
    }
}
