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

    function key(context): string {
        return JSON.stringify({
            title: String(context.title ?? ""),
            artist: String(context.artist ?? ""),
            album: String(context.album ?? ""),
            length: Number(context.length ?? 0),
            url: String(context.url ?? "")
        });
    }

    function filePath(context): string {
        const slug = `${context.title}-${context.artist}-${Math.round(Number(context.length ?? 0))}`
            .replace(/[^A-Za-z0-9_\u4e00-\u9fff.-]+/g, "_")
            .replace(/^\.+|\.+$/g, "")
            .slice(0, 180);
        return `${root.directory}/${slug || "track"}.json`;
    }

    // Starts an async lookup; the caller waits for either hit(key, lines) or
    // miss(key) before running a network fetch, so a cached track never triggers
    // a wasted request.
    function lookup(context): void {
        const wanted = root.key(context);
        lookupFile.path = root.filePath(context);
        lookupFile.expectedKey = wanted;
        lookupFile.reload();
    }

    function save(context, lines): void {
        saveFile.path = root.filePath(context);
        saveFile.pendingText = JSON.stringify({ key: root.key(context), lines: lines });
        mkdirProc.running = true;
    }

    Process {
        id: mkdirProc
        command: ["mkdir", "-p", root.directory]
        onExited: saveFile.setText(saveFile.pendingText)
    }

    FileView {
        id: lookupFile
        property string expectedKey: ""
        onLoaded: {
            try {
                const record = JSON.parse(lookupFile.text());
                if (record?.key === lookupFile.expectedKey && Array.isArray(record.lines))
                    root.hit(lookupFile.expectedKey, record.lines);
                else
                    root.miss(lookupFile.expectedKey);
            } catch (e) {
                root.miss(lookupFile.expectedKey);
            }
        }
        onLoadFailed: (error) => root.miss(lookupFile.expectedKey)
    }

    FileView {
        id: saveFile
        property string pendingText: ""
    }
}
