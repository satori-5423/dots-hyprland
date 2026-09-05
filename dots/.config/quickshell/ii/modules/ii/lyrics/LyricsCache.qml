import QtQuick
import Quickshell
import Quickshell.Io
import qs
import qs.modules.common
import qs.modules.common.functions

Item {
    id: root
    readonly property string directory: FileUtils.trimFileProtocol(`${Directories.cache}/lyrics`)
    signal hit(var lines)

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

    function lookup(context): bool {
        const wanted = root.key(context);
        lookupFile.path = root.filePath(context);
        lookupFile.expectedKey = wanted;
        lookupFile.reload();
        return false;
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
                if (record?.key === lookupFile.expectedKey && Array.isArray(record.lines)) root.hit(record.lines);
            } catch (e) {}
        }
    }

    FileView {
        id: saveFile
        property string pendingText: ""
    }
}
