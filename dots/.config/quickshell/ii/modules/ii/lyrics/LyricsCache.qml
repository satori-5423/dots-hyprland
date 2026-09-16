import QtQuick
import Quickshell
import Quickshell.Io
import qs
import qs.modules.common
import qs.modules.common.functions

Item {
    id: root
    readonly property string directory: FileUtils.trimFileProtocol(`${Directories.cache}/lyrics`)
    signal hit(var key, var lines)
    signal miss(var key)

    // MPRIS length is not stable for one and the same track: browser players re-report
    // `mpris:length` while buffering (observed 233.940832 -> 233.94 -> 234.0), so it is
    // stored as metadata and matched with a tolerance, never compared for equality.
    readonly property real lengthTolerance: 6
    readonly property int maxEntriesPerFile: 12

    // Records already read from disk (keyed by path) so a save can merge into them
    // instead of throwing away the other releases of the same song.
    property var records: ({})

    function norm(value): string {
        return String(value ?? "").toLowerCase().replace(/[\s\u3000]+/g, " ").trim();
    }

    // Identity of a cached song: only the fields that stay stable while it plays.
    // Album / length / url arrive late or drift, and used to make the lookup miss
    // while piling up one file per metadata variation.
    function key(context): string {
        return root.norm(context?.title) + "\u001f" + root.norm(context?.artist);
    }

    function filePath(context): string {
        const base = `${root.norm(context?.title)}-${root.norm(context?.artist)}`;
        const slug = base
            .replace(/[^A-Za-z0-9_\u4e00-\u9fff.-]+/g, "_")
            .replace(/^[_ .\-]+|[_ .\-]+$/g, "")
            .slice(0, 150);
        return `${root.directory}/${slug || "track"}.json`;
    }

    function entryFor(context, lines): var {
        return {
            title: String(context?.title ?? ""),
            artist: String(context?.artist ?? ""),
            album: String(context?.album ?? ""),
            length: Number(context?.length ?? 0),
            url: String(context?.url ?? ""),
            savedAt: Date.now(),
            lines: lines
        };
    }

    // Accepts the current `{entries: [...]}` layout as well as the legacy `{key, lines}` one.
    function parseRecord(text): var {
        let data = null;
        try { data = JSON.parse(String(text ?? "")); } catch (e) { data = null; }
        if (!data) return null;
        if (Array.isArray(data.entries))
            return {
                version: 2,
                title: String(data.title ?? ""),
                artist: String(data.artist ?? ""),
                entries: data.entries.filter(e => e && Array.isArray(e.lines) && e.lines.length > 0)
            };
        if (typeof data.key === "string" && Array.isArray(data.lines) && data.lines.length > 0) {
            let meta = null;
            try { meta = JSON.parse(data.key); } catch (e) { meta = null; }
            if (meta)
                return {
                    version: 2,
                    title: String(meta.title ?? ""),
                    artist: String(meta.artist ?? ""),
                    entries: [{
                        title: String(meta.title ?? ""),
                        artist: String(meta.artist ?? ""),
                        album: String(meta.album ?? ""),
                        length: Number(meta.length ?? 0),
                        url: String(meta.url ?? ""),
                        savedAt: 0,
                        lines: data.lines
                    }]
                };
        }
        return null;
    }

    // 0 means "not for this context": another album or a clearly different length is a
    // different release whose lyrics may differ, so those variants are kept apart.
    function entryScore(entry, context): real {
        const wantAlbum = root.norm(context?.album);
        const haveAlbum = root.norm(entry.album);
        if (wantAlbum !== "" && haveAlbum !== "" && wantAlbum !== haveAlbum) return 0;
        const wantLength = Number(context?.length ?? 0);
        const haveLength = Number(entry.length ?? 0);
        if (wantLength > 0 && haveLength > 0 && Math.abs(wantLength - haveLength) > root.lengthTolerance) return 0;
        // Same album wins, "both unknown" next, one-sided album knowledge last.
        let score = wantAlbum === haveAlbum ? (wantAlbum === "" ? 4 : 8) : 3;
        score += (wantLength > 0 && haveLength > 0) ? 6 : 1;
        return score;
    }

    function pickEntry(record, context): var {
        if (!record || !Array.isArray(record.entries)) return null;
        let best = null;
        let bestScore = 0;
        let bestSavedAt = -1;
        for (const entry of record.entries) {
            const score = root.entryScore(entry, context);
            if (score <= 0) continue;
            const savedAt = Number(entry.savedAt ?? 0);
            if (score > bestScore || (score === bestScore && savedAt > bestSavedAt)) {
                best = entry;
                bestScore = score;
                bestSavedAt = savedAt;
            }
        }
        return best;
    }

    function mergeInto(record, entry): var {
        const merged = {
            version: 2,
            title: record?.title || entry.title,
            artist: record?.artist || entry.artist,
            entries: record ? record.entries.slice() : []
        };
        let replaced = false;
        for (let i = 0; i < merged.entries.length; ++i) {
            const other = merged.entries[i];
            if (root.norm(other.album) === root.norm(entry.album)
                && Math.abs(Number(other.length ?? 0) - Number(entry.length ?? 0)) <= root.lengthTolerance) {
                merged.entries[i] = entry;
                replaced = true;
                break;
            }
        }
        if (!replaced) merged.entries.push(entry);
        if (merged.entries.length > root.maxEntriesPerFile)
            merged.entries = merged.entries.slice(merged.entries.length - root.maxEntriesPerFile);
        return merged;
    }

    function write(path, record): void {
        saveFile.path = path;
        saveFile.pendingText = JSON.stringify(record);
        mkdirProc.running = true;
    }

    // Async lookup; the caller waits for hit() or miss() before fetching.
    // FileView.reload() is a no-op while a load is already in flight, so requests are
    // queued and drained from the event loop instead of being dropped silently.
    function lookup(context): void {
        if (!context) return;
        root.pendingLookup = context;
        lookupKick.restart();
    }

    function runLookup(): void {
        // A reload can complete synchronously and re-enter lookup() before this loop
        // returns, so drain every queued request rather than handling just one.
        while (root.pendingLookup) {
            const context = root.pendingLookup;
            root.pendingLookup = null;
            lookupFile.pendingContext = context;
            lookupFile.path = root.filePath(context);
            lookupFile.reload();
        }
    }

    property var pendingLookup: null

    Timer {
        id: lookupKick
        interval: 0
        repeat: false
        onTriggered: root.runLookup()
    }

    function save(context, lines): void {
        if (!context || !Array.isArray(lines) || lines.length === 0) return;
        const path = root.filePath(context);
        const entry = root.entryFor(context, lines);
        const known = root.records[path];
        if (known) {
            root.records[path] = root.mergeInto(known, entry);
            root.write(path, root.records[path]);
            return;
        }
        // Not read in this session yet: read the file first so the other album/length
        // variants of the same song survive the merge.
        mergeFile.pendingPath = path;
        mergeFile.pendingEntry = entry;
        mergeFile.path = path;
        mergeFile.reload();
    }

    function commitSave(existing): void {
        const entry = mergeFile.pendingEntry;
        const path = mergeFile.pendingPath;
        mergeFile.pendingEntry = null;
        if (!entry || !path) return;
        root.records[path] = root.mergeInto(existing, entry);
        root.write(path, root.records[path]);
    }

    Process {
        id: mkdirProc
        command: ["mkdir", "-p", root.directory]
        onExited: saveFile.setText(saveFile.pendingText)
    }

    FileView {
        id: lookupFile
        property var pendingContext: null
        watchChanges: false
        onLoaded: {
            const context = lookupFile.pendingContext;
            if (!context) return;
            const record = root.parseRecord(lookupFile.text());
            if (record) root.records[root.filePath(context)] = record;
            const entry = root.pickEntry(record, context);
            if (entry) root.hit(root.key(context), entry.lines);
            else root.miss(root.key(context));
        }
        onLoadFailed: (error) => {
            if (!lookupFile.pendingContext) return;
            root.miss(root.key(lookupFile.pendingContext));
        }
    }

    FileView {
        id: mergeFile
        property string pendingPath: ""
        property var pendingEntry: null
        watchChanges: false
        onLoaded: root.commitSave(root.parseRecord(mergeFile.text()))
        onLoadFailed: (error) => root.commitSave(null)
    }

    FileView {
        id: saveFile
        property string pendingText: ""
    }
}
