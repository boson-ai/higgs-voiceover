/*
 * Higgs VoiceOver - the CEP build's side inside Premiere (ExtendScript, ES3).
 *
 * The panel calls HiggsVO.<name>(<JSON args>) through evalScript and gets
 * JSON back. Everything here is what UXP's premierepro module does for the
 * UXP build (src/host/uxp/premiere.ts), plus what UXP cannot do yet:
 * captions (Sequence.createCaptionTrack) and adding an audio track (QE DOM).
 *
 * ExtendScript has no JSON object; hvJson below writes the small results.
 * Times are seconds (Time.seconds); ExtendScript's own calls take seconds
 * as numbers.
 */

function hvJson(v) {
    var t = typeof v;
    if (v === null || v === undefined) return "null";
    if (t === "boolean") return v ? "true" : "false";
    if (t === "number") return isFinite(v) ? String(v) : "null";
    if (t === "string") {
        return '"' + v.replace(/[\\"\u0000-\u001f\u2028\u2029]/g, function (c) {
            var m = { "\\": "\\\\", '"': '\\"', "\n": "\\n", "\r": "\\r", "\t": "\\t" };
            if (m[c]) return m[c];
            var h = c.charCodeAt(0).toString(16);
            return "\\u" + "0000".substr(h.length) + h;
        }) + '"';
    }
    var out = [], k;
    if (v instanceof Array) {
        for (k = 0; k < v.length; k++) out.push(hvJson(v[k]));
        return "[" + out.join(",") + "]";
    }
    for (k in v) if (v.hasOwnProperty(k) && v[k] !== undefined) out.push(hvJson(String(k)) + ":" + hvJson(v[k]));
    return "{" + out.join(",") + "}";
}

var HiggsVO = (function () {
    var BIN_TYPE = 2, CLIP_TYPE = 1;   // ProjectItemType.BIN / CLIP

    function norm(p) { return String(p || "").replace(/\\/g, "/").toLowerCase(); }

    function findBin(name) {
        var root = app.project.rootItem;
        for (var i = 0; i < root.children.numItems; i++) {
            var c = root.children[i];
            if (c && c.type === BIN_TYPE && c.name === name) return c;
        }
        return null;
    }

    function ensureBin(name) {
        return findBin(name) || app.project.rootItem.createBin(name);
    }

    function findByPath(bin, path) {
        var want = norm(path);
        for (var i = 0; i < bin.children.numItems; i++) {
            var c = bin.children[i];
            if (c && c.type === CLIP_TYPE && norm(c.getMediaPath()) === want) return c;
        }
        return null;
    }

    /** Import what is not already in the bin; files are never imported twice. */
    function importInto(bin, paths) {
        var missing = [];
        for (var i = 0; i < paths.length; i++) if (!findByPath(bin, paths[i])) missing.push(paths[i]);
        if (missing.length > 0) app.project.importFiles(missing, true, bin, false);
        for (var j = 0; j < paths.length; j++) if (!findByPath(bin, paths[j])) return false;
        return true;
    }

    function findTrack(seq, name) {
        for (var i = 0; i < seq.audioTracks.numTracks; i++) {
            if (seq.audioTracks[i].name === name) return seq.audioTracks[i];
        }
        return null;
    }

    /**
     * There is no supported "add track": the QE DOM's addTracks is what
     * every panel uses. One stereo audio track after the last one; then it is
     * named, which recent versions allow on the track object.
     */
    function addTrack(seq, name) {
        var before = seq.audioTracks.numTracks;
        app.enableQE();
        var q = qe.project.getActiveSequence();
        // (video tracks, after video #, audio tracks, audio type 1 = stereo, after audio #, submixes, submix type)
        q.addTracks(0, 0, 1, 1, before, 0, 0);
        // DOM objects can go stale across a QE edit; read the sequence again.
        seq = app.project.activeSequence;
        if (seq.audioTracks.numTracks <= before) return null;
        var track = seq.audioTracks[seq.audioTracks.numTracks - 1];
        try { track.name = name; } catch (e) { /* older versions: the name stays Premiere's */ }
        return track;
    }

    function clips(track) {
        var out = [];
        for (var i = 0; i < track.clips.numItems; i++) {
            var c = track.clips[i];
            out.push({ start: c.start.seconds, end: c.end.seconds });
        }
        return out;
    }

    function guarded(fn) {
        return function (a) {
            try { return fn(a); } catch (e) {
                return hvJson({ ok: false, placed: 0, starts: [], ends: [], error: "Premiere stopped with an error: " + e.toString() + (e.line ? " (line " + e.line + ")" : "") });
            }
        };
    }

    var api = {
        info: function () {
            var p = app.project;
            var has = !!(p && p.activeSequence);
            return hvJson({
                project: p ? String(p.name).replace(/\.prproj$/i, "") : "",
                id: p ? String(p.documentID || p.path || p.name) : "",
                hasSequence: has,
                version: app.version
            });
        },

        importToBin: function (a) {
            if (!app.project) return hvJson({ ok: false, error: "No project is open." });
            var bin = ensureBin(a.bin);
            if (!bin) return hvJson({ ok: false, error: "Premiere would not make the \u201c" + a.bin + "\u201d bin." });
            return hvJson(importInto(bin, a.paths) ? { ok: true } : { ok: false, error: "Premiere would not import the clip." });
        },

        /** The open sequence's audio track names, A1 first. */
        tracks: function () {
            var seq = app.project && app.project.activeSequence, out = [];
            if (seq) for (var i = 0; i < seq.audioTracks.numTracks; i++) out.push(seq.audioTracks[i].name);
            return hvJson(out);
        },

        place: function (a) {
            var fail = function (why, fps) { return hvJson({ ok: false, placed: 0, starts: [], ends: [], pushed: false, fps: fps || 0, error: why }); };
            var seq = app.project && app.project.activeSequence;
            if (!seq) return fail("No sequence is open.");
            var frame = seq.getSettings().videoFrameRate.seconds || (1 / 24);
            var fps = 1 / frame;
            var bin = ensureBin(a.bin);
            var paths = [];
            for (var i = 0; i < a.takes.length; i++) paths.push(a.takes[i].path);
            if (!bin || !importInto(bin, paths)) return fail("Premiere would not import the clip.", fps);

            // A track by number (A1 = index 0), or the plugin's own track by name.
            var track, label;
            if (a.index !== null && a.index !== undefined) {
                if (a.index >= seq.audioTracks.numTracks) return fail("This sequence has no A" + (a.index + 1) + " track. Choose another track in Settings.", fps);
                track = seq.audioTracks[a.index];
            } else {
                track = findTrack(seq, a.track) || addTrack(seq, a.track);
                if (!track) return fail("Premiere would not add an audio track for \u201c" + a.track + "\u201d.", fps);
                seq = app.project.activeSequence;
            }
            for (var n = 0; n < seq.audioTracks.numTracks; n++) if (seq.audioTracks[n].id === track.id) label = "A" + (n + 1);
            label = label || a.track;
            if (track.isLocked && track.isLocked()) return fail(label + " is locked. Unlock it and place again.", fps);

            // The playhead, or after clips on the track that reach past it - nothing is overwritten.
            var playhead = Math.round(seq.getPlayerPosition().seconds / frame) * frame;
            var start = playhead, existing = clips(track);
            for (var k = 0; k < existing.length; k++) if (existing[k].end > start) start = existing[k].end;

            var at = start, plan = [];
            for (var t = 0; t < a.takes.length; t++) {
                var item = findByPath(bin, a.takes[t].path);
                if (!item) return fail("Premiere imported the clip but it is not in the bin.", fps);
                var seconds = a.takes[t].seconds;
                try { seconds = item.getOutPoint().seconds - item.getInPoint().seconds || seconds; } catch (e1) { /* keep ours */ }
                plan.push({ item: item, at: at });
                track.overwriteClip(item, at);
                at = Math.ceil((at + seconds) / frame - 1e-6) * frame;
            }

            // Trust the timeline, not the calls.
            var landed = clips(track), starts = [], ends = [];
            for (var p = 0; p < plan.length; p++) {
                var hit = null;
                for (var l = 0; l < landed.length; l++) if (Math.abs(landed[l].start - plan[p].at) < frame / 2) hit = landed[l];
                if (!hit) {
                    return hvJson({ ok: false, placed: starts.length, starts: starts, ends: ends, pushed: start > playhead + frame / 2, fps: fps,
                                    track: label, error: "Premiere did not place the clip on " + label + "." });
                }
                starts.push(hit.start);
                ends.push(hit.end);
            }
            return hvJson({ ok: true, placed: plan.length, starts: starts, ends: ends, pushed: start > playhead + frame / 2, fps: fps, track: label });
        },

        /** Native captions from an .srt, its time zero at `at` seconds in the sequence. */
        captions: function (a) {
            var seq = app.project && app.project.activeSequence;
            if (!seq) return hvJson({ ok: false, error: "No sequence is open." });
            var bin = ensureBin(a.bin);
            if (!bin || !importInto(bin, [a.srt])) return hvJson({ ok: false, error: "Premiere would not import the subtitles." });
            var item = findByPath(bin, a.srt);
            var before = seq.captionTracks ? seq.captionTracks.numTracks : -1;
            var made = seq.createCaptionTrack(item, a.at, Sequence.CAPTION_FORMAT_SUBTITLE);
            var after = seq.captionTracks ? seq.captionTracks.numTracks : -1;
            return hvJson(made || after > before ? { ok: true } : { ok: false, error: "Premiere did not make the captions." });
        }
    };
    for (var name in api) if (api.hasOwnProperty(name)) api[name] = guarded(api[name]);
    return api;
}());
