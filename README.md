# omarchy-git-status

An [Omarchy](https://omarchy.org/) bar plugin that warns you when any git
repository under a set of watched folders has work pending to be
synchronized with its remote: uncommitted changes, untracked files, or
unpushed commits.

The bar shows a single git glyph, in your theme's foreground when
everything is clean and in the theme's urgent color when something is
pending. The popup lists the repositories that need attention — clicking
one opens lazygit there — and the watched folders themselves, which you add
and remove from inside the panel. There is no configuration file.

![preview](preview.png)

## Behavior

A repository is considered "pending" if any of the following is true:

- `git status --porcelain` is non-empty (uncommitted or untracked changes).
- The current branch has commits ahead of its configured upstream.
- The current branch has **no** upstream configured **and** `HEAD` is not
  reachable from any remote tracking ref. This catches the case where you
  pushed with `git push origin main` instead of `git push -u origin main`
  but everything is still on the remote — the script correctly treats
  that as synced.

## Install

```bash
omarchy plugin add https://github.com/santiagoei/omarchy-git-status.git --enable
```

Or, if you keep it in your dotfiles, symlink the checkout into the plugins
directory and rescan:

```bash
ln -sfn ~/code/omarchy-git-status ~/.config/omarchy/plugins/ei.git-status
omarchy-shell shell rescanPlugins
omarchy plugin enable ei.git-status right
```

Dependencies: `git`, `jq`, `find`, coreutils (`sort`, `head`, `timeout`),
and `lazygit` for the row click — all present on a stock Omarchy. They are
resolved once from a pinned `PATH` (`/usr/bin:/bin`) and called by absolute
path, so nothing earlier in your own `PATH` gets to stand in for them.

## Configuration

Watched folders are managed from the panel itself: type a path into the
field at the bottom to add one, click the `×` on a folder to stop watching
it. Each folder shows how many repositories it holds and how many of them
are pending, so a typo shows up as "does not exist" on its own row.
A pattern with `*` or `?` — `~/Projects/*`, say — is a bulk add: every
folder it matches is stored exactly as if you had typed it itself, each
with its own row and its own `×`. Patterns expand once, at add time; a
folder created later needs one more pass.

Everything is stored in the widget's entry in `~/.config/omarchy/shell.json`
and is also editable from the bar's widget settings UI:

| Key                  | Default  | What it does                                                      |
| -------------------- | -------- | ----------------------------------------------------------------- |
| `watchDirs`          | `~/code` | Comma-separated folders to scan. `~` expands to your home folder; `*` and `?` expand once, when added. |
| `maxDepth`           | `4`      | How deep to look for `.git` directories under each folder.        |
| `refreshIntervalSec` | `60`     | Seconds between scans.                                            |

```json
{ "id": "ei.git-status", "watchDirs": "~/code, ~/work", "maxDepth": 3 }
```

## Interactions

| Input        | Action                             |
| ------------ | ---------------------------------- |
| Left click   | Open the popup                     |
| Right click  | Rescan now                         |
| `↑` / `↓`    | Move between pending repositories  |
| `Enter`      | Open lazygit for that repository   |
| `r`          | Rescan                             |
| `Esc`        | Close                              |
| Type + `↵`   | Add a watched folder               |
| `×`          | Stop watching that folder          |

IPC, for scripts and keybinds:

```bash
omarchy-shell ei.git-status toggle
omarchy-shell ei.git-status refresh
omarchy-shell ei.git-status status         # -> "4 repos pending"
omarchy-shell ei.git-status watch '~/work'
omarchy-shell ei.git-status watch '~/Projects/*'   # bulk add: one entry per match
omarchy-shell ei.git-status unwatch '~/work'
```

## How it works

`core/git-status.sh` takes a depth and a list of folders, walks every
`.git` directory below them, and runs cheap **local** git commands per
repository — no network, no auth:

```bash
git -C <repo> --no-optional-locks -c core.fsmonitor= status --porcelain
git -C <repo> --no-optional-locks -c core.fsmonitor= rev-list --count '@{u}..HEAD'
git -C <repo> --no-optional-locks -c core.fsmonitor= branch -r --contains HEAD
```

`--no-optional-locks` keeps the scan from writing into repositories it is
only looking at; `core.fsmonitor=` declines to run the hook a scanned
repository's own config asks for — a watched folder is not necessarily full
of your own code. Only the first 4 KiB of any git invocation is read.

It prints one JSON object on stdout:

```json
{
  "state": "unsynced",
  "scanned": 13,
  "pending": [
    { "name": "dotfiles", "path": "/home/me/code/dotfiles",
      "dir": "~/code", "issues": "uncommitted changes" }
  ],
  "watched": [
    { "path": "~/code", "state": "ok", "repos": 13, "pending": 1 }
  ]
}
```

### Limits

`watchDirs` is yours to point anywhere, so every ceiling below is hard.
Crossing one aborts the run and reports it — a half-finished scan that said
"synced" would be a lie, and the panel would paint it green:

```json
{ "state": "error", "error": "too many repositories in total (limit 500)",
  "scanned": 0, "pending": [], "watched": [] }
```

| Ceiling | Value |
|---|---|
| Watched folders per run   | 24              |
| Repositories per folder   | 200             |
| Repositories in total     | 500             |
| `maxDepth`                | clamped to 1–8  |
| Bytes read per git call   | 4 KiB           |
| Emitted JSON              | 512 KiB         |
| Wall clock for a whole scan | 20 s, and the panel wraps the script in `timeout 25s` |

The panel runs the script under `timeout`, which leads its own process
group, so the deadline's `TERM` reaches the `find` and `git` children too
rather than orphaning them. `core/supervise.sh` sits inside that group and
follows up with a `KILL` to it five seconds later; sending it from inside
keeps the group id from being recycled onto an unrelated process group
before it lands.

`Panel.qml` schedules that script and draws the result. The script is
standalone, so it also works from any other status bar — point the bar's
exec at `core/git-status.sh 4 ~/code` and parse the JSON.

`./core/git-status.test.sh` builds throwaway repositories for each branch of
that decision — no remote, pushed without `-u`, ahead of upstream, untracked
files, a missing folder — and asserts the verdict and the per-folder counts,
plus that a hijacked `PATH` is ignored, that each ceiling is rejected, and
that a straggler which ignores `TERM` is still killed after an abort.

`./core/panel-logic.test.mjs` runs the QML's path round-trip under node:
it lifts the folder add/remove functions out of `Panel.qml` and asserts that
a displayed `~/Projects` removes a stored `/home/ei/Projects`, that a glob
hands its pattern to the resolver instead of the list, and that a batch
crossing the folder cap is refused whole.

## Notes

- **Scan cost.** Each tick runs `git status` and `git rev-list` once per
  repository. Local and cheap, but a very large `watchDirs` with a deep
  `maxDepth` costs more; raise `refreshIntervalSec` if you notice it.
- **Untracked files count.** `git status --porcelain` reports untracked
  files, so a brand-new file in any watched repo turns the icon urgent.
- **Current branch only.** A side branch with unpushed commits does not
  trigger the indicator if the checked-out branch is clean.

## Credits

Maintained fork of
[igarag/omarchy-git-status](https://github.com/igarag/omarchy-git-status),
originally published under the plugin id `nachoaz.git-status`. The
canonical upstream for the design and the original scan script stays with
igarag; this fork carries the path-round-trip fix, glob bulk-add, the
folder cap raised to 24, and the panel logic tests.

## License

[MIT](./LICENSE).
