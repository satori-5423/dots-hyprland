pragma ComponentBehavior: Bound

import QtQuick

QtObject {
    id: root

    function cleanTrackTitle(raw): string { return String(raw ?? "").trim(); }
    function cleanArtist(raw): string { return String(raw ?? "").trim(); }

    function parseJson(raw): var {
        try { return JSON.parse(String(raw ?? "").trim()); } catch (e) { return null; }
    }

    function parseLrc(raw): var {
        const lines = [];
        for (const line of String(raw ?? "").split("\n"))
            for (const entry of root.parseLrcLine(line)) lines.push(entry);
        lines.sort((a, b) => a.time - b.time);
        return lines;
    }

    function parseQqLyrics(raw): var {
        const text = String(raw ?? "").trim();
        const start = text.indexOf("{");
        const end = text.lastIndexOf("}");
        if (start < 0 || end < start) return [];
        const lyric = root.parseJson(text.slice(start, end + 1))?.lyric ?? "";
        let lines = root.parseLrc(lyric);
        if (lines.length > 0) return lines;
        // Try base64 only when the lyric field is actually Base64.
        if (root.isBase64(lyric)) {
            try {
                lines = root.parseLrc(root.base64Decode(lyric));
            } catch (e) {
                lines = [];
            }
        }
        return lines;
    }

    // Base64 lyric: no "[mm:ss]" markers, only base64 chars/padding.
    function isBase64(s): bool {
        const v = String(s ?? "").trim();
        return v.length >= 4
            && !v.includes("[")
            && /^[A-Za-z0-9+/]*={0,2}$/.test(v);
    }

    // Decode Base64 to UTF-8; "" when no decoder is available.
    function base64Decode(s): string {
        const b64 = String(s ?? "").trim();
        const raw = typeof atob === "function" ? atob
            : typeof Qt.atob === "function" ? Qt.atob : null;
        if (!raw) return "";
        const binary = raw(b64);
        try {
            return decodeURIComponent(escape(binary));
        } catch (e) {
            return binary;
        }
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

    function parseRichLine(line): var {
        const obj = root.parseJson(line);
        if (!obj || typeof obj.t !== "number" || !Array.isArray(obj.c)) return null;
        let text = "";
        for (const character of obj.c) text += character.tx ?? "";
        text = text.trim();
        return text ? { time: obj.t, text: text } : null;
    }

    function parseNeteaseLyrics(raw): var {
        const text = String(raw ?? "").trim();
        if (text.startsWith("{")) {
            const obj = root.parseJson(text);
            const lyric = obj?.lrc?.lyric;
            return typeof lyric === "string" ? root.parseNeteaseLyricBody(lyric) : [];
        }
        return root.parseNeteaseLyricBody(text);
    }

    function parseNeteaseLyricBody(text): var {
        const rich = [];
        const lrc = [];
        for (const rawLine of String(text).split("\n")) {
            const line = rawLine.trim();
            if (!line) continue;
            if (line.startsWith("{")) {
                const entry = root.parseRichLine(line);
                if (entry) rich.push(entry);
            } else {
                for (const entry of root.parseLrcLine(line)) lrc.push(entry);
            }
        }
        if (lrc.length > 0) {
            lrc.sort((a, b) => a.time - b.time);
            return lrc;
        }
        rich.sort((a, b) => a.time - b.time);
        return rich;
    }

    function latinTokens(s): var {
        const out = [];
        const re = /[a-z0-9]{2,}/g;
        let match;
        while ((match = re.exec(String(s).toLowerCase())) !== null) out.push(match[0]);
        return out;
    }

    function cjkAgreement(a, b): real {
        const sa = String(a ?? "").toLowerCase();
        const sb = String(b ?? "").toLowerCase();
        if (!sa || !sb || sa.length !== sb.length || sa.length < 2) return 0;
        let cjk = 0, same = 0;
        for (let i = 0; i < sa.length; ++i) {
            const ca = sa[i], cb = sb[i];
            if (/[\u4e00-\u9fff]/.test(ca) || /[\u4e00-\u9fff]/.test(cb)) {
                cjk++;
                if (ca === cb) same++;
            }
        }
        return cjk >= 2 ? same / cjk : 0;
    }

    function titleSimilarity(a, b): real {
        const compact = value => String(value ?? "").toLowerCase()
            .replace(/[\s\-_–—:：,.，。!?！？'"“”‘’()[\]（）【】]/g, "");
        const left = compact(a);
        const right = compact(b);
        if (!left || !right) return 0;
        if (left === right) return 1;
        const shorter = Math.min(left.length, right.length);
        const longer = Math.max(left.length, right.length);
        let positional = 0;
        if (left.length === right.length) {
            for (let i = 0; i < left.length; ++i)
                if (left[i] === right[i]) positional++;
            positional /= left.length;
        }
        const counts = value => {
            const result = {};
            for (const character of value) result[character] = (result[character] ?? 0) + 1;
            return result;
        };
        const leftCounts = counts(left);
        const rightCounts = counts(right);
        let overlap = 0;
        for (const character of Object.keys(leftCounts))
            overlap += Math.min(leftCounts[character], rightCounts[character] ?? 0);
        const dice = 2 * overlap / (left.length + right.length);
        const containment = shorter / longer;
        return left.length === right.length ? Math.max(positional, dice) : dice * containment;
    }

    function artistMatches(trackArtist, songArtists): bool {
        const track = root.cleanArtist(trackArtist).toLowerCase();
        if (!track) return false;
        const names = [];
        if (Array.isArray(songArtists)) {
            for (const artist of songArtists) {
                if (typeof artist === "string") names.push(artist);
                else if (artist && typeof artist.name === "string") names.push(artist.name);
            }
        } else names.push(String(songArtists ?? ""));
        const trackTokens = root.latinTokens(track);
        for (const name of names) {
            const candidate = root.cleanArtist(name).toLowerCase();
            if (!candidate || candidate.length < 2) continue;
            if (candidate === track || track.includes(candidate) || candidate.includes(track)) return true;
            if (root.cjkAgreement(track, candidate) >= 2 / 3) return true;
            if (trackTokens.length > 0 && root.latinTokens(candidate).some(t => trackTokens.includes(t))) return true;
        }
        return false;
    }

    function scoreSong(title, artist, album, length, saneLength, songTitle, songArtist, songAlbum, songDuration): number {
        let score = 0;
        const resultTitle = root.cleanTrackTitle(String(songTitle ?? "")).toLowerCase();
        const titleMatch = root.titleSimilarity(title, resultTitle);
        let matched = false;
        if (title) {
            if (titleMatch >= 0.88) { score += 80; matched = true; }
            else if (titleMatch >= 0.62) { score += 60; matched = true; }
            else if (titleMatch >= 0.45) { score += 35; matched = true; }
        }
        if (artist && root.artistMatches(artist, songArtist)) { score += 60; matched = true; }
        const resultAlbum = String(songAlbum ?? "").trim().toLowerCase();
        if (album && !album.startsWith("http") && resultAlbum === album) { score += 50; matched = true; }
        if (matched && saneLength && typeof songDuration === "number" && songDuration > 0 && length > 0) {
            const diff = Math.abs(songDuration - length);
            const tolerance = Math.max(5, length * 0.02);
            score += diff <= tolerance ? 90 : Math.max(0, 20 - (diff - tolerance) * 2);
        }
        return score;
    }
}
