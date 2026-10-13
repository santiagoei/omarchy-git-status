// Unit tests for the path round-trip inside Panel.qml.
//
// The functions that decide which watched folder the menu's stop-watching
// removes are pure JavaScript over strings, so they are extracted from the QML at test time and
// run under node. This is the safety net the first release lacked: the panel
// displays `~/Projects` while shell.json may store `/home/ei/Projects`, and
// comparing the two without canonicalising them silently broke every removal.
//
//   node core/panel-logic.test.mjs

import fs from "node:fs";

const panel = fs.readFileSync(new URL("../Panel.qml", import.meta.url), "utf8");

function extract(name) {
  const at = panel.indexOf(`function ${name}(`);
  if (at === -1) throw new Error(`Panel.qml has no ${name}()`);
  let depth = 0, j = panel.indexOf("{", at);
  for (; j < panel.length; j++) {
    if (panel[j] === "{") depth++;
    else if (panel[j] === "}") { depth--; if (depth === 0) break; }
  }
  return panel.slice(at, j + 1);
}

const names = ["canonDir", "displayDir", "dirArgs", "addDir", "removeDir", "globDirs", "addDirs"];
const source = names.map(extract).join("\n");

// The QML scope the functions were lifted out of: injected properties become
// bindings, persistDirs and the glob Process become recorders. maxWatchDirs is
// the panel's own cap, not node's.
const build = new Function("maxWatchDirs", `
  let homeDir = "/home/ei", watchDirs = "", lastError = "";
  const glob = { command: null, running: false };
  const calls = [];
  function persistDirs(dirs) { calls.push(dirs.slice()); }
  ${source}
  return {
    set: (w, h) => { watchDirs = w; homeDir = (h === undefined ? "/home/ei" : h); },
    calls, error: () => lastError, glob,
    addDir, removeDir, addDirs, globDirs, canonDir, displayDir, dirArgs,
  };
`);

let fails = 0;
function check(label, got, want) {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  if (!ok) { fails++; console.log("FAIL", label, "\n  got ", JSON.stringify(got), "\n  want", JSON.stringify(want)); }
  else console.log("ok  ", label);
}
function run(wd, fn, home) {
  const p = build(24);
  p.set(wd, home);
  fn(p);
  return p;
}
const persisted = p => p.calls.length ? p.calls[p.calls.length - 1] : null;

// --- removeDir: the bug this file exists for ---------------------------------
const user = "/home/ei/Projects/icampus, /mnt/data/notes, /home/ei/Documents/La 60, /home/ei/Projects, /home/ei/Projects/*";
const minusProjects = ["/home/ei/Projects/icampus", "/mnt/data/notes", "/home/ei/Documents/La 60", "/home/ei/Projects/*"];

check("the x button: display ~/ against a stored absolute",
  persisted(run(user, p => p.removeDir("~/Projects"))), minusProjects);
check("and the stored absolute itself",
  persisted(run(user, p => p.removeDir("/home/ei/Projects"))), minusProjects);
check("~/code when stored /home/ei/code/ (trailing slash)",
  persisted(run("/home/ei/code/", p => p.removeDir("~/code"))), []);
check("bare ~ against the home folder itself",
  persisted(run("/home/ei", p => p.removeDir("~"))), []);
check("an unknown folder persists nothing at all",
  persisted(run("~/code", p => p.removeDir("~/nope"))), null);

// --- addDir single path -------------------------------------------------------
check("a new absolute is stored in the displayed ~ form",
  persisted(run("~/code", p => p.addDir("/home/ei/work"))), ["~/code", "~/work"]);
check("a duplicate across forms is ignored",
  persisted(run("/home/ei/code", p => p.addDir("~/code/"))), null);
check("a folder outside home stays absolute, trimmed",
  persisted(run("~/code", p => p.addDir("  /mnt/x/  "))), ["~/code", "/mnt/x"]);
check("empty input persists nothing",
  persisted(run("~/code", p => p.addDir("  /  "))), null);

// --- addDir glob branch -------------------------------------------------------
const globbed = run("~/code", p => p.addDir("~/Projects/*"));
check("a pattern goes to the resolver, not straight to the list",
  [globbed.glob.running, globbed.glob.command[4], persisted(globbed)],
  [true, "/home/ei/Projects/*", null]);
check("resolved matches merge after the stored list, dedupe, and persist in ~ form",
  persisted(run("/home/ei/Projects/icampus, ~/code",
    p => p.addDirs(["/home/ei/Projects/icampus", "/home/ei/Projects/BLSrubin", "  /mnt/data/notes/ "]))),
  ["/home/ei/Projects/icampus", "~/code", "~/Projects/BLSrubin", "/mnt/data/notes"]);
check("globDirs keeps paths verbatim and drops empty lines",
  run("", p => p.globDirs("/a\n/b\n\nc \n")).globDirs("/a\n/b\n\nc \n"),
  ["/a", "/b", "c "]);
const capped = run(Array.from({ length: 24 }, (_, i) => `/d${i}`).join(", "),
  p => p.addDirs(["/d24", "/d25"]));
check("a batch crossing the cap is refused whole, with the reason on screen",
  [persisted(capped), capped.error()],
  [null, "too many watched folders (limit 24)"]);

// --- degenerate environments --------------------------------------------------
check("no HOME: ~ is just a character, stored and matched verbatim",
  persisted(run("~/code", p => p.removeDir("~/code"), "")), []);

console.log(fails ? fails + " FAILURES" : "all checks passed");
process.exit(fails ? 1 : 0);
