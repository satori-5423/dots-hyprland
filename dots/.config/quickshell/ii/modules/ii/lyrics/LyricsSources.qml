import QtQuick
import Quickshell
import Quickshell.Io

Item {
    id: root

    property var text: LyricsText { id: textTools }
    property bool active: false
    property int matchThreshold: 80
    property int generation: 0
    property string title: ""
    property string artist: ""
    property string album: ""
    property real length: 0
    property real position: 0
    property bool qqFinished: false
    property bool neteaseFinished: false
    property var qqResult: null
    property var neteaseResult: null

    signal resolved(var lines)
    signal empty()

    Process {
        id: qqSearchProc
        property int nextQuery: 1
        stdout: StdioCollector {
            id: qqSearchCol
            property int gen: -1
            waitForEnd: true
            onStreamFinished: root.onQqSearchDone(qqSearchCol.text)
        }
    }
    Process {
        id: qqLyricProc
        stdout: StdioCollector {
            id: qqLyricCol
            property int gen: -1
            property real matchScore: 0
            waitForEnd: true
            onStreamFinished: root.onQqLyricDone(qqLyricCol.text)
        }
    }
    Process {
        id: neteaseSearchProc
        property int nextQuery: 1
        stdout: StdioCollector {
            id: neteaseSearchCol
            property int gen: -1
            waitForEnd: true
            onStreamFinished: root.onNeteaseSearchDone(neteaseSearchCol.text)
        }
    }
    Process {
        id: neteaseLyricProc
        stdout: StdioCollector {
            id: neteaseLyricCol
            property int gen: -1
            property real matchScore: 0
            waitForEnd: true
            onStreamFinished: root.onNeteaseLyricDone(neteaseLyricCol.text)
        }
    }
    Process {
        id: lrclibProc
        stdout: StdioCollector {
            id: lrclibCol
            property int gen: -1
            waitForEnd: true
            onStreamFinished: root.onLrclibDone(lrclibCol.text)
        }
    }

    function queries(): var {
        if (!root.title) return [];
        return root.artist ? [ `${root.title} ${root.artist}`, root.title ] : [ root.title ];
    }

    function run(proc, command, collector): void {
        collector.gen = root.generation;
        proc.command = command;
        proc.running = false;
        proc.running = true;
    }

    function cancel(): void {
        for (const proc of [qqSearchProc, qqLyricProc, neteaseSearchProc, neteaseLyricProc, lrclibProc])
            proc.running = false;
    }

    function stale(collector): bool {
        return !root.active || collector.gen !== root.generation;
    }

    function start(): void {
        root.cancel();
        root.qqFinished = false;
        root.neteaseFinished = false;
        root.qqResult = null;
        root.neteaseResult = null;
        root.startQqSearch(0);
        root.startNeteaseSearch(0);
    }

    function startQqSearch(attempt): void {
        const searchQueries = root.queries();
        if (attempt >= searchQueries.length) {
            root.qqFinished = true;
            root.considerResults();
            return;
        }
        const url = "https://c.y.qq.com/soso/fcgi-bin/client_search_cp?w=" + encodeURIComponent(searchQueries[attempt]) + "&format=json&n=10";
        qqSearchProc.nextQuery = attempt + 1;
        root.run(qqSearchProc, ["curl", "-s", "-L", "--max-time", "10", "-A", "Mozilla/5.0", "-H", "Referer: https://y.qq.com", url], qqSearchCol);
    }

    function onQqSearchDone(raw): void {
        if (root.stale(qqSearchCol)) return;
        const result = root.pickQqSong(raw);
        if (result !== null) {
            qqLyricCol.matchScore = result.score;
            const url = "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg?songmid=" + result.id + "&format=json&nobase64=1";
            root.run(qqLyricProc, ["curl", "-s", "-L", "--max-time", "10", "-A", "Mozilla/5.0", "-H", "Referer: https://y.qq.com", url], qqLyricCol);
        } else root.startQqSearch(qqSearchProc.nextQuery);
    }

    function onQqLyricDone(raw): void {
        if (root.stale(qqLyricCol)) return;
        const parsed = root.text.parseQqLyrics(raw);
        if (parsed.length > 0) {
            root.qqResult = { lines: parsed, score: qqLyricCol.matchScore };
            root.qqFinished = true;
            root.considerResults();
        } else root.startQqSearch(qqSearchProc.nextQuery);
    }

    function pickQqSong(raw): var {
        const songs = root.text.parseJson(raw)?.data?.song?.list;
        if (!Array.isArray(songs) || songs.length === 0) return null;
        return root.pickSong(songs, s => s.songname, s => s.albumname, s => s.interval, s => s.singer, s => s.songmid);
    }

    function startNeteaseSearch(attempt): void {
        const searchQueries = root.queries();
        if (attempt >= searchQueries.length) {
            root.neteaseFinished = true;
            root.considerResults();
            return;
        }
        const url = "https://music.163.com/api/search/get?s=" + encodeURIComponent(searchQueries[attempt]) + "&type=1&limit=10";
        neteaseSearchProc.nextQuery = attempt + 1;
        root.run(neteaseSearchProc, ["curl", "-s", "-L", "--max-time", "10", "-A", "Mozilla/5.0", "-H", "Referer: https://music.163.com", url], neteaseSearchCol);
    }

    function onNeteaseSearchDone(raw): void {
        if (root.stale(neteaseSearchCol)) return;
        const result = root.pickNeteaseSong(raw);
        if (result !== null) {
            neteaseLyricCol.matchScore = result.score;
            const url = "https://music.163.com/api/song/lyric?id=" + result.id + "&lv=1&kv=0&tv=1";
            root.run(neteaseLyricProc, ["curl", "-s", "-L", "--max-time", "10", "-A", "Mozilla/5.0", "-H", "Referer: https://music.163.com", url], neteaseLyricCol);
        } else root.startNeteaseSearch(neteaseSearchProc.nextQuery);
    }

    function onNeteaseLyricDone(raw): void {
        if (root.stale(neteaseLyricCol)) return;
        const parsed = root.text.parseNeteaseLyrics(raw);
        if (parsed.length > 0) {
            root.neteaseResult = { lines: parsed, score: neteaseLyricCol.matchScore };
            root.neteaseFinished = true;
            root.considerResults();
        } else root.startNeteaseSearch(neteaseSearchProc.nextQuery);
    }

    function pickNeteaseSong(raw): var {
        const songs = root.text.parseJson(raw)?.result?.songs;
        if (!Array.isArray(songs) || songs.length === 0) return null;
        return root.pickSong(songs, s => s.name, s => s.album?.name, s => s.duration / 1000, s => s.artists, s => s.id);
    }

    function pickSong(songs, titleOf, albumOf, durationOf, artistOf, idOf): var {
        const titleLower = root.title.toLowerCase();
        const artistLower = root.artist.toLowerCase();
        const albumLower = root.album.toLowerCase();
        const saneLength = root.length > root.position;
        let best = null;
        let bestScore = -1;
        for (const song of songs) {
            const score = root.text.scoreSong(titleLower, artistLower, albumLower, root.length, saneLength,
                titleOf(song), artistOf(song), albumOf(song), durationOf(song));
            if (score > bestScore) { best = song; bestScore = score; }
        }
        if (best === null || bestScore < root.matchThreshold) return null;
        return { id: String(idOf(best) ?? ""), score: bestScore };
    }

    function considerResults(): void {
        if (!root.qqFinished || !root.neteaseFinished) return;
        if (root.qqResult !== null || root.neteaseResult !== null) {
            const qq = root.qqResult;
            const netease = root.neteaseResult;
            const winner = qq === null ? netease : netease === null ? qq : qq.score >= netease.score ? qq : netease;
            root.resolved(winner.lines);
        } else root.startLrclib();
    }

    function startLrclib(): void {
        if (!root.active || !root.title) { root.empty(); return; }
        let url = "https://lrclib.net/api/search?track_name=" + encodeURIComponent(root.title);
        if (root.artist) url += "&artist_name=" + encodeURIComponent(root.artist);
        root.run(lrclibProc, ["curl", "-s", "-L", "--max-time", "15", "-A", "Mozilla/5.0", url], lrclibCol);
    }

    function onLrclibDone(raw): void {
        if (root.stale(lrclibCol)) return;
        let parsed = [];
        const list = root.text.parseJson(raw);
        if (Array.isArray(list)) {
            let best = null;
            let bestScore = -1;
            for (const entry of list) {
                if (!entry || typeof entry.syncedLyrics !== "string") continue;
                const score = root.text.scoreSong(root.title.toLowerCase(), root.artist.toLowerCase(), root.album.toLowerCase(), root.length, root.length > root.position,
                    entry.trackName, entry.artistName, entry.albumName, entry.duration);
                if (score > bestScore) { best = entry; bestScore = score; }
            }
            if (best !== null && bestScore >= root.matchThreshold) parsed = root.text.parseLrc(best.syncedLyrics);
        }
        if (parsed.length > 0) root.resolved(parsed);
        else root.empty();
    }
}
