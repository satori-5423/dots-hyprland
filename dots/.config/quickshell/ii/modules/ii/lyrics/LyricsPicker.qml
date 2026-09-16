import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs
import qs.modules.common
import qs.modules.common.widgets

WindowDialog {
    id: root
    property var context: null
    property var textTools: null
    property alias query: queryField.text
    property string initialQuery: ""
    property bool searching: false
    signal chosen(var lines)

    onShowChanged: {
        if (!show) return;
        queryField.text = root.initialQuery;
        queryField.forceActiveFocus();
        root.search();
    }

    backgroundWidth: 560
    backgroundHeight: 620

    WindowDialogTitle { text: "选择歌词" }

    MaterialTextField {
        id: queryField
        Layout.fillWidth: true
        placeholderText: "歌曲标题、艺术家或关键词"
        onAccepted: root.search()
    }

    RowLayout {
        Layout.fillWidth: true
        DialogButton { buttonText: "搜索"; onClicked: root.search() }
        Item { Layout.fillWidth: true }
        DialogButton { buttonText: "关闭"; onClicked: root.dismiss() }
    }

    ListView {
        id: resultList
        z: 1
        Layout.fillWidth: true
        Layout.fillHeight: true
        clip: true
        spacing: 2
        model: ListModel { id: results }
        delegate: Rectangle {
            required property string title
            required property string artist
            required property string source
            required property string songId
            width: resultList.width
            height: 58
            radius: Appearance.rounding.small
            color: mouse.containsMouse ? Appearance.colors.colLayer2Hover : Appearance.colors.colLayer2
            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 8
                spacing: 0
                StyledText { Layout.fillWidth: true; text: title; elide: Text.ElideRight }
                StyledText { Layout.fillWidth: true; text: `${artist}  ·  ${source}`; color: Appearance.m3colors.m3onSurfaceVariant; elide: Text.ElideRight }
            }
            MouseArea {
                id: mouse
                anchors.fill: parent
                acceptedButtons: Qt.LeftButton
                hoverEnabled: true
                onClicked: root.choose(songId, source)
            }
        }
    }

    Process {
        id: searchProc
        stdout: StdioCollector {
            id: searchCol
            waitForEnd: true
            onStreamFinished: root.searchDone(searchCol.text)
        }
    }
    Process {
        id: lyricProc
        property string source: ""
        property string selectedId: ""
        stdout: StdioCollector {
            id: lyricCol
            waitForEnd: true
            onStreamFinished: root.lyricDone(lyricCol.text)
        }
    }

    function search(): void {
        results.clear();
        root.searching = true;
        const q = encodeURIComponent(root.query.trim());
        if (!q) return;
        searchProc.command = ["sh", "-c", `printf 'QQ\\n'; curl -sS -L --max-time 12 -A 'Mozilla/5.0' 'https://c.y.qq.com/soso/fcgi-bin/client_search_cp?w=${q}&format=json&n=10'; printf '\\nNETEASE\\n'; curl -sS -L --max-time 12 -A 'Mozilla/5.0' 'https://music.163.com/api/search/get?s=${q}&type=1&limit=10'`];
        searchProc.running = true;
    }

    function searchDone(raw): void {
        const chunks = String(raw).split("\nNETEASE\n");
        const qq = chunks[0].replace(/^QQ\n/, "");
        const netease = chunks[1] ?? "";
        const qqSongs = textTools?.parseJson(qq)?.data?.song?.list ?? [];
        const neteaseSongs = textTools?.parseJson(netease)?.result?.songs ?? [];
        for (const song of qqSongs) results.append({ title: song.songname ?? "", artist: (song.singer ?? []).map(a => a.name).join(", "), source: "QQ音乐", songId: String(song.songmid), });
        for (const song of neteaseSongs) results.append({ title: song.name ?? "", artist: (song.artists ?? []).map(a => a.name).join(", "), source: "网易云音乐", songId: String(song.id), });
        root.searching = false;
    }

    function choose(id, source): void {
        lyricProc.source = source;
        lyricProc.selectedId = id;
        lyricProc.command = source === "QQ音乐"
            ? ["curl", "-sS", "-L", "--max-time", "12", "-A", "Mozilla/5.0", "-H", "Referer: https://y.qq.com", `https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg?songmid=${id}&format=json&nobase64=1`]
            : ["curl", "-sS", "-L", "--max-time", "12", "-A", "Mozilla/5.0", `https://music.163.com/api/song/lyric?id=${id}&lv=1&kv=0&tv=1`];
        lyricProc.running = true;
    }

    function lyricDone(raw): void {
        const lines = lyricProc.source === "QQ音乐"
            ? textTools.parseQqLyrics(raw)
            : textTools.parseNeteaseLyrics(raw);
        if (lines.length > 0) root.chosen(lines);
    }
}
