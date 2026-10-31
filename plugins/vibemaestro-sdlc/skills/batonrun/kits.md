# batonrun reference: kit batons

Read this when a kit refuses, when its `<launcher> list <name>` entry does not say enough for a call, for a kit of another
plugin, or to keep, change, move or retire a baton. Also printed by `<launcher> help kits`.

A kit baton is a baton script the plugin ships, named `kit:<name>` instead of a path; it is reviewed plugin code, so you do not
write it, you run it like any other (`go`, or the separate commands). Only a kit baton may run one of the plugin's gates, and its signature
binds the plugin version it was signed with. `kit:merge-pr` is the guarded merge (`gates/merge_guard.py --help` lists its
arguments):

    <launcher> go kit:merge-pr --repo <owner/name> --pr <n> --head <full sha> --brief <file> [guard options]

Rehearse is the guard's dry run: every condition with its verdict, and the plan line (`merge … head <sha> …`). The run hands
the guard the signed plan (`BATON_PLAN`), so a world that moved since signing is refused before anything merges. A PR the guard
refuses fails at rehearse and cannot be signed: fix the PR, never the guard's arguments to fit it. The header says `Stops: none`,
so in mode `auto` the session signs it. A merge is not reversible: when the run fails after
GitHub merged, `run` exits 5 and the way back is a revert PR, which the owner is told about at once. Accepted red steps
(`--accept '<check>:<step prefix>'`), base files that may stay behind (`--behind-ok <globs>`), an image that must exist
(`--require-image <tag>`) and the image-bump lane (`--image-bump`) are arguments, so the signature binds them.
`--behind-ok-clean <docs globs>` (each ends in `.md`, starts with a literal folder) also accepts a docs file main and the PR both changed, when git's 3-way merge and GitHub's test merge agree it is clean and a merged current-state still passes its check.

**A PR behind main: merge main only when the guard refuses.** Run `kit:merge-pr` with `--behind auto` (never beside
`--behind-ok` or `--behind-ok-clean`): the guard decides by itself. It accepts a behind PR when GitHub's test merge of the
base tip and the head is fresh and mergeable, every file main and the PR both changed is a docs file that merges clean, and
the suites main's files wake do not meet the suites CI ran for the PR (the repo's `merge.planner`, run from the base; with no
planner, main's files must all be docs). On `FAIL  behind` main is merged into the PR's branch and CI runs again; on
`??  behind` (a test merge still stale) rehearse again a minute later. Do not merge main into a queued PR before the guard has refused it: that
costs a full CI cycle for nothing.

`kit:gh-write` is for the small GitHub writes: open an issue, comment, edit your comment, an issue's title or body, a PR body,
reopen or close an issue, close a PR, mark a draft PR ready, open a PR from a pushed branch, propose one file as a PR. Do not
hand-write a baton for these; one of them alone (a comment, a ticket) is a simple write, made directly. Write one JSON spec (`gates/gh_write.py --help` gives the format)
with the Write tool to a fresh path and, in the same response, run:

    <launcher> go kit:gh-write --spec <file>

To post one comment, put the body inline:

    {"gh-write": 1, "ops": [{"op": "issue-comment", "repo": "<owner/name>", "issue": 59,
     "body": "…\n<!-- my-marker -->", "marker": "<!-- my-marker -->"}]}

To close an issue with a closing comment, one op (not an `issue-comment` and an `issue-close` on the same issue, which is refused):

    {"gh-write": 1, "ops": [{"op": "issue-close", "repo": "<owner/name>", "issue": 62, "reason": "completed",
     "comment": "…\n<!-- my-marker -->", "marker": "<!-- my-marker -->"}]}

The comment is posted before the close. Its undo retracts the comment and reopens the issue, only while both are as the run left them.

How it behaves:

- **Rehearse.** It reads every target and prints one plan line per op. Each line carries the spec's sha256, so the signature
  binds the spec and every body file pinned in it (`body_file` plus `sha256`).
- **Refusals at rehearse.** Each is named:
  - a repository that is not private, or is internal (`refuse-public`);
  - a deletion (`refuse-delete`);
  - a repository creation (`refuse-repo-create`);
  - an unknown kind or key;
  - a marker already present, so a second run of the same spec is refused;
  - a fence left open.
  - a closed issue or a closed or merged pull request, for a comment, an edit or a close; the one exception is an `issue-comment`
    with `"closed_ok": true`, which passes there and says so in its plan line.
- **Run.** A later op may target an issue created earlier in the spec (`"issue": "@<id>"`) and cite it in its body
  (`{{issue:<id>}}`). Its number comes from the create's own output, never from a list.
- **Post-check.** It reads every write back by number and compares it byte for byte. The engine handles the trailing
  newline once, so do not compare bodies yourself.
- **Undo.** It puts saved bodies back, closes created issues as not planned (and removes their marker), and retracts new
  comments by editing them. It never deletes. It leaves alone two things, and then the run ends with exit 5:
  - what someone changed after the run;
  - a write whose outcome is unknown and that a list does not show yet.
- **Recover.** A run that was interrupted, or whose undo failed, stays open, and its spec cannot be rehearsed again. Undo it
  with the same command plus `--recover` after the spec path (`go --reuse`, since the spec is older than 120 s); each undo
  step is one plan line. A step that must leave
  a state alone closes the run anyway and ends with rc 5: tell the owner what it left. When what it left is a write whose
  outcome is unknown, the spec stays refused until the owner has checked GitHub and moved that journal aside.

The pull-request ops pin what they act on:

- `pr-ready` (`pr`, `head`): the PR is open, a draft, and at that head; undo turns it back into a draft while it is still ready
  at that head.
- `pr-create` (`base`, `branch`, `head`, `title`, `draft`, a body): the branch is already pushed to the same repository and is at
  `head`, and no open PR from it into `base` exists. `draft` is required, so the plan line says `draft` or `ready`. Undo closes
  the PR while it is open, not merged and still at `head`.
- `file-pr` (`base`, `branch`, `path`, `content_file` with `content_sha256`, `title`, `draft`, a body): one file proposed
  without a clone, added, or replacing the regular file at that path on the base (it keeps that file's mode). The branch must
  not exist. The plan line names the base tip, what the path holds there (`replaces blob <sha> mode <mode>`, or `replaces
  none`) and the commit's author (the viewer's GitHub noreply address), so a base or file that moved after signing is
  refused. A directory, a link, a submodule, a path under a file, content equal to the file, and a path under
  `.github/workflows/` or `.github/actions/` (this op writes no workflow definition) are refused. The run makes one commit on
  that tip, then the branch, then the PR. Undo closes the PR. The branch stays, because this baton never deletes, so the undo
  names the branch and the run ends with exit 5; once the owner has deleted the branch, `--recover` closes the run.

Deletions (but a merged branch: `kit:branch-delete` below), public repositories and anything outside these kinds stay
hand-written batons, signed by the owner.

`kit:coordinator-bootstrap` sets up BatonRun on a machine (the launcher, the permission block, attribution off where a key is
absent) in one run the owner signs (`Stops: security-boundary`); it takes no argument. Follow the skill `coordinator-bootstrap`:
on a new machine there is no launcher yet, so it runs through the plugin's `baton.py`, and the owner types the signature.
A session whose sdlc is not the installed one (started before a plugin update) is refused at rehearse with one line naming both versions: restart Claude Code, then run it again.

`kit:permissions-upgrade` replaces the ask rules of the permission block printed before the anchored rules (each started with
`*`, so it asked for any command that only mentioned a sign or a mode call) in the user settings: it removes exactly those
patterns, adds the anchored rules that are absent, and changes no other rule or key. It takes no argument; `Stops:
security-boundary` (a permission change), so the owner signs. Its post-check is `permissions --check` with no rule finding; its
undo puts the file back byte for byte while it holds what the run wrote. A file with none of the old patterns is refused at
rehearse (`nothing to do`); an old pattern in another settings scope is named, and the owner removes it there. Its card says
the cost of this version: an owner in auto confirms the mode once more (one dialog) and trusts the remote list again.

`kit:branch-push` pushes one local branch as a new branch of its private GitHub repository. Run it from the clone:

    <launcher> go kit:branch-push --branch <name> --head <full sha> --repo <owner/name> [--remote <name>]

The remote's URL must name github.com/`--repo` over https or ssh; the kit then talks to that repository from a scratch
repository with no config of its own and none of the user's, reading the clone's objects. So nothing in the clone's config or
hooks (a `pushurl`, an `insteadOf` rule, `core.sshCommand`, a proxy, `push.followTags`, a hook) changes where the push goes
or runs during it. Its git calls also get an allowlisted environment (PATH, HOME, the locale, `SSH_AUTH_SOCK`, `GIT_SSH_COMMAND`,
gh's token variables, the proxy variables): no env-config, `GIT_EXEC_PATH` or CA file reaches them. Refused at rehearse:
- a remote that cannot be read;
- a repository that is public or internal;
- a local branch that is not at `--head`;
- a branch the remote already has;
- a commit the remote lacks that changes a path under `.github/workflows/` or `.github/actions/` (it would run with the
  repository's secrets: such a push is a hand-written baton the owner signs). The commits counted are those not reachable
  from a tip the remote advertises and the clone holds; in a clone whose last fetch is old, fetch first;
- a name git resolves first as another ref (HEAD, `*_HEAD`, `AUTO_MERGE`, `BISECT_EXPECTED_REV`, a first component `refs`,
  `heads`, `tags` or `remotes`, 40 hex).

At the push, its plan line must be in the signed plan. The push sends the pinned SHA create-only: it never moves a branch that
exists, even one that appeared since the check. A branch cannot be deleted here, so an undo after a landed push names the
branch, and the run ends with exit 5.

`kit:branch-delete` deletes one branch of a private GitHub repository at a pinned head that is merged into the default
branch, with no owner signature. Run it from a clone of the repository (its `origin` gives the transport, as `kit:branch-push`):

    <launcher> go kit:branch-delete repo='<owner/name>' branch='<name>' head='<full sha>'

`head` pins the branch: a branch whose tip is another SHA is refused, at rehearse and again when the run reads it. The base
is always the repository's default branch. Rehearse reads everything from GitHub (`--hostname github.com`), never from the
clone's refs: the branch's SHA and the default branch's SHA from the remote's own listing, and merged-ness from one of two
proofs. Ancestor: the compare API shows the head an ancestor of the default tip (a merge commit or a fast-forward). Its PR,
when that fails (a squash or a rebase merge): GitHub's own list of closed PRs from this repository's branch into the default
branch has a merged one whose head is the pinned SHA (nothing pushed after the merge), whose merge commit is on the default
tip (compare API), and whose `refs/pull/<n>/head` is at the SHA, so the branch's commits stay reachable after the delete;
candidates are tried from the lowest number up and the first that holds is used. The PR number is never an argument. A PR
merged into another base, a fork's PR and a branch pushed after its merge are refused and stay hand-written batons the owner
signs. The plan line names the branch, the head, the default branch, its SHA and the proof (`ancestor` or `merged PR #<n>`),
so the signature binds what was proven. Refused at rehearse:
- a branch that is not merged into the default branch, a SHA only another branch holds included (an unmerged branch is a
  hand-written baton the owner signs);
- a branch whose tip is not the pinned head;
- the default branch;
- a protected branch, one a repository ruleset forbids to delete, or one whose protection or rules cannot be read;
- a name that is also a tag, or that git resolves first as another ref (as `kit:branch-push`), or with a character outside
  letters, digits and `._/-`;
- an open pull request from the branch or into it (deleting a base closes its pull requests), or a list that cannot be read;
- a branch or default branch the remote does not have; a repository that is public or internal; an `origin` that names
  another repository.

The run reads it all again, so a branch that moved since signing is refused and a default branch that moved gives another
plan line: nothing is deleted. The delete is the plugin's gate `gates/branch_delete.py`, run inside `write()` as
`kit:merge-pr` runs its guard: it refuses a plan line that is not in the signed plan or names another branch, head or URL,
then pushes with a lease on the head (`--force-with-lease=refs/heads/<branch>:<sha>`), so GitHub refuses it if the branch
moved after that check. The post-check wants the branch gone and the same proof still holding (a default branch forced back,
or a pull ref moved, fails it). A run record says whether this run's delete landed; when it did, undo recreates the branch
at the pinned SHA through the API, and a branch there again at another SHA is left and named (exit 5). A push that fails
while the branch is gone (an answer lost, or someone else deleted it) is an unknown outcome: undo puts the branch back when
its proof no longer holds or a read of the proof fails, so no commit is lost, and leaves it for the owner (exit 5) when the
proof still holds, the record names no proof, or the repository no longer reads as private or cannot be listed; a branch there again at another
SHA is left and named (exit 5). Tags and unmerged branches stay
hand-written batons the owner signs.

`kit:plugin-update` updates every plugin of this machine's `vibemaestro` marketplace (user scope), through Claude Code's own
`claude plugin marketplace update` and `claude plugin update`, with no owner signature (`Stops: none`):
- `vibemaestro-sdlc` and `vibemaestro-brain` to kit main at one full SHA;
- each marketplace-local plugin, an entry whose source is `./plugins/<its name>`, to the marketplace's own main.

    <launcher> go kit:plugin-update <full kit sha>

The claude directory is `CLAUDE_CONFIG_DIR` when set (a relative one is refused), else `~/.claude`. The kit reads the
marketplace layout from the `vibemaestro` clone instead of assuming one, and knows two:
- the kit's own marketplace: both plugins at `./plugins/<name>`; the kit is the github.com repository that the known source
  and the clone's `origin` both name;
- a marketplace that lists both plugins as `{"source": "git-subdir", "url": "https://github.com/<owner>/<name>", "path":
  "plugins/<name>", "ref": "main"}` with one URL and nothing else; the kit is that repository.

In both, every other entry is a marketplace-local plugin: `{"name", "source": "./plugins/<name>", "description"}`, a name of
lower-case letters, digits, dots, dashes and underscores. Claude Code installs it from the clone's work tree, so the clone's
`plugins` directory and the plugin's directory must be real directories, not symlinks, and nothing under `.claude-plugin` or
the plugin's directory may differ from the clone's HEAD. Each file there is read and hashed against `git ls-tree` of HEAD,
with replace refs off, so neither the index's stat data nor a replace ref can hide a change: a changed or missing file, a file
HEAD lacks (untracked, ignored, a repository inside), a symlink or submodule in HEAD, and a directory that cannot be listed
are refused, and so is a filter in the clone's git config. This fails closed: a checkout that rewrites bytes (`eol=crlf`,
`ident`) is refused as well. The manifest itself carries only `$schema`, `name`, `owner`, `description`, `version`, `metadata`
(no `pluginRoot`) and `plugins`. The clone is checked again right before each local plugin's update. Its target is the marketplace's main M, which the kit reads from GitHub at each phase and pins in the plan line;
in the kit's own marketplace M is the kit SHA, and sdlc and brain are local too. M is not an argument: whatever is merged on
the marketplace's main is the owner's own, and the pinned plan line binds the exact commit as an argument would. A local plugin
with no user-scope install is named (`NOT INSTALLED`) and left alone; a plugin already at its target is skipped (`SKIP`).

The known source is `{source: github, repo}` or `{source: git, url}` naming a github.com repository (https or ssh),
at most with `ref: main`; each marketplace entry carries only `name`, `source` and `description`, since an entry can
add hooks, servers or a manifest of its own; the clone's config, as git reads it there (its worktree config too), gives
`origin` one URL, the known source's repository, with no URL rewrite and no include; its `.git` is a real directory. The
clone's own config sets no transport key either: no proxy (`remote.origin.proxy`, `http[.<url>].proxy`, `core.gitProxy`),
no `http[.<url>].curloptResolve`, no branch remote other than `origin`, no fetch refspec or branch merge ref onto another ref,
no `core.sshCommand`, no `http[.<url>].sslVerify` off. The owner's global and system git config and the proxy variables are the owner's own setup.

Refused at rehearse, nothing called:
- any other layout: a `directory` or `url` marketplace, a plugin missing, another ref, a pinned `sha`, an ssh or http URL
  in a `git-subdir` source, mixed sources, an entry with other keys, an entry that is neither sdlc or brain in the layout's
  shape nor a local plugin (another source kind, a source outside `./plugins/<its name>`), a known source with other keys or
  another ref;
- a layout that names no kit repository, or more than one, and a known source on another host;
- a clone whose origin is not the known source's repository, or whose git config has two origin URLs, a URL rewrite
  (`insteadOf`) or an include; a clone git does not trust (another owner, not in the owner's `safe.directory`), or whose
  `.git` git does not read as its repository;
- a fetch URL that a rewrite in the owner's global, XDG or system git config takes off the known source's repository
  (`git ls-remote --get-url origin`; a rewrite that stays on it, such as https to ssh, passes);
- a git variable that points git at another repository or config file (`GIT_DIR`, `GIT_CONFIG`, `GIT_CONFIG_PARAMETERS`,
  `GIT_CONFIG_COUNT`, …), even empty: Claude Code's git would not read the clone that was checked;
- a symlinked `plugins` or local plugin directory, or a clone tree that differs from its HEAD there;
- a SHA that is not kit main on GitHub now;
- sdlc or brain with no user-scope install or two, a local plugin with two, or every plugin already at its target
  (`REFUSE nothing to do`);
- a registry file that is a symlink, a relative `installLocation` or `CLAUDE_CONFIG_DIR`.

The plan lines name the layout, the kit, the SHA, the marketplace repository with the clone's HEAD and M, each plugin with its
old and new commit, and the sha256 of `installed_plugins.json` and `known_marketplaces.json`. Each write checks its own line
against the signed plan, so a world that moved since signing is refused at its line: when the marketplace's main moved after
the rehearse, the run stops at `REFUSE the line is not in the signed plan (…): plugin-update marketplace vibemaestro (…)`
before the marketplace update, and never installs the newer commit. The run first keeps byte copies of both files in a run
record, then updates the marketplace. That replaces the clone, so the next step of the plan checks it before any plugin
update: the same layout, kit and local plugins, kit main still the SHA, the marketplace's main still M, the clone at M with a
clean tree; any miss refuses the plugin updates. It never passes `-y`: a marketplace-declared command fails the run.

Kit main can still move between that read and a plugin update, since a `git-subdir` source at ref `main` fetches the newest
main. So the post-check reads the registry, and each plugin of the run (its record names them, with their targets) must hold:
- its user entry records `gitCommitSha` equal to its target;
- its version is the target's first 12 hex, alone or with `-<8 hex>` (Claude Code adds it for a `git-subdir` source);
- the real path of its `installPath` is the directory `<claude dir>/plugins/cache/vibemaestro/<plugin>/<version>`;
- its `plugin.json`, a regular file, carries no version;
- the new sdlc's launcher template accepts every directory and resolves to the new sdlc.

A failed check is undone: undo puts both files back byte for byte from this run's record (the run prints its path, `KEPT the
run record …`). It names what it leaves: the new cache directories, and the marketplace clone at the new marketplace head
once the marketplace update started. It leaves both files as they are, with the copies, for the owner (exit 5) when either
changed outside the run's plugins' user-scope entries and the marketplace since the copy, a plugin of the run is no longer what
the run left (`MOVED`: neither the copy's entry nor the one its update left), or the copy names an install that is gone; it
marks that record `left`, and no run of the kit deletes or reuses it. The post-check writes nothing; the next run of
the kit deletes other records older than seven days. On success the post-check prints
the next step, its paths shell-quoted, which the session runs. `go` names the file that holds the run's output
(`go: ok — 6 writes — <file>`). The step:

    python3 -I <new sdlc>/scripts/baton.py permissions --install-launcher
    <launcher> permissions --check

`kit:workflow-dispatch` dispatches one `workflow_dispatch` run of a workflow of a private repository, on a branch:

    <launcher> go kit:workflow-dispatch --repo <owner/name> --workflow <file.yml> --ref <branch> [--input <key>=<value>]...

The plan line pins the branch head and the blob of `.github/workflows/<file>` there, so a branch or workflow that moved
after signing is refused; a workflow with no `workflow_dispatch` trigger (a key, or an item of `on:`) is refused at rehearse,
and so is a ref outside letters, digits and `._/-`. The run writes a run record first, one per target and runner process: the matching runs that already exist
(same workflow, event, branch and triggering login). It calls gh only when its plan line is in the signed plan, and marks
the record `sent` once gh accepted the call. Its run is then the one new match, found without comparing clocks; the
post-check wants it at the pinned head (gh starts it by branch name, so a branch that moved in between runs other bytes,
and undo cancels that run). Undo cancels the run only when the record says `sent`, and only for its own record; two new
matches, a new match without `sent`, or `sent` with no run showing, are left for the owner (exit 5).

In a sandbox session (`SEAT` and `INTENT_SLUG` both set) it refuses at rehearse, before any gh call: the pod's token has no `actions:write`, so ask the coordinator to start the workflow run.

## A kit from a dependent plugin

`kit:<name>` also runs a kit that another plugin ships in its `batons/`: a plugin of the same marketplace built on
vibemaestro-sdlc. How it is found:

1. sdlc's own `batons/<name>.sh` comes first.
2. Otherwise baton looks in the `batons/<name>.sh` of every other plugin in Claude Code's plugin registry. It reads the registry
   that sits beside the sdlc copy that runs (`<claude dir>/plugins/installed_plugins.json`, where the copy is
   `plugins/cache/<marketplace>/vibemaestro-sdlc/<version>`). It never reads `CLAUDE_CONFIG_DIR` or `HOME`, which a session can
   set. A `baton.py` run from a checkout finds only sdlc's kits.

Such a kit runs only when all of these hold:

- the plugin's registry id is `<plugin>@<marketplace>`, with sdlc's own marketplace;
- its newest install entry has a real path of exactly `plugins/cache/<marketplace>/<plugin>/<version>`, the version named as the
  launcher accepts one;
- its `.claude-plugin/plugin.json`, reached through no symlink, lists `vibemaestro-sdlc` (or `vibemaestro-sdlc@<marketplace>`)
  in `dependencies`;
- the kit file lies in that plugin's own `batons/`.

It then gets every check an sdlc kit gets: `Each:`, a gate only in the trusted form, and rehearse before sign and run. Two things
point at that plugin rather than sdlc: `BATON_PLUGIN_ROOT` is its root, and the signature binds its `batons/` directory and the
kit's bytes. So an edit after signing, or another version of the plugin, has no signature. The rehearse header ends with
`from <plugin>@<marketplace>`, and the owner's decision card says `(a kit of <plugin>@<marketplace>)`.

Refused before anything runs (rc 64), with the reason:

- a name that sdlc and a dependent plugin both ship, or that two dependent plugins ship: kit names must be unique;
- a plugin from another marketplace;
- a plugin that does not declare the dependency;
- a plugin installed outside the cache shape;
- a kit file or `batons/` that leads outside the plugin's own `batons/`, or a manifest reached through a symlink.

A plugin that may not run a kit never shadows an sdlc kit of the same name. A name nobody ships is rc 66; the message also says
when the registry could not be used.

## Keeping a baton, and changing one

A flow met a second time is kept, so the next session calls it by name instead of writing it again. A kept baton lives in
exactly one place, and a call always names it:

| Place | File | Who reviews it |
|---|---|---|
| `project:<name>` | `<project root>/.vibemaestro/batons/<name>.sh`, committed with the repository | the PR that carries it |
| `user:<name>` | `$XDG_DATA_HOME/vibemaestro/batons/<name>.sh`, else `~/.local/share/vibemaestro/batons/` (this machine) | nobody: `list` says `not reviewed, kept by …` |

`kit:` and `kind:` names are the plugin's; no kept baton can stand in for one. A bare name or another prefix is refused (rc 64),
except by `pack` in a sandbox (below).

**Keep:** `<launcher> pack <path> project:<name>` (or `user:<name>`). It refuses, nothing written:
- rc 3: no `ok` run of these exact bytes in the log (run it with values first), the same bytes already kept under another
  name, or the name already kept with another `Stops`;
- rc 1: the script fails `check` as a kept baton: `Params` with at least one key, `Targets` as patterns (`{key}` placeholders
  before ` — `), no `Usage`;
- rc 64: no place (outside a sandbox), a `kit:` or `kind:` name, a copy name (`-v<digits>`, `-<7 or more hex>`), `user:` in a
  sandbox.

It writes the file and a keep record under the state directory: the record pins the sha256, and a kept baton runs only with
pinned bytes, so an edit by hand is not callable until it is kept again. `pack` does not commit: a session in a repository
commits a `project:` baton on its branch. A `user:` keep prints one line starting `owner:` (what was kept, its `Stops`, its
sha256, what changed, `not reviewed`, its Purpose): copy it into the next reply to the owner.

**In a sandbox** (`INTENT_SLUG` and `SEAT` both set): `pack <path> <name>` keeps `project:<name>`, and `user:` is refused,
since a pod's library is lost with the pod. A pod never gets the owner's signature, so a flow that stops for the owner is handed over:
1. `go <path> key='value'…` to the owner's card (exit 8): check, rehearse and plan against Expect all held;
2. `pack <path> <name>`: these bytes keep as `project:<name>` on that stop (its line says `not run: stop-list, the owner signs
   after merge`); a `Stops: none` script keeps only on a stop of the pod's mode manual, and its line, keep record and
   hand-off say it never ran (the coordinator's `go` is its first run); no `Params`: add them and `go` again first;
3. commit it on the branch and open the PR; tell the coordinator the call (`go project:<name> key='value'…`).

The coordinator merges the PR after its post-check (the default deny globs leave `.vibemaestro/batons/` to the guard), then
runs it with the owner's signature: as `project:<name>` from the merged default branch when the remote is on the owner's list
(below), else from a fresh scratch copy of the merged file, which it then packs.

**Reviewed:** a `project:` baton runs without a keep record on this machine when its bytes are the blob at its path on
origin's default branch (`refs/remotes/origin/HEAD`) and origin is on the owner's remote list; its label is `reviewed on
<url> <branch>`. The list is empty until the owner sets it: `mode remotes` prints it, `mode trust <remote>` and `mode
untrust <remote>` change it, and like the mode they ask the owner. Anything else, a file changed on the branch included,
needs a keep record, and a retired sha stays refused (rc 3 says which condition failed).

**Find and call:** `<launcher> list <keyword>…` prints one line per baton (at most 25); when the keywords match one baton it
prints its whole entry (Purpose, Targets, Blast, Undo, Stops, Params or Usage, the file and its sha256). Call it with
`<launcher> go <place>:<name> key='value'…`.

**Evolve, never copy.** A kept baton stands for a workflow: a changed workflow updates it. The test: the same purpose, targets
and risk?
- a step needed every time: add it;
- a step needed sometimes, or a value that changes: a parameter (the signature binds the values, so the plan shows them);
- other purpose or targets, or a new `Stops` word: a new baton with its own name, which the owner signs if a `Stops` word says so;
- a step met for the first time: a session baton this once; the second time, fold it in.

To evolve one: copy the kept file to a fresh path, change it, `go <path> key='value'…`, then `pack <path> <place>:<name>`
again. The name stays. For `project:` every kept sha stays callable until retired; for `user:` only the newest keep is.
`pack --retire <place>:<name> <sha256>` unpins one sha (the file stays). `pack project:<name> user:<name>` (or the other way)
moves a kept baton; no copy is left, and a move cut half-way finishes when the same command runs again.

A kit changes only through a kit PR; meanwhile the extra step runs as a separate run right after it. The signature binds the
script's sha256 and the log records it, so which version ran stays known. A baton that other sessions or repositories need
becomes a `project:` baton of that repository, or a kit: open a kit issue (`kit:gh-write`) with the script, its log lines and
where else it is needed.
