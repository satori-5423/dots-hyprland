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

    // ==========================================================================
    // Filter words & platform names: all named vocabulary lives here so the
    // logic below only references these lists and the derived patterns. Add or
    // adjust a platform or filter word here; everything else picks it up
    // automatically.
    // ==========================================================================

    // Media-type words that mark a name as a platform when fused onto a single
    // brand token ("QQ音乐", "喜马拉雅FM"). Latin or CJK. Structural detection
    // makes new platforms match without being enumerated.
    readonly property var mediaTypeWords: [
        "Music", "FM", "Radio", "Podcast", "Player", "Video", "Streaming",
        "云音乐", "音乐", "电台", "播放器", "播客", "听书", "短视频", "收音机",
    ]

    // Platforms the structural pattern can't catch and must be listed: spaced
    // "brand + media-type word" combos ("YouTube Music", "Apple Music") and
    // pure brands with no media-type word ("Spotify", "Bilibili", "YouTube").
    // Spaced names are structurally indistinguishable from real song titles.
    readonly property var platformNames: [
        "YouTube Music", "Apple Music", "Amazon Music", "Yandex Music",
        "Spotify", "Bilibili", "YouTube", "SoundCloud", "iTunes", "NetEase", "喜马拉雅",
    ]

    // Version/format markers appended to track titles, stripped before search
    // ("(Official Music Video)", "(Audio)", " MV", "翻唱"). Prefix words combine
    // freely with base words (Official Music Video, Lyric Video...); a base word
    // alone also matches.
    readonly property var titleMarkerPrefixes: [ "official", "music", "lyric" ]
    readonly property var titleMarkers: [ "video", "audio", "mv", "cover", "翻唱", "live" ]

    // Collaborator markers appended to artist names ("feat. Someone", "ft. Someone")
    readonly property var artistMarkers: [ "feat", "ft" ]

    // Separators a platform suffix can trail after: pipes ("Song | Spotify",
    // short segments always stripped) and dashes ("Song - Artist", stripped only
    // when structurally platform-like). The dash sits last so it is a literal
    // inside character classes.
    readonly property string pipeSeparators: "|｜"
    readonly property string dashSeparators: "–-"

    // Characters not allowed inside a platform brand (must be a single token:
    // no whitespace or separators)
    readonly property string brandExcludedChars: "\\s" + root.pipeSeparators + ",，·•、"

    // D-Bus name prefix of browser-integration buses (their title can lag the
    // real track, so avoid them when picking a player)
    readonly property string browserIntegrationBusPrefix: "org.mpris.MediaPlayer2.plasma-browser-integration"

    // ---- Derived patterns: don't edit these, edit the lists above ----
    readonly property var platformNameRe: new RegExp(
        "^(?:[^" + root.brandExcludedChars + "]{0,32})(?:" + root.mediaTypeWords.join("|") + ")$",
        "i")
    readonly property var titleMarkerRe: new RegExp(
        "(?:(?:" + root.titleMarkerPrefixes.join("|") + ")\\s*)*(?:" + root.titleMarkers.join("|") + ")",
        "i")
    readonly property var parenTitleMarkerRe: new RegExp(
        "\\s*[（(]" + root.titleMarkerRe.source + "[）)]\\s*$",
        "i")
    readonly property var bareTitleMarkerRe: new RegExp(
        "\\s*" + root.titleMarkerRe.source + "$",
        "i")
    readonly property var artistMarkerRe: new RegExp(
        "\\s*(?:" + root.artistMarkers.join("|") + ")\\.?.*$",
        "i")
    readonly property var platformSuffixRe: new RegExp(
        "\\s*([" + root.pipeSeparators + root.dashSeparators + "])\\s*([^" + root.pipeSeparators + "]+)$",
        "")
    readonly property var trailingSeparatorsRe: new RegExp(
        "[\\s" + root.pipeSeparators + root.dashSeparators + "]+$",
        "")

    // Pick the player that best describes the playing track: prefer a native bus
    // with a real title (browser-integration buses can lag a real track change
    // and keep reporting the previous track's title while playing), with the
    // artist/sane-length tiebreakers picking the best-described candidate; fall
    // back to any real-title player, then any playing one.
    readonly property MprisPlayer activePlayer: {
        const playing = Mpris.players.values.filter(p => p.isPlaying);
        const native = p => !String(p.dbusName ?? "").startsWith(root.browserIntegrationBusPrefix);
        const real = p => root.isPlatformTitle(p.trackTitle) === false;
        for (const p of playing)
            if (native(p) && real(p) && p.length > p.position
                && String(p.trackArtist ?? "").trim() !== "") return p;
        for (const p of playing)
            if (native(p) && real(p) && p.length > p.position) return p;
        for (const p of playing)
            if (real(p) && p.length > p.position
                && String(p.trackArtist ?? "").trim() !== "") return p;
        for (const p of playing)
            if (real(p) && p.length > p.position) return p;
        for (const p of playing)
            if (p.length > p.position) return p;
        if (playing.length > 0) return playing[0];
        return MprisController.activePlayer;
    }
    property var lines: [] // [{ time: ms, text: string }] sorted by time
    property int shownIndex: -1
    property real lyricSpacing: 10
    property int matchThreshold: 80 // below this a search result is a guess: fall through to the next source
    property string fetchedTitle: "" // normalized title whose lyrics are currently loaded
    property string fetchingTitle: "" // normalized title currently being fetched
    property int fetchGen: 0 // bumped per new fetch; steps carry the gen they were launched under
    property int fetchAttempts: 0 // consecutive empty results; retried a few times before giving up
    property bool noLyrics: false // true once all retries failed, to show a placeholder
    property string noLyricsText: "No lyrics found"

    // Window stays mounted at all times; only its content is shown when the
    // lyrics are toggled on. This avoids recreating the layer surface on every
    // toggle (rapid toggling can break the surface).
    property bool lyricsOpen: GlobalStates.lyricsOpen

    // Drag state, driven by the global cursor position so the window tracks the
    // mouse 1:1 (surface-relative deltas feed back into themselves while moving
    // a layer-shell window and end up trailing or oscillating).
    property bool userDragged: false
    property bool dragging: false
    property point grabOffset: Qt.point(0, 0)
    property real draggedCenterLeft: 0 // the window's center x while dragged
    property real draggedTop: 0

    // Same top offset as the media controls popup so it doesn't touch the bar
    property real defaultTopMargin: Appearance.sizes.barHeight

    // Keep the shown line in sync with playback. The poll is fast so a line
    // change is detected within ~100ms of its timestamp (plus the pre-roll in
    // advance(), which absorbs the scroll duration).
    Timer {
        id: positionTimer
        running: GlobalStates.lyricsOpen
        interval: 100
        repeat: true
        onTriggered: root.advance()
    }

    // Safety net: re-check the title periodically so a player/title update that
    // emitted no signal still gets picked up. fetchLyrics dedups, so this is cheap.
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

        // Seek/position jumps respond instantly instead of waiting for the poll timer
        function onPositionChanged() {
            root.advance();
        }

        // Some players update the title without a track-change signal; fetch on
        // any title change instead of relying on MprisController.trackChanged
        // alone. fetchLyrics dedups, so duplicates are cheap.
        function onTrackTitleChanged() {
            if (GlobalStates.lyricsOpen)
                root.fetchLyrics();
        }
    }

    onLyricsOpenChanged: {
        if (GlobalStates.lyricsOpen) {
            root.userDragged = false; // always opens back at the top-center
            root.fetchLyrics();
            root.applyCurrent();
        } else {
            root.shownIndex = -1;
            root.preRolled = false;
            root.lines = []; // drop the lyrics so no stray signal can ever re-render them
            root.noLyrics = false;
            root.fetchingTitle = "";
            root.cancelAllFetches();
            root.normalizeRest(); // clear the text so the closed window shows nothing
        }
    }

    // ---------------- lyric sources: qq music → netease → lrclib ----------------

    Process {
        id: qqSearchProc
        property int nextQuery: 1
        stdout: StdioCollector {
            id: qqSearchCol
            property int gen: -1 // fetch generation this step was launched under
            waitForEnd: true
            onStreamFinished: root.onQqSearchDone(qqSearchCol.text)
        }
    }
    Process {
        id: qqLyricProc
        stdout: StdioCollector {
            id: qqLyricCol
            property int gen: -1 // fetch generation this step was launched under
            waitForEnd: true
            onStreamFinished: root.onQqLyricDone(qqLyricCol.text)
        }
    }
    Process {
        id: neteaseSearchProc
        property int nextQuery: 1
        stdout: StdioCollector {
            id: neteaseSearchCol
            property int gen: -1 // fetch generation this step was launched under
            waitForEnd: true
            onStreamFinished: root.onNeteaseSearchDone(neteaseSearchCol.text)
        }
    }
    Process {
        id: neteaseLyricProc
        stdout: StdioCollector {
            id: neteaseLyricCol
            property int gen: -1 // fetch generation this step was launched under
            waitForEnd: true
            onStreamFinished: root.onNeteaseLyricDone(neteaseLyricCol.text)
        }
    }
    Process {
        id: lrclibProc
        stdout: StdioCollector {
            id: lrclibCol
            property int gen: -1 // fetch generation this step was launched under
            waitForEnd: true
            onStreamFinished: root.onLrclibDone(lrclibCol.text)
        }
    }

    function runProcess(proc, command): void {
        proc.command = command;
        proc.running = false; // cancel any in-flight run of this step
        proc.running = true;
    }

    // True when a name is a media platform: structurally (brand + media-type
    // word, see mediaTypeWords) or one of the explicitly-listed brand names
    // (see platformNames). Both live in the config block at the top.
    function isPlatformLike(name): bool {
        const s = String(name ?? "").trim();
        if (s.length === 0) return false;
        if (root.platformNameRe.test(s)) return true;
        const lower = s.toLowerCase();
        return root.platformNames.some(n => n.toLowerCase() === lower);
    }

    // True when the MPRIS title is just a platform name rather than a real track
    // (players report these as placeholders while a track is loading)
    function isPlatformTitle(title): bool {
        return root.isPlatformLike(title);
    }

    // Strip trailing platform-name segments after " | ", "｜", " - " or " – "
    // (e.g. "Song | Platform" -> "Song"). A " | " / "｜" segment is stripped
    // whenever it is short: that separator is the browser-native platform format
    // and platform names are short, so even pure brand names are caught without
    // a list. A " - " / "–" segment is only stripped when it is structurally
    // platform-like, so real "Song - Artist" names and "Song-Artist" survive.
    function stripPlatformSuffix(raw): string {
        let s = String(raw ?? "").trim();
        while (true) {
            const m = root.platformSuffixRe.exec(s);
            if (!m) break;
            const sep = m[1];
            const seg = m[2].trim();
            const pipeSep = root.pipeSeparators.includes(sep);
            if ((pipeSep && seg.length <= 32) || root.isPlatformLike(seg)) {
                s = s.slice(0, m.index).trim();
                continue;
            }
            break;
        }
        return s;
    }

    // Normalize the MPRIS title for search and dedup: strip trailing platform
    // suffixes that browser integrations append, plus bracketed cover/version
    // markers ("Title【cover ▪ Artist】", "Title (Official Video)", ...). The same
    // song arrives as several title variants, so all comparisons go through this.
    function cleanTrackTitle(raw): string {
        return root.stripPlatformSuffix(StringUtils.cleanMusicTitle(raw))
            .replace(/【[^】]*】\s*$/, "")
            // Parenthesized markers: "(Official Music Video)", "(Audio)", "(MV)" ...
            .replace(root.parenTitleMarkerRe, "")
            // Bare trailing markers: " - Music Video", " MV", "翻唱" ...
            .replace(root.bareTitleMarkerRe, "")
            // Separators left behind by the stripping above
            .replace(root.trailingSeparatorsRe, "")
            .trim();
    }

    // Normalize the MPRIS artist for search and comparison: drop bracketed
    // channel/uploader markers ("【…】") and "feat." style suffixes.
    function cleanArtist(raw): string {
        return String(raw ?? "")
            .replace(/【[^】]*】/g, "")
            .replace(/\s*[（(].*?[）)]/g, "")
            .replace(root.artistMarkerRe, "")
            .trim();
    }

    function searchQueries(): var {
        const title = root.fetchingTitle || root.cleanTrackTitle(root.activePlayer?.trackTitle ?? "");
        const artist = root.cleanArtist(root.activePlayer?.trackArtist ?? "");
        if (!title) return [];
        return artist ? [ `${title} ${artist}`, title ] : [ title ];
    }

    function fetchLyrics(): void {
        if (!root.activePlayer) return;
        const title = root.cleanTrackTitle(root.activePlayer.trackTitle);
        if (!title) { root.finishFetch([]); return; } // no title -> don't show stale lyrics from the previous track
        // Some players report a bare platform-name placeholder between tracks;
        // the real title arrives a moment later, so don't fetch this
        if (root.isPlatformTitle(title)) return;
        // The same song emits several signals (placeholder, clean and suffixed
        // titles, changing unique ids): only fetch once per real title
        if (title === root.fetchedTitle || title === root.fetchingTitle) return;
        root.fetchGen++;
        root.cancelAllFetches();
        root.fetchingTitle = title;
        root.fetchAttempts = 0;
        root.noLyrics = false;
        fetchRetryTimer.stop();
        // Drop the previous track's lines right away so its lyrics never linger on
        // the new track while the fetch is in flight
        root.lines = [];
        root.shownIndex = -1;
        root.normalizeRest();
        fetchWatchdog.restart();
        root.startQqSearch(0);
    }

    // Kill every in-flight pipeline process when a new fetch takes over, so stale
    // results from the previous track cannot land later
    function cancelAllFetches(): void {
        for (const p of [qqSearchProc, qqLyricProc, neteaseSearchProc, neteaseLyricProc, lrclibProc])
            p.running = false;
    }

    function launchStep(proc, col, command): void {
        col.gen = root.fetchGen;
        root.runProcess(proc, command);
    }

    // A pipeline step is stale if lyrics were closed or a newer fetch started since
    // this step was launched. The live title must NOT gate results: it can flicker
    // to a platform-name placeholder and back even mid-song, which would drop the
    // in-flight result and strand the pipeline. Real track changes bump fetchGen.
    function stepStale(col): bool {
        if (!GlobalStates.lyricsOpen) return true;
        return col.gen !== root.fetchGen;
    }

    // A fetch that comes back empty is usually a transient network/match blip, not
    // proof the song has no lyrics: retry a few times before giving up (see finishFetch)
    Timer {
        id: fetchRetryTimer
        interval: 1500
        repeat: false
        onTriggered: {
            if (!GlobalStates.lyricsOpen) return;
            if (root.fetchAttempts >= 5) { root.giveUpNoLyrics(); root.normalizeRest(); return; }
            fetchWatchdog.restart();
            root.startQqSearch(0);
        }
    }

    // Safety net: if a pipeline ever strands without delivering a result, restart
    // it so the lyrics don't stay blank until the next track change
    Timer {
        id: fetchWatchdog
        interval: 8000
        repeat: false
        onTriggered: {
            if (!GlobalStates.lyricsOpen) return;
            if (root.fetchingTitle === "") return; // no fetch in flight
            root.fetchGen++;
            root.cancelAllFetches();
            root.fetchAttempts = 0;
            root.startQqSearch(0);
        }
    }

    // --- qq music ---

    function startQqSearch(attempt): void {
        const queries = root.searchQueries();
        if (attempt >= queries.length) { root.startNeteaseSearch(0); return; }
        const url = "https://c.y.qq.com/soso/fcgi-bin/client_search_cp?w=" + encodeURIComponent(queries[attempt]) + "&format=json&n=10";
        qqSearchProc.nextQuery = attempt + 1;
        root.launchStep(qqSearchProc, qqSearchCol, ["curl", "-s", "-L", "--max-time", "10", "-A", "Mozilla/5.0", "-H", "Referer: https://y.qq.com", url]);
    }

    function onQqSearchDone(raw): void {
        if (root.stepStale(qqSearchCol)) return;
        const mid = root.pickQqSongMid(raw);
        if (mid) {
            const url = "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg?songmid=" + mid + "&format=json&nobase64=1";
            root.launchStep(qqLyricProc, qqLyricCol, ["curl", "-s", "-L", "--max-time", "10", "-A", "Mozilla/5.0", "-H", "Referer: https://y.qq.com", url]);
        } else {
            root.startQqSearch(qqSearchProc.nextQuery);
        }
    }

    function onQqLyricDone(raw): void {
        if (root.stepStale(qqLyricCol)) return;
        const parsed = root.parseQqLyrics(raw);
        if (parsed.length > 0) root.finishFetch(parsed);
        else root.startNeteaseSearch(0);
    }

    function pickQqSongMid(raw): string {
        const data = root.parseJson(raw);
        const songs = data?.data?.song?.list;
        if (!Array.isArray(songs) || songs.length === 0) return "";
        return String(root.pickSong(songs, s => s.songname, s => s.albumname, s => s.interval, s => s.singer, s => s.songmid));
    }

    // --- netease ---

    function startNeteaseSearch(attempt): void {
        const queries = root.searchQueries();
        if (attempt >= queries.length) { root.startLrclib(); return; }
        const url = "https://music.163.com/api/search/get?s=" + encodeURIComponent(queries[attempt]) + "&type=1&limit=10";
        neteaseSearchProc.nextQuery = attempt + 1;
        root.launchStep(neteaseSearchProc, neteaseSearchCol, ["curl", "-s", "-L", "--max-time", "10", "-A", "Mozilla/5.0", "-H", "Referer: https://music.163.com", url]);
    }

    function onNeteaseSearchDone(raw): void {
        if (root.stepStale(neteaseSearchCol)) return;
        const id = root.pickNeteaseSongId(raw);
        if (id) {
            const url = "https://music.163.com/api/song/lyric/v1?id=" + id + "&lv=1&kv=0&tv=1&yv=1";
            root.launchStep(neteaseLyricProc, neteaseLyricCol, ["curl", "-s", "-L", "--max-time", "10", "-A", "Mozilla/5.0", "-H", "Referer: https://music.163.com", url]);
        } else {
            root.startNeteaseSearch(neteaseSearchProc.nextQuery);
        }
    }

    function onNeteaseLyricDone(raw): void {
        if (root.stepStale(neteaseLyricCol)) return;
        const parsed = root.parseNeteaseLyrics(raw);
        if (parsed.length > 0) root.finishFetch(parsed);
        else root.startLrclib();
    }

    function pickNeteaseSongId(raw): string {
        const data = root.parseJson(raw);
        const songs = data?.result?.songs;
        if (!Array.isArray(songs) || songs.length === 0) return "";
        return String(root.pickSong(songs, s => s.name, s => s.album?.name, s => s.duration / 1000, s => s.artists, s => s.id));
    }

    // Pick the search result that best matches the playing track. Songs come in many
    // versions (live, covers, re-recordings, medleys) with different timelines:
    //   - an exact title match identifies the same song,
    //   - an artist match filters out covers by other artists,
    //   - a result from the same album is almost certainly the right version,
    //   - a close duration is the best version discriminator: covers and live
    //     takes drift far from the track's real length, so it outranks a bare
    //     title match (only counted when the length is trustworthy).
    function pickSong(songs, titleOf, albumOf, durationOf, artistOf, idOf): string {
        const title = root.cleanTrackTitle(root.activePlayer?.trackTitle ?? "").toLowerCase();
        const artist = root.cleanArtist(root.activePlayer?.trackArtist ?? "").toLowerCase();
        const album = String(root.activePlayer?.trackAlbum ?? "").trim().toLowerCase();
        const length = root.activePlayer?.length ?? 0;
        // Some native player buses report a broken length (0 or equal to the position)
        const saneLength = length > (root.activePlayer?.position ?? 0);
        let best = null;
        let bestScore = -1;
        for (const song of songs) {
            const score = root.scoreSong(title, artist, album, length, saneLength,
                titleOf(song), artistOf(song), albumOf(song), durationOf(song));
            if (score > bestScore) { best = song; bestScore = score; }
        }
        // A weak best match is a guess: fall through to the next lyric source
        if (best === null || bestScore < root.matchThreshold) return "";
        return String(idOf(best) ?? "");
    }

    // Score how well a search result matches the playing track. An artist match
    // plus a close duration is the strongest evidence of the *same recording* and
    // beats a bare exact-title match, which covers / live takes / re-recordings
    // share with the original.
    function scoreSong(title, artist, album, length, saneLength, songTitle, songArtist, songAlbum, songDuration): number {
        let score = 0;
        const sTitle = String(songTitle ?? "").trim().toLowerCase();
        if (title) {
            // Exact name match: covers/lives/medleys carry extra markers and don't qualify
            if (sTitle === title) score += 80;
            // Search results often append the artist/version ("Song-Artist", "Song (Live)")
            else if (title.length >= 2 && sTitle.startsWith(title)) score += 40;
            // Or the source title carries a marker the result doesn't
            else if (sTitle.length >= 2 && title.startsWith(sTitle)) score += 25;
        }
        if (artist && root.artistMatches(artist, songArtist)) score += 60;
        // Some players report the page URL as the album; only reward a real name match
        const songAlbumName = String(songAlbum ?? "").trim().toLowerCase();
        if (album && !album.startsWith("http") && songAlbumName === album) score += 50;
        if (saneLength && typeof songDuration === "number" && songDuration > 0 && length > 0) {
            const diff = Math.abs(songDuration - length);
            // Within ~2% (or 5s) of the real length it's almost certainly the same
            // recording; fall off afterwards so live takes/medleys score far lower
            const tolerance = Math.max(5, length * 0.02);
            score += diff <= tolerance ? 90 : Math.max(0, 90 - (diff - tolerance) / 2);
        }
        return score;
    }

    // True when the result's artist(s) match the playing track's artist. Handles
    // string names (lrclib) and arrays of {name} (qq music / netease), "feat."
    // style suffixes, bracketed channel markers, and traditional / simplified
    // variants via their shared latin token.
    function artistMatches(trackArtist, songArtists): bool {
        const ta = root.cleanArtist(trackArtist).toLowerCase();
        if (!ta) return false;
        const names = [];
        if (Array.isArray(songArtists)) {
            for (const a of songArtists) {
                if (typeof a === "string") names.push(a);
                else if (a && typeof a.name === "string") names.push(a.name);
            }
        } else {
            names.push(String(songArtists ?? ""));
        }
        const taTokens = root.latinTokens(ta);
        for (const name of names) {
            const n = root.cleanArtist(name).toLowerCase();
            if (!n || n.length < 2) continue;
            if (n === ta || ta.includes(n) || n.includes(ta)) return true;
            // Traditional/simplified variants keep their latin token
            if (taTokens.length > 0) {
                const nTokens = root.latinTokens(n);
                if (nTokens.some(t => taTokens.includes(t))) return true;
            }
        }
        return false;
    }

    // Lowercased ASCII alphanumeric runs (length >= 2) extracted from a name.
    function latinTokens(s): var {
        const out = [];
        const re = /[a-z0-9]{2,}/g;
        let m;
        while ((m = re.exec(String(s).toLowerCase())) !== null)
            out.push(m[0]);
        return out;
    }

    // --- lrclib ---

    function startLrclib(): void {
        if (!GlobalStates.lyricsOpen) return;
        const title = root.fetchingTitle;
        if (!title) { root.finishFetch([]); return; }
        const artist = root.cleanArtist(root.activePlayer?.trackArtist ?? "");
        // /api/get rejects an empty artist_name with 400; /api/search accepts the
        // bare track name, so use it and pick the closest candidate below
        let url = "https://lrclib.net/api/search?track_name=" + encodeURIComponent(title);
        if (artist) url += "&artist_name=" + encodeURIComponent(artist);
        root.launchStep(lrclibProc, lrclibCol, ["curl", "-s", "-L", "--max-time", "15", "-A", "Mozilla/5.0", url]);
    }

    function onLrclibDone(raw): void {
        if (root.stepStale(lrclibCol)) return;
        let parsed = [];
        try {
            const data = root.parseJson(raw);
            const list = Array.isArray(data) ? data : [];
            let best = null;
            let bestScore = -1;
            const title = root.cleanTrackTitle(root.activePlayer?.trackTitle ?? "").toLowerCase();
            const artist = root.cleanArtist(root.activePlayer?.trackArtist ?? "").toLowerCase();
            const album = String(root.activePlayer?.trackAlbum ?? "").trim().toLowerCase();
            const length = root.activePlayer?.length ?? 0;
            const saneLength = length > (root.activePlayer?.position ?? 0);
            for (const entry of list) {
                if (!entry || typeof entry.syncedLyrics !== "string") continue;
                const score = root.scoreSong(title, artist, album, length, saneLength,
                    entry.trackName, entry.artistName, entry.albumName, entry.duration);
                if (score > bestScore) { best = entry; bestScore = score; }
            }
            // A weak best match is a guess: prefer no lyrics over a wrong version
            if (best !== null && bestScore >= root.matchThreshold)
                parsed = root.parseLrc(best.syncedLyrics);
        } catch (e) { parsed = []; }
        root.finishFetch(parsed);
    }

    function finishFetch(parsed): void {
        root.lines = parsed;
        root.shownIndex = -1;
        root.preRolled = false;
        if (parsed.length > 0) {
            // Only a successful fetch caches the title (so a failed one is retried
            // on the next open); the window sizes itself to the visible lines
            root.fetchedTitle = root.fetchingTitle;
            root.fetchingTitle = "";
            root.noLyrics = false;
            root.fetchAttempts = 0;
            fetchRetryTimer.stop();
            fetchWatchdog.stop();
        } else if (root.fetchAttempts < 5) {
            // All sources came back empty: retry shortly instead of blanking the
            // window on a transient network/match failure. fetchLyrics resets this
            // budget on every new track.
            root.fetchAttempts++;
            fetchRetryTimer.restart();
        } else {
            root.giveUpNoLyrics();
        }
        root.normalizeRest(); // always render, so stale texts from a previous track never linger
        root.applyCurrent();
    }

    // Show a static placeholder after all retries came back empty, so the window
    // gives feedback instead of silently going blank
    function giveUpNoLyrics(): void {
        root.noLyrics = true;
        root.fetchingTitle = ""; // let a later signal for this song retry
        fetchWatchdog.stop();
    }

    // ---------------- parsing ----------------

    function parseJson(raw): var {
        try { return JSON.parse(String(raw ?? "").trim()); } catch (e) { return null; }
    }

    // QQ responses can come wrapped in a jsonp callback
    function parseQqLyrics(raw): var {
        let text = String(raw ?? "").trim();
        const start = text.indexOf("{");
        const end = text.lastIndexOf("}");
        if (start < 0 || end < start) return [];
        return root.parseLrc(root.parseJson(text.slice(start, end + 1))?.lyric ?? "");
    }

    // Netease's lyric endpoint returns a JSON envelope with the synced lyric in
    // `lrc.lyric` (a plain LRC string). Some endpoints return a JSON-per-line
    // "rich" format instead; handle both.
    function parseNeteaseLyrics(raw): var {
        const text = String(raw ?? "").trim();
        if (text.startsWith("{")) {
            const obj = root.parseJson(text);
            const lyric = obj?.lrc?.lyric;
            if (typeof lyric === "string") {
                const parsed = root.parseLrc(lyric);
                if (parsed.length > 0) return parsed;
            }
            return [];
        }
        const rich = [];
        const lrc = [];
        for (const rawLine of text.split("\n")) {
            const line = rawLine.trim();
            if (!line) continue;
            if (line.startsWith("{")) {
                const entry = root.parseRichLine(line);
                if (entry) rich.push(entry);
            } else {
                const entries = root.parseLrcLine(line);
                for (const e of entries) lrc.push(e);
            }
        }
        if (lrc.length > 0) {
            lrc.sort((a, b) => a.time - b.time);
            return lrc;
        }
        rich.sort((a, b) => a.time - b.time);
        return rich;
    }

    function parseRichLine(line): var {
        const obj = root.parseJson(line);
        if (!obj || typeof obj.t !== "number") return null;
        const chars = obj.c;
        if (!Array.isArray(chars)) return null;
        let text = "";
        for (const c of chars) text += c.tx ?? "";
        text = text.trim();
        if (!text) return null;
        return { time: obj.t, text: text };
    }

    // Standard LRC: [mm:ss], [mm:ss.xx] or [mm:ss.xxx], possibly several tags per line
    function parseLrc(raw): var {
        const lines = [];
        for (const line of String(raw ?? "").split("\n"))
            for (const entry of root.parseLrcLine(line))
                lines.push(entry);
        lines.sort((a, b) => a.time - b.time);
        return lines;
    }

    function parseLrcLine(line): var {
        const entries = [];
        const timeRe = /\[(\d{1,2}):(\d{1,2})(?:[.:](\d{1,3}))?\]/g;
        const times = [];
        let match;
        while ((match = timeRe.exec(line)) !== null) {
            const fraction = match[3] ?? "";
            const millis = fraction ? parseInt((fraction + "000").slice(0, 3)) : 0;
            times.push(parseInt(match[1]) * 60000 + parseInt(match[2]) * 1000 + millis);
        }
        if (times.length === 0) return entries;
        const text = line.replace(timeRe, "").trim();
        if (!text) return entries;
        for (const time of times) entries.push({ time: time, text: text });
        return entries;
    }

    // ---------------- adaptive background sampling ----------------

    // Periodically captures the screen behind the lyrics window, takes the median
    // color (robust against the lyrics text itself) and picks high-contrast colors
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
        // Sample the background behind the visible text rather than the whole window:
        // the window can be far wider than a short line (long credit lines size it),
        // so a small bright patch under the text would be drowned out by dark
        // wallpaper on either side of the wide span.
        const textWidth = Math.max(currentLine ? currentLine.width : 0, nextLine ? nextLine.width : 0);
        const sampleW = textWidth > 0 ? textWidth : lyricsWindow.width;
        const cx = lyricsWindow.margins.left + lyricsWindow.width / 2;
        // Clip the sample region to the on-screen part: wayland fills the area
        // beyond the screen with black, which would drag the median (and the text
        // colors) dark while the window is partly dragged off-screen
        const left = Math.max(screen.x, Math.round(cx - sampleW / 2));
        const top = Math.max(screen.y, Math.round(screen.y + lyricsWindow.margins.top));
        const right = Math.min(screen.x + screen.width, left + Math.round(sampleW));
        const bottom = Math.min(screen.y + screen.height, top + Math.round(lyricsWindow.implicitHeight));
        const w = right - left;
        const h = bottom - top;
        if (w <= 0 || h <= 0) return; // fully off-screen: keep the last colors
        const geom = Math.round(left) + "," + Math.round(top) + " " + Math.round(w) + "x" + Math.round(h);
        // grim captures the region in logical coordinates; python prints the per-channel
        // median of the top row (current line) and the bottom row (next line) separately
        bgSampleProc.command = ["sh", "-c",
            "grim -g \"$1\" - | python3 -W ignore -c \"import sys,PIL.Image as I,io; im=I.open(io.BytesIO(sys.stdin.buffer.read())).convert('RGB'); d=list(im.getdata()); n=len(d); t=d[:n//2]; b=d[n//2:]; print(*(sorted(p[i] for p in t)[len(t)//2] for i in range(3)), *(sorted(p[i] for p in b)[len(b)//2] for i in range(3)))\"",
            "sh", geom];
        bgSampleProc.running = false;
        bgSampleProc.running = true;
    }

    function onBgSampleDone(out): void {
        bgSampleProc.running = false; // stop the sampler from auto-restarting into a busy loop
        const parts = String(out).trim().split(/[\s,]+/);
        const v = parts.slice(0, 6).map(parseFloat);
        if (v.length < 6 || v.some(x => isNaN(x))) return;
        root.updateColors(
            Qt.rgba(v[0] / 255, v[1] / 255, v[2] / 255, 1),
            Qt.rgba(v[3] / 255, v[4] / 255, v[5] / 255, 1));
    }

    // Pick high-contrast colors from the sampled background: the highlighted line uses
    // the complementary hue (background blue -> accent orange, background green -> red...)
    // with a brightness that opposes the background, the upcoming line flips between
    // near-black and near-white based on background brightness rather than inverting,
    // so gray backgrounds stay readable
    property bool bgIsDark: true // hysteresis state for the dark/light flip
    property bool hasBgSample: false
    property var lastAppliedBg: null // the background color the display is derived from
    property var pendingBg: null // first sighting of a different color
    property bool nextIsDark: true // hysteresis state for the next line's dark/light flip
    property bool hasNextSample: false

    function colorClose(a, b): bool {
        return (Math.abs(a.r - b.r) + Math.abs(a.g - b.g) + Math.abs(a.b - b.b)) / 3 < 0.15;
    }

    function updateColors(bg, bgNext): void {
        // The dark/light classification follows the latest sample directly (with a
        // hysteresis dead-zone), so contrast recovers on the next sample even while
        // the color below the window keeps changing (dragging, animated wallpaper).
        // It must not ride on the debounced color below, or the classification gets
        // stuck on the old background whenever consecutive samples keep disagreeing.
        if (root.hasBgSample) {
            if (root.bgIsDark && bg.hslLightness > 0.62) root.bgIsDark = false;
            else if (!root.bgIsDark && bg.hslLightness < 0.38) root.bgIsDark = true;
        } else {
            root.bgIsDark = bg.hslLightness < 0.5;
            root.hasBgSample = true;
        }
        const dark = root.bgIsDark;

        // The accent hue stays debounced: only adopt a new background color when two
        // consecutive samples agree on it. When the window sits between two
        // alternating wallpaper colors, the complementary hue stays put instead of
        // flipping back and forth.
        const applied = root.lastAppliedBg;
        if (applied === null) {
            root.lastAppliedBg = bg;
        } else if (root.colorClose(bg, applied)) {
            root.pendingBg = null; // sample matches what is currently shown
        } else if (root.pendingBg !== null && root.colorClose(root.pendingBg, bg)) {
            root.lastAppliedBg = bg; // second consecutive sample of the new color
            root.pendingBg = null;
        } else {
            root.pendingBg = bg; // first sighting of a different color
        }

        const base = root.lastAppliedBg;
        // Achromatic backgrounds (grays) have a meaningless hue: QColor reports a
        // fixed 240 for them, so the "complement" becomes an arbitrary green. Only
        // saturated backgrounds get the complementary hue; grays fall back to the
        // theme accent hue instead.
        const hue = base.hslSaturation < 0.15
            ? Qt.color(Appearance.colors.colPrimary).hslHue
            : (base.hslHue + 0.5) % 1.0;
        // Moderate lightness (not the extreme ends) so the accent stays readable even
        // when the background under the text is a mixed light/dark gradient
        root.currentLineColorBottom = Qt.hsla(hue, 0.9, dark ? 0.58 : 0.42, 1);

        // The upcoming line follows the background behind its own row (bgNext), with
        // the same hysteresis so it flips cleanly between black and white
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

    // ---------------- display ----------------

    // The window keeps a *constant* width (a fixed slot as wide as the screen)
    // instead of hugging the text. Resizing a layer-shell surface needs a
    // compositor round-trip, and the surface size and the horizontal margin end
    // up committed in different frames, so any width change makes the centered
    // text jump sideways for a frame (the shaking seen on every line change).
    // With a fixed width and a fixed margin the text can never move horizontally.
    // The window mask (see lyricsWindow) limits the clickable area to the two
    // text lines, so the wide transparent band does not block windows behind it.
    property real lyricSlotWidth: (lyricsWindow && lyricsWindow.screen) ? lyricsWindow.screen.width : 1280
    property real rowHeight: (currentLine ? currentLine.height : 0) + root.lyricSpacing
    // Fixed margin: the slot is centered on the screen once and never moves again
    property real centeredLeft: Math.max(0, Math.floor((((lyricsWindow && lyricsWindow.screen) ? lyricsWindow.screen.width : 0) - root.lyricSlotWidth) / 2))
    // Lyric text sizes: a bit larger than the regular reading sizes
    property real currentLineSize: 24
    property real nextLineSize: 20
    // The upcoming line renders at the big size and is visually shrunk with scale, so
    // scrolling can grow it with a smooth transform instead of re-rasterizing the font
    property real nextLineScale: root.nextLineSize / root.currentLineSize
    // Adaptive contrast colors: refreshed from the screen behind the lyrics window
    // while the lyrics are open (see sampleBackground/updateColors below)
    property color currentLineColorBottom: Qt.hsla(Qt.color(Appearance.colors.colPrimary).hslHue, 0.9, 0.5, 1)
    property color nextLineColor: Qt.hsla(0, 0, 0.75, 1)
    // Pre-roll the line transition by this many ms: the 400ms scroll plus the
    // position poll would otherwise land the next line a beat late. Tunable:
    // raise it if lines still feel late, lower it if they feel early.
    property int scrollLead: 500
    // True while a pre-rolled transition is waiting for the position to catch up
    property bool preRolled: false
    // Last seen position (ms); a big backward jump while pre-rolled means a seek
    property real lastPositionMs: -1

    function lineIndexAt(positionMs): int {
        // Full scan: correct even if a source ever returns lines out of order
        let index = -1;
        for (let i = 0; i < root.lines.length; ++i) {
            if (root.lines[i].time <= positionMs)
                index = i;
        }
        return index;
    }

    // Position timer: scroll up on normal advances, jump on seeks. Gated on
    // lyricsOpen: the position signal keeps firing while the window is closed,
    // and without this guard a stale advance() would re-render the hidden lyrics.
    // The transition is pre-rolled: the scroll starts `scrollLead` ms before the
    // next line's timestamp, so the line lands at the top around the moment its
    // lyrics start instead of a beat late.
    function advance(): void {
        if (!GlobalStates.lyricsOpen) return;
        if (!root.activePlayer) return;
        const positionMs = root.activePlayer.position * 1000;
        const index = root.lineIndexAt(positionMs);
        // A big backward jump while waiting for a pre-rolled line means the user
        // seeked back: abandon the pre-roll and snap to the actual line.
        if (root.preRolled && positionMs < root.lastPositionMs - 250) {
            root.preRolled = false;
            root.lastPositionMs = positionMs;
            root.resetLines(index);
            return;
        }
        root.lastPositionMs = positionMs;
        if (index === root.shownIndex) {
            // Line unchanged; start the next transition early if its start is near
            if (root.preRolled) {
                root.preRolled = false; // position caught up to the pre-rolled line
            } else if (index >= 0 && index + 1 < root.lines.length) {
                const nextTime = root.lines[index + 1].time;
                if (positionMs >= nextTime - root.scrollLead) {
                    root.preRolled = true;
                    root.showIndex(index + 1);
                }
            }
            return;
        }
        // Waiting for the position to catch up to a pre-rolled line
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

    // Jump straight to line `i` (opening, track change, seek)
    function resetLines(i): void {
        if (i === root.shownIndex) return;
        root.shownIndex = i;
        root.preRolled = false;
        scrollAnim.stop();
        root.normalizeRest();
    }

    // Scroll up to line `i`: both lines slide up one row, and the incoming line
    // grows from the small size to the big size as it reaches the top
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

    // Bring the texts back to the rest layout (pixel-identical to the animated end state)
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

    // ---------------- dragging ----------------

    // Polls the global cursor position while dragging. The global position is
    // immune to the layer-surface move feedback loop, so the window tracks the
    // mouse exactly 1:1. The window must be keyboard-focusable (OnDemand) so
    // Hyprland keeps the pointer grab alive while a button is held even on a
    // workspace with no windows (otherwise it drops the grab on the first move
    // and sends a spurious release, killing the drag).
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
        // grabOffset is the cursor's offset within the window at press time, so the
        // window's center is the global cursor minus that offset plus half the width.
        // Anchoring the center keeps the text put as the width changes. No clamping:
        // the window may be dragged off-screen (reopening the lyrics recenters it)
        root.draggedCenterLeft = pos.x - (screen ? screen.x : 0) - root.grabOffset.x + lyricsWindow.width / 2;
        root.draggedTop = pos.y - (screen ? screen.y : 0) - root.grabOffset.y;
    }

    // ---------------- window ----------------

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

        // Constant width: never resized, so the surface size and the margin stay
        // fixed and the centered text cannot jump sideways (see lyricSlotWidth).
        implicitWidth: root.lyricSlotWidth
        // Two lines at the big size: the upcoming line grows to it while scrolling up
        implicitHeight: (currentLine ? currentLine.height : 0) + root.lyricSpacing + (currentLine ? currentLine.height : 0)

        Item {
            id: content
            width: parent.width
            height: parent.height

            // The highlighted line, colored with the adaptive accent color
            StyledText {
                id: currentLine
                anchors.horizontalCenter: parent.horizontalCenter
                horizontalAlignment: Text.AlignHCenter
                renderType: Text.QtRendering
                font.pixelSize: root.currentLineSize
                color: root.currentLineColorBottom
                // Blend smoothly as the sampled background changes
                Behavior on color { ColorAnimation { duration: 300 } }
            }
            StyledText {
                id: nextLine
                anchors.horizontalCenter: parent.horizontalCenter
                horizontalAlignment: Text.AlignHCenter
                renderType: Text.QtRendering
                font.pixelSize: root.currentLineSize
                transformOrigin: Item.Top
            }
        }

        // Only the two text lines are clickable (for dragging); the transparent
        // dead space of the fixed-width window passes clicks through to whatever
        // is underneath (media controls, bar, ...). The Region maps the items via
        // mapToScene, so the mask follows the text as it scrolls.
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
            // The incoming line warms from the second-line color into the highlight
            // color while it slides up. Must be a ColorAnimation: NumberAnimation
            // converts colors to plain numbers for interpolation, which makes the
            // transition start from a dark/transparent value (a black flash)
            ColorAnimation {
                id: scrollColorAnim
                target: nextLine
                property: "color"
                duration: 400
                easing.type: Easing.OutCubic
            }
            onFinished: root.normalizeRest()
        }

        // The window hugs the text, so dragging anywhere on it moves the lyrics
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
                    cursorPollProc.running = true; // prime the first sample immediately
            }
            onReleased: (event) => {
                root.dragging = false;
            }
            onCanceled: (event) => {
                root.dragging = false;
            }
        }
    }
}
