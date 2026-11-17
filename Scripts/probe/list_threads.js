// Stock macOS JXA + sqlite3. No hooks, settings changes, transcript reads or writes.
ObjC.import('Foundation');
const fm = $.NSFileManager.defaultManager;
function warning(message) { console.log(message); }
function exists(path) { return Boolean(fm.fileExistsAtPath(path)); }
function readJSON(path) {
    try {
        const text = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null);
        if (!text) throw Error('unreadable');
        return JSON.parse(ObjC.unwrap(text));
    } catch (_) {
        warning('claude: unreadable metadata skipped');
        return null;
    }
}
function timestamp(value, milliseconds) {
    if (typeof value !== 'number' || !Number.isFinite(value)) return null;
    const date = new Date(value * (milliseconds ? 1 : 1000));
    return Number.isFinite(date.getTime()) ? date.toISOString() : null;
}
function metadata(tool, name, project, activity, redact) {
    return {
        tool: tool,
        name: redact ? '[redacted]' : (typeof name === 'string' && name ? name : 'Untitled'),
        project: redact ? '[redacted]' : (typeof project === 'string' ? project : ''),
        state: 'unknown',
        last_activity: activity,
        state_source: 'inventory'
    };
}
function claude(home, redact) {
    const root = home + '/Library/Application Support/Claude/claude-code-sessions';
    if (!exists(root)) return [];
    const enumerator = fm.enumeratorAtPath(root);
    if (!enumerator) {
        warning('claude: inventory unavailable');
        return [];
    }
    const paths = ObjC.deepUnwrap(enumerator.allObjects);
    return paths.filter(p => /(^|\/)local_[^/]+\.json$/.test(p)).map(p => readJSON(root + '/' + p))
        .filter(d => d && typeof d === 'object' && !Array.isArray(d) && !d.isArchived)
        .map(d => metadata('claude-code', d.title, d.cwd, timestamp(d.lastActivityAt, true), redact));
}
function codex(home, redact) {
    const path = home + '/.codex/state_5.sqlite';
    if (!exists(path)) return [];
    try {
        const task = $.NSTask.alloc.init;
        const output = $.NSPipe.pipe;
        const errors = $.NSPipe.pipe;
        task.launchPath = '/usr/bin/sqlite3';
        // No timestamps imply live state; user inventory excludes delegated agents.
        task.arguments = ['-readonly', '-json', path,
            "SELECT name,cwd,updated_at FROM threads WHERE archived=0 " +
            "AND COALESCE(thread_source,'') NOT IN ('subagent','guardian_review') " +
            "AND COALESCE(source,'') NOT LIKE '%\"subagent\"%' ORDER BY updated_at DESC"];
        task.standardOutput = output;
        task.standardError = errors;
        task.launch;
        const data = output.fileHandleForReading.readDataToEndOfFile;
        task.waitUntilExit;
        if (task.terminationStatus !== 0) throw Error('sqlite');
        const text = ObjC.unwrap($.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding));
        const rows = text.trim() ? JSON.parse(text) : [];
        return rows.map(d => metadata('codex', d.name, d.cwd, timestamp(d.updated_at, false), redact));
    } catch (_) {
        warning('codex: inventory unavailable (read-only SQLite/schema check failed)');
        return [];
    }
}
function run(args) {
    const redact = args.indexOf('--redact') !== -1;
    const homeAt = args.indexOf('--home');
    const home = homeAt === -1 ? ObjC.unwrap($.NSHomeDirectory()) : args[homeAt + 1];
    const valid = args.every((a, i) => a === '--redact' || a === '--home' || i === homeAt + 1 && homeAt !== -1);
    if (!valid || !home || home[0] !== '/') throw Error('Usage: list_threads [--home /absolute/fixture/home] [--redact]');
    const rows = claude(home, redact).concat(codex(home, redact));
    // osascript prints a newline for an empty return string; emit no result instead.
    return rows.length ? rows.map(r => JSON.stringify(r)).join('\n') : undefined;
}
