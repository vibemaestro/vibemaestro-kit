English | [Tiếng Việt](sdlc.vi.md)

# sdlc research: what the plugin costs and gives on app work

The sdlc plugin runs each piece of work through an intent, a spec the person approves, and a pull request, and keeps what it
learns in the repo's `kb/`. This page states what the plugin costs in model tokens up to the local commit, and what it gives in
working code, compared with the same model on the same tasks without the plugin. The pull request and its review rounds are
not part of the measurement. The page covers how it was measured and what the measurements do not show. A second
measurement, at the end, asks what the plugin with its `kb/` gives when a request's answer is recorded only there.

## Findings

- **No measurable difference in cost per working task (0.76–1.25 under the scoring fixed before the last task ran).** That
  is the ratio of cost per task whose hidden tests pass, with the plugin to without it, over two chains; the range holds 1.0.
  Under the scoring as decided, without the plugin costs less per passing task: 1.01–1.25. That figure rests on a scoring
  choice for the last task made after the results, which moves one run without the plugin from fail to pass, and, in the
  first chain, on a single task: the plugin's run of the last task, which fails on a rule the task states. On the hidden tests' raw results, with no exclusion, the ratio is 1.01–1.41.
- **Cost, review and verdicts side by side:**

  | | chain 1, plugin | chain 1, without | chain 2, plugin | chain 2, without |
  |---|---|---|---|---|
  | cost units, five tasks | 4.81 M | 5.12 M | 4.79 M | 4.75 M |
  | tasks that pass (fixed before the last task ran) | 3 of 5 | 4 of 5 | 4 of 5 | 3 of 5 |
  | tasks that pass (as decided) | 3 of 5 | 4 of 5 | 4 of 5 | 4 of 5 |
  | review score (lower is better) | 24 | 16 | 26 | 30 |
  | reviews that say the task is met | 1 of 5 | 2 of 5 | 1 of 5 | 2 of 5 |

  Both arms spend about the same: about 38.4 and 39.5 USD for ten sessions per arm. The ratio follows the number of tasks
  that pass, not the spend.
- **In these runs, the plugin is cheaper on one task and dearer on two** (each figure is the mean of two runs). On the third task it costs 1.30 M units per run against 2.04 M;
  on the fourth, 0.64 M against 0.48 M; on the fifth, 0.82 M against 0.48 M. The first two tasks are about even.
- **No saving shows up over the chain.** From the first task to the fifth, cost without the plugin changes by ×0.70 and
  ×0.64, and with it by ×1.28 and ×0.90. A saving that builds up in `kb/` would show as the plugin's cost falling faster;
  with two chains, and five tasks of different sizes in each, this does not show the opposite either.
- **No unit-suite regression in either arm.** One run with the plugin broke three hidden tests of an earlier task.
- **The plugin adds process and human turns.** With it, every run wrote a spec, and the person answered 14 times
  (10 spec approvals, 4 permission prompts) against once without. Turns: 787 against 637; output tokens: 760,207 against 808,750.

## Method

**The app and the tasks.** A mid-size Node app repo: a server, a vanilla JS client, tests next to the modules, about
360–470 unit tests. The tasks are five merged pull requests in one area of the app, replayed in merge order; six other
pull requests merged between them arrive as history that neither arm worked on. Before each task, the code is reset to the
app's history just before that pull request, so every run of a task starts from the same code. Each task gives the original
request, the decisions the original pull request settled, and a closing paragraph that stops the work at the local commit.

**Arms.**

| Arm | What the session has |
|---|---|
| P | the app with its `kb/` and the sdlc plugin; P's `kb/` carries from task to task |
| N | the app's public export, with no `kb/` and no plugin |

P's code equals N's in every step. N's tree for the fifth task is a stated deviation: the app's export is red there.

Both arms run Claude Code 2.1.290 with Sonnet 5.5 at high effort, one fresh session per task, in a sandbox with a local
repository and no remote. Each arm runs two chains of five tasks, and the two sessions of a pair start each task together.

**What is counted.**

- *Cost units:* the session's tokens from the task to the end of the work: the first push or pull-request attempt after the
  last commit, a stop by the operator, or a 120-minute cap, whichever comes first. Tokens are weighted by price in units of
  the Opus 5.5 base input price: Sonnet 5.5 input ×0.5, output ×2.5, cache read ×0.05. A 1-hour cache write is taken at
  ×1.0, twice the input price, which is an assumption, not a published price. USD is units ÷ 250,000, an estimate.
- *A task that works:* the original pull request's own tests that the task names (two to five per task) all pass on the
  run's final commit, with the test files laid over. The original merge passes them and the code before it fails them, by
  name, on every task.
- *The primary measure:* per chain, cost units of the five tasks ÷ the tasks that work, with P's divided by N's. When the
  range over the two chains holds 1.0, the result is "no measurable difference".
- *Regressions:* the unit suite against the task's starting code, and each earlier task's hidden tests on every later commit.
  A test that the original pull requests also changed on purpose is not counted.
- *Blind review:* each run's code change (`kb/` and plugin files left out) is reviewed without knowing the arm.
  - A fresh Opus 5.5 reviewer reads the task, the patch and the patched app, and may run its tests.
  - A second reviewer checks every finding.
  - A third reviewer per task rules all four changes' findings by one standard.
  - Score: 3 × blocker + 2 × major + 1 × minor, counting only findings ruled real.

**Scoring exclusions.** Three tasks hold a test that asserts something the task text does not state or contradicts. All
three are applied in both arms, and each was set after that task's own results, except the first part of the fifth.
- The third task's first test needs repository names that the text forbids.
- One of the fourth task's tests needs a rule the text leaves out.
- In the fifth task, one test's cost assertions and one tag are not scored. The cost assertions were set aside before that
  task ran. The tag was set aside after its results.

## What the measurements do not show

- **Small samples.** Two chains per arm, one app, one area of it, one model. Under the scoring as decided, one pair of chains
  sits at a ratio of 1.01.
- **Scoring rests on judgment.** Three of five tasks are scored with exclusions, and all but one of the exclusions were set
  after that task's results; the last one after the whole chain had run. The headline uses the scoring fixed before the last
  task ran for that reason.
- **The pull request is not measured.** Every run stops at its local commit, in both arms; the cost of opening the pull
  request, its review rounds and the merge is not in the figures.
- **No browser tests.** Neither the checks nor the reviewers ran an end-to-end suite; findings about end-to-end tests come
  from reading them.
- **Review coverage is uneven.** A score counts only what its reviewer found. One defect present in all four changes of the
  third task was filed against three of them.
- **Blinding is partial.** A patch can hint at the plugin arm (a reference to a `kb/` path turns into a marker). The one who
  ran the reviews and their checks knew which run each change came from; the reviewers did not. The reviewers ran on one
  shared machine, with nothing keeping them inside their own directory. That did happen once: one first check cited a later
  copy of the app found elsewhere, and its adjudicator set that evidence aside.
- **Human turns are not priced.** The 14 interventions with the plugin are the person's time; their effect on cost is only the
  tokens of the turns they start.
- **The decisions were given.** Both arms received, with each task, the decisions the original pull request had settled; the
  study measured carrying out the work, not finding those decisions.

## When the answer is recorded only in `kb/`

The measurement above gives both arms the decisions in the task text, so it measures the work, not finding what was decided.
This one asks: when a request's right answer is recorded only in the app's `kb/`, what does the plugin with that `kb/` give,
compared with the same model with neither?

### Findings

- **With the plugin and its `kb/`, a higher score on four of five tasks and a tie on the fifth.** That meets the bar set
  before the runs (at least four of five), narrowly: each task ran twice per arm, and two of the four wins rest on a single
  run without the plugin. The plugin arm found the answer recorded only in `kb/` more often on three of the five tasks.

  | Task | Where the answer is recorded | Score, plugin (run 1, run 2) | Score, without (run 1, run 2) | Cost units, plugin ÷ without |
  |---|---|---|---|---|
  | why idle characters stay on screen | the reason in a spec | 2, 2 of 3 | 1, 2 of 3 | 1.77 |
  | where a fee figure comes from | a decision | 2, 1 of 3 | 0, 0 of 3 | 1.04 |
  | add a feature an earlier spec rejected | the rejected option in a spec | 2, 2 of 6 | 4, 0 of 6 | 0.75 |
  | does a pushed tag build the image | the current-state map | 3, 2 of 3 | 0, 0 of 3 | 1.35 |
  | a bug known only by its symptom | a design case in a spec | 4, 4 of 4 | 4, 0 of 4 | 1.62 |

  The scores of 6 and of 4 are two reviewers' scores summed.
- **Facts recorded only in `kb/` were found; reasons and rejections were not.** The fee's origin and how the image is
  built: given by the plugin arm in all four runs, by the other arm in none (it said the repo has no source). The reason
  behind the idle rule: in no run of either arm, though the plugin arm read the spec that holds it; the difference on that
  task is that the plugin arm called the rule a design choice in both runs, the other arm in one. The earlier rejection:
  found by neither arm. The plugin arm wrote a spec that proposed the rejected feature in both runs, and stopped only because
  it asked first; the other arm built it once without asking.
- **On the bug, the plugin arm followed the recorded design.** With the plugin, both runs cited the design case and fixed the
  bug as designed (the hidden tests pass). Without it, one run fixed the bug the same way from the code; the other took the bug for the design and changed the
  behaviour the other way (the hidden tests fail).
- **Cost: about 1.17× on these tasks, 3.53× on two one-line bug fixes.** On the five tasks the plugin arm used 966,311 cost
  units against 829,118. On the two control bugs, where `kb/` holds nothing that matters, both arms fixed both, and the
  plugin arm cost 3.53× as much: each run wrote an intent and a spec and asked for approval before a one-line fix. The plugin
  arm asked the person 6 times in all, the other arm twice.

### Method

The arms and the sandbox are those above, with two differences: each run is one fresh session on its own copy of the app, with
no chain and no history; and a run's cost is counted up to the session's own end or a 60-minute cap. Five tasks are raw requests, each with a key point that a search shows is absent from the other
arm's tree (the app's public files, by the export's allowlist); two control tasks are one-line bugs that `kb/` does not touch. Two runs per arm for each `kb/` task and one for each
control: 24 sessions, about 11 USD with the reviewers.

Fixed before any run: each task's right answer, the points it is scored on, the hidden tests, and the one scripted reply to
any question, the same in both arms (for the rejected feature, the recorded decision).

Scoring: a fresh Opus 5.5 reviewer per pair of runs scores both against the points from the session's text and its code
change, blind: arm-revealing words, `kb/` paths and branch names are replaced. When an arm's two runs of a task differ by 2
points or more, a second reviewer scores both pairs again and the two scores are summed. The bug and the controls are also
scored by hidden tests.

### What this measurement does not show

- **Small samples.** Two runs per arm and task, one app, one model. Two of the four wins (the idle rule and the bug) each
  rest on a single run without the plugin; with either one a tie, the bar would not be met.
- **Chosen tasks.** One person picked them from a `kb/` they had read; the search proves the answer is absent from the public
  export, not that such tasks are typical.
- **The scripted reply rewards asking.** A run that asks before building the rejected feature gets the recorded decision.
- **Reviewers can be wrong.** A score counts what the session's text says, as one reviewer read it. The two tasks scored
  twice got identical points from both reviewers.
- **Not every win is the `kb/` answer.** On the idle rule the difference is a point the other arm also scored in one run,
  not the reason recorded only in `kb/`; on the fee task two of three points are findable without `kb/`. No task of the kind "a
  change that must keep a recorded decision" was used: for every candidate, the other arm's tree already held the answer.
- **Blinding is partial.** A spec or an approval step in the plugin arm's text can show through, and in five of the plugin
  arm's ten scored runs the plugin's script name or a spec's date was not replaced. This was found after all the scores;
  both are now replaced, and every review of a text where they were left was done again by a new reviewer: no score
  changed.
- **Time is not used.** Active time mixes in the wait for tests.
