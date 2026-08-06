---
name: gauntlet-loop
description: Build any deliverable to a stated quality bar by fanning out a builder sub-agent per aspect, looping each through a fresh harsh critic against a rubric derived from a required concrete reference, then gating completion on a final unanimous blind side-by-side panel that must prefer the build. Use when D explicitly invokes it, or says "gauntlet this", "don't stop until it's perfect, blind-compare it against [X]", or hands over a build with an explicit, comparable quality bar and asks for AAA-level rigor. Requires the Workflow tool.
argument-hint: "[deliverable, optionally 'as good as' a named reference]"
metadata:
  category: orchestration
---

# /gauntlet-loop

## Usage

```bash
/gauntlet-loop <deliverable> as good as <reference>   # both stated inline
/gauntlet-loop <deliverable>                           # interviews for the reference
/gauntlet-loop                                         # interviews for everything
```

Also triggers without the slash on emphatic, unmistakably gauntlet-shaped requests: "gauntlet this", "don't
stop until it's perfect — blind-compare it against \<X\>", "fan out sub-agents and loop until it's flawless
against \<X\>". A bare comparative aside ("make the button as good as the homepage one") does **not** trigger
this skill on its own — see Guardrails; this pipeline is expensive and unbounded by default, so it only fires
on a request that is clearly asking for that.

This is a different mechanism from this repo's built-in `loop` skill (which runs a prompt or command on a
recurring interval). "Loop" here means the per-aspect build → critic → revise iteration inside a single run,
never scheduling or recurrence.

## Description

Generalizes a one-shot prompt that built an AAA-quality FPS game in ThreeJS in a single pass, by fanning out
sub-agents per aspect, looping each through a harsh critic sub-agent, and not stopping until every critic was
"utterly wowed" comparing the build blind, side by side, against the real Call of Duty game. This skill keeps
that shape — Task, Build Method, Bar to Hit — for any deliverable: code, a feature, a design, a document, content,
anything with a stateable quality bar. It requires a concrete, named reference; without one there is nothing to
be blind about, so the skill refuses to run. Every question goes through the `ask` skill's format; the pre-build
round is a compressed `interview` that closes with a Playback of the assembled prompt and rubric — D confirms
before anything launches, the same closing mechanism `/interview` uses.

Execution runs on the `Workflow` tool. There is exactly one artifact involved: the assembled Gauntlet Prompt
(Behavior 4 — Task, Build Method, Bar to Hit, plus the D-confirmed rubric) is the literal input `Workflow`
consumes. Launching in-session means invoking `Workflow` with that prompt text, running as a background task;
save-only mode writes the identical prompt text to disk instead of launching it. Both "save" and "launch" happen
every run, in different orders — save always happens, launch is the choice that may or may not follow it. A
`Workflow` run cannot itself pause to ask D a question mid-execution — it has no interactive tool inside its
script body — so stalls (Behavior 5-6) are surfaced by the orchestrating session after the run reports them, not
from inside the run itself; see Behavior 7 for exactly how that works.

## Expected Output

```text
User: /gauntlet-loop our pricing page, as good as Stripe's
Claude: (AskUserQuestion)
        Context: A blind comparison needs a reference D can actually hold
        the build up against — a shipped page, a screenshot, a spec.
        Ask: Compare against Stripe's live pricing page, or a frozen
        screenshot/version?
        [Live page (Recommended) — most current, but can change mid-run]
        [Frozen screenshot/version — stable target, D supplies it]
User: (picks live)
Claude: (AskUserQuestion)
        Ask: How many revision rounds should each aspect get before I stop?
        [Unbounded (Recommended) — true to "don't stop until it's perfect";
         real tokens per round, no mid-run checkpoint besides cancellation]
        [Set a numeric cap — I'll ask how many]
User: (picks unbounded)
Claude: (AskUserQuestion)
        Ask: Run this now in the background, or just save the Gauntlet
        Prompt for a later session?
        [Run now (Recommended)]
        [Save only]
User: (picks run now)
Claude: (AskUserQuestion — proposed decomposition: layout/visual design,
         copy & positioning, plan comparison table, FAQ/objection handling —
         confirm or edit)
User: Confirmed
Claude: (AskUserQuestion — pre-registered rubric derived from Stripe's page,
         pre-grouped into 3 final-panel slices: visual/craft, copy/positioning,
         completeness — confirm or edit)
User: Confirmed
Claude: (PLAYBACK dialog — assembled Gauntlet Prompt played back verbatim:
         Task pinned to Stripe's page, Build Method [4 aspects, single fresh
         harsh critic per round, unbounded], Bar to Hit [unanimous 3-panelist
         blind gate], plus the full confirmed rubric)
        Ask: Launch this?
        [Launch it (Recommended)] [Fix something]
User: Launch it
Claude: Gauntlet Prompt assembled and saved to
        ./.claude/gauntlet-loop/plans/gauntlet-pricing-page-20260806-1420.md
        Launching now — 4 aspects, unbounded rounds, single fresh harsh
        critic per round, final 3-panelist panel gates completion.
        (Workflow runs as a background task; per-aspect round narration
        streams back to this session as it completes each round)
        [layout/visual design, round 3] critic flaw list empty → aspect done
        [copy & positioning, round 5] same rubric line item failing 3 rounds
                  running ("value prop buried below fold") → aspect stalled,
                  continuing other aspects
Claude: (Workflow run completes — 3 aspects done, 1 stalled)
        (AskUserQuestion — stall on "copy & positioning", same rubric line
         item unresolved 3 rounds running: keep going, adjust the rubric, or
         take a different angle?)
User: (answers: keep going)
Claude: (relaunches Workflow via resumeFromRunId, seeded with D's answer,
         to finish only the stalled aspect; other aspects replay from cache)
        (resumes; eventually) Integration pass clean. Final panel: 3/3
        panelists clearly prefer the build over Stripe's page on their
        assigned rubric slice. Gauntlet complete.
        Deliverable: [the finished pricing page / diff / file set].
        41 total agent calls across 2 Workflow runs.
```

## Behavior

### 1. No reference, no gauntlet

If the invocation doesn't name a concrete reference, the skill doesn't state a policy in prose and then open a
dialog underneath it — by the `ask` skill's own mechanics, a dialog takes focus immediately, so anything
load-bearing sitting in prose above it goes unread. Instead the refusal _is_ the dialog, carried in its Context
line, so D actually reads it before answering:

```text
Context: Gauntlet Loop needs a concrete reference to blind-compare against — a shipped product, a
screenshot, a competitor, a spec doc, or a benchmark. "Make it AAA quality" or "utterly perfect" isn't
one on its own; the critics need something specific to hold the work up against. The run doesn't start
without one.

Ask: What should the build be judged against?
[Help me find candidates (Recommended) — I'll propose a few based on the deliverable]
[Point me to a doc already on disk]
[Cancel the gauntlet, proceed as a normal task instead]
```

D can also just name the reference directly by typing it — that's the expected common case, and it isn't a
listed option, since the dialog already accepts free text and the `ask` skill's own rule is that a slot is never
spent on what typing already covers. "I don't have one yet" is a real, first-class answer, reachable through
either the cancel option or a direct reply — it ends the interview, not a soft nudge to guess on D's behalf.

### 2. Modality check on the reference

A reference is only as blind-comparable as it is inspectable in the same medium as the deliverable. When the
reference is confirmed, the skill checks whether it can be normalized to the deliverable's medium (both
renderable, both readable, both executable, etc.). This check has one specific effect, on one specific stage:
per-aspect rounds (Behavior 5) are already rubric-anchored in every case regardless of modality, so a mismatch
changes nothing there. What it changes is Behavior 6's final panel — normally a live blind A/B against the real
reference — which becomes a rubric-only scoring pass instead when no same-modality artifact exists, and it
forces Behavior 3's iteration-cap dialog to drop the unbounded option entirely (only a mandatory numeric cap is
offered) since a loop with no live comparison to fall back on cannot be allowed to run open-ended. If a
same-modality artifact doesn't exist, the skill offers to find one before accepting the downgrade.

### 3. Interview: reference → cap → launch mode → rubric → decomposition → playback

Six steps, in order, each gated on the one before it resolving, each a single decision — never bundled, per the
`ask` skill's one-decision-per-dialog rule:

- **Reference** (Behavior 1-2): required, with the modality check folded in.
- **Iteration cap**: unbounded (the default, true to the source prompt's "don't stop until it's perfect") or a
  numeric cap. The unbounded option's own description carries the cost/scope heads-up inline — no separate
  round, no follow-up warning — stating plainly that no cap means genuinely unbounded rounds, that rounds spend
  real tokens even though they run in the background, and that there is no mid-run checkpoint besides
  cancellation. Because the heads-up lives on the unbounded option itself, it simply never appears when D picks
  the numeric-cap option instead, with no separate precondition to track. If Behavior 2's modality fallback
  triggered, this dialog does not offer the unbounded option at all — only the mandatory numeric cap is
  confirmed (a default is proposed, D can raise or lower it).
- **Launch mode**: run now in this session, or save the prompt only — a separate dialog from the cap, since how
  long the loop may run and where it executes are independent axes; you could sensibly run now with a cap, or
  save an unbounded run for later. Bundling them would be exactly the unrelated-decisions-in-one-dialog pattern
  the `ask` and `interview` skills both rule out.
- **Rubric**: the skill shows the pre-registered rubric derived from the reference (Behavior 4) — the concrete,
  checkable qualities the build will be judged against — pre-grouped into the dimension slices the final panel
  (Behavior 6) will use, and asks D to confirm, edit, add, or remove lines or groupings before build starts.
  This is what makes "wowed" falsifiable instead of a mood: D approves the yardstick before any critic uses it,
  the same way D approves the reference and the decomposition.
- **Decomposition**: the skill reads the confirmed deliverable and reference and proposes a concrete aspect
  split before asking — never asks D to decompose blind. Options: use as proposed (recommended), edit the list,
  a genuinely different split (e.g. regroup by screen instead of by layer), or no fan-out at all for a
  deliverable too small to benefit from splitting.

Deliverable itself is Step 0, asked only if the invocation didn't already state one — most invocations will,
mirroring how `/interview <topic>` takes its subject as an argument. ("Step" here and "round," used later for
per-aspect iterations, are deliberately different counters that are never conflated in a ledger.)

Once the Gauntlet Prompt is assembled (Behavior 4), one more dialog closes the interview before anything
launches: the **Playback**. This is this skill's Understanding Playback — the same closing mechanism `/interview`
uses — showing the assembled Task, Build Method, and Bar to Hit, plus the confirmed rubric, played back verbatim
for D's confirmation, not summarized or re-narrated. Only D's confirmation ends it; a correction reopens the
relevant earlier dialog and produces a fresh playback before trying again. If D says "just launch it" or similar
mid-playback, the skill skips straight to Behavior 7, stating any still-open assumptions in prose first — the
same escape hatch `/interview` uses, never a silent skip.

### 4. Assemble the Gauntlet Prompt — Task, Build Method, Bar to Hit

The three-part shape from the source prompt — Task, Build Method, Bar to Hit — is preserved as the assembled
prompt's structure, and is never collapsed into one flat paragraph regardless of how simple the deliverable is
(Guardrails enforces this). What does not carry over unchanged is the source's single mechanism for judging
every pass: the source ran one flat, per-item, blind side-by-side comparison against the real game, on every
iteration. This skill deliberately splits that into two tiers instead: fast, cheap, rubric-anchored defect
checks driving each per-aspect revision round (Behavior 5), and the genuine blind side-by-side reserved for the
integrated whole at the final gate (Behavior 6). This split exists because three same-model critics repeating a
live blind comparison every round, on every aspect, is triple cost for correlated (non-independent) signal —
see Behavior 5 for the full reasoning. The trade-off is real, not free: per-aspect rounds never see the actual
reference, only the rubric derived from it, so the rubric's fidelity to what the reference actually is (D
confirms it in this same interview) is what keeps that gap from becoming a loophole.

- **Task**: the deliverable, pinned to the reference — never "great" or "high quality" unqualified, always
  "matches or beats \<reference\>."
- **Build Method**: fan out one sub-agent per confirmed aspect; each aspect loops build → single fresh harsh
  critic → revise, using a defect-list verdict (Behavior 5), not a pass/fail vibe. The same builder sub-agent
  persists across rounds within one aspect's loop — it is not re-spawned fresh each round like the critic — so
  it retains memory of what it already fixed and why; this is what the anti-regression ledger in Behavior 5
  relies on. Builder sub-agents work at maximum thoroughness on every pass, not a quick draft — the direct
  analog of the source prompt's "ultracode" instruction, and it applies every round, not just the first. Every
  builder and critic sub-agent, at every round, is launched with a restricted tool set: read/write within the
  run's own working area only — no deploy, publish, send, purchase, or production-write tools, regardless of
  what the ambient session can access. This is enforced at launch, not policed after the fact.
- **Bar to Hit**: don't stop until the final panel (Behavior 6) is unanimous — every panelist decisively prefers
  the build on their assigned rubric slice, which is the cashed-out meaning of "utterly wowed." A tie, a narrow
  or non-decisive preference, or a single dissent all read as not done.

The pre-registered rubric that makes "wowed" falsifiable instead of a mood is derived from the reference and
confirmed with D before build starts (Behavior 3) — critics judge against this written, D-approved rubric
throughout, never an unanchored impression. Assembly closes with the Playback dialog defined in Behavior 3 — D
confirms this exact prompt and rubric before Behavior 7 does anything with it.

### 5. Per-aspect loop: single fresh, harsh critic, defect-list verdict, rubric-anchored

Every critic sub-agent — per-aspect and final panel alike — is prompted explicitly as a harsh, adversarial
critic: assume the build is flawed until proven otherwise, actively hunt for its weakest points rather than
confirming its strengths, and treat the reference's standard as the default expectation, not a stretch goal.
This persona instruction is as load-bearing as the defect-list format below — a lenient critic can still produce
a short, well-formatted, real-but-minor defect list and wave the build through without ever having been pushed
to be harsh, so format rigor alone is not a substitute for it.

Each revision round spawns exactly one critic — a fresh agent instance with no memory of the build conversation
and no visibility into prior rounds' verdicts (kills anchoring and sycophancy drift). Three same-model critics
voting every round was the naive design; it was dropped after review because same-model panelists are correlated
noise, not independent judgment — tripling cost for near-zero added signal while raising deadlock risk inside an
unbounded loop. That objection is about redundancy: three instances independently re-answering the _identical_
question every round adds cost without adding signal. It does not apply to the final panel (Behavior 6) — those
critics each answer a different, non-overlapping question (a distinct rubric slice), so there is no redundant
vote to be correlated in the first place.

The critic's verdict is a list of specific, located defects, each tagged to the pre-registered rubric line item
(Behavior 3-4) it violates — an empty list is the only pass; adjectives ("looks great", "feels AAA") are not an
acceptable verdict on their own and get rejected back to the critic for specifics. Tagging every defect to a
rubric line item, rather than free prose, is what makes "the identical defect" and "a previously-fixed defect
regressed" checkable at all despite critics being fresh and memoryless: the Workflow script's own loop state (a
plain ledger object carried across iterations in the script, not owned by any critic) tracks, per rubric line
item, whether it was open last round and whether this round's list still names it. An item drops only when the
current round's list omits a line item that was previously open; the builder — which does persist across rounds
(Behavior 4) — is the one accountable for not letting a dropped item's underlying issue silently reappear, since
it is the only party present across the whole aspect's history. Guardrails requires this anti-regression check
to run every round, not just be asserted.

**Stall handling:** because every defect is tagged to a rubric line item, "identical defect" has the same
checkable definition as above — the same rubric line item failing in consecutive rounds, regardless of how
differently each fresh critic phrases it in prose. A new rubric line item failing does not count, even if it
sounds related. If the same rubric line item survives three consecutive rounds unresolved, the script marks that
aspect **stalled** in its own state and stops looping on it — it does not keep spinning silently, and it does
not block other aspects, which keep running in their own independent loops (Behavior 4's fan-out has no barrier
between aspects). The run reports every stall in its per-round narration (Behavior 8) as it happens; what happens
next — D deciding whether to keep going, adjust the rubric, or take a different angle — is handled by the
orchestrating session once the run completes or is checked on, per Behavior 7, not from inside the stalled loop
itself. If D chooses to keep going, a resumed run gets a fresh three-round counter for that aspect and can stall
again under the same rule if the same line item is still failing three rounds later.

### 6. Integration, then a separate, final, role-differentiated blind panel

The actual "don't stop until wowed" gate is structurally distinct from the per-aspect loop, and runs in two
parts: integration, then judgment. Both parts require every aspect to have reached either an empty defect list
or a D-resolved stall (Behavior 5, Behavior 7) — a run does not integrate or judge over an aspect still actively
stalled.

**Integration.** A dedicated integrator sub-agent — neither a builder nor a critic — merges the aspects into one
deliverable. Where two aspects' outputs conflict (e.g. two builders assumed different layouts), the integrator
resolves the conflict by rubric priority and routes the losing side back into that aspect's per-aspect loop
(Behavior 5) with the conflict as its next defect. Any defect the integration step itself introduces that
doesn't map cleanly to one existing aspect becomes its own cross-cutting aspect, entering the same per-aspect
loop rather than being silently absorbed or dropped. Only once integration produces a defect-free merge does the
build proceed to the panel.

**The panel.** The integrated build is handed to a final panel whose slices are exactly the dimension groupings
D confirmed in the Rubric dialog (Behavior 3) — one critic per confirmed grouping, minimum three panelists even
for a narrow rubric, covering the full confirmed rubric by construction rather than an arbitrary subset, so no
single critic is ever both judge and jury for the whole build. Panelists are fresh, have no access to per-aspect
critic history or prior verdicts, and are shown only the integrated build and the reference — anonymized as A/B
with position randomized per critic — genuinely blind, not just unlabeled to a critic who can infer which is
which from context.

Each panelist judges only their assigned rubric slice and returns one of four verdicts on it: clearly prefers
build, prefers build, toss-up, or prefers reference — never a holistic call on the whole deliverable, since a
critic scoped to one slice has no legitimate basis to render one. Unanimous pass requires every panelist at
_clearly prefers build_ on their slice; this is the cashed-out meaning of the source prompt's "utterly wowed" —
a decisive, rubric-anchored margin on every dimension, not a narrow or mixed one. A toss-up, a "prefers
reference," or a merely-"prefers build" (non-decisive) on any single slice all count as not done, same as an
outright dissent.

Any panelist's verdict below _clearly prefers build_ routes their specific, located gaps back only to the
aspects they implicate — not a full rebuild — and those aspects re-enter their per-aspect loop (Behavior 5)
seeded with the new punch list, then flow back through integration before the panel re-runs.

**Outer-loop stall guard.** Behavior 5's stall guard only counts rounds within one aspect's own inner loop; this
outer cycle gets a symmetric guard, matched the same way — by rubric line item, not prose. If the same aspect
gets routed back by the final panel three times running, the run marks that aspect stalled at the outer level
(same mechanism as Behavior 5) instead of re-entering it a fourth time automatically.

**Rubric-only mode.** If Behavior 2's modality fallback is in effect, there is no live artifact to blind-compare,
so the panel judges differently: each panelist still owns a rubric-grouping slice, but scores the integrated
build against the written rubric for that slice rather than against a reference artifact. Verdict becomes "meets
rubric slice" / "does not meet rubric slice," unanimity is still required, and the mandatory numeric cap
(Behavior 2-3) governs how many times this can loop before it stalls and reports rather than running unbounded.

**Delivery.** Once the panel is unanimous, the run's final result is the integrated deliverable itself (not a
report about it) plus a summary: total agent calls, rounds per aspect, and the panel's verdicts. Behavior 7
covers how this reaches D.

### 7. Launch: what "run now" actually does, and how a stall reaches D

Launching only happens once Behavior 3's Playback dialog is confirmed. If the `Workflow` tool isn't available in
the current environment, the skill says so and stops rather than degrading to a lesser orchestration mechanism —
the per-aspect fan-out and long-running background execution this skill depends on has no equivalent without it.

The Gauntlet Prompt assembled in Behavior 4 — Task, Build Method, Bar to Hit, plus the confirmed rubric — is the
exact input the `Workflow` tool consumes; there is one artifact, not a prompt file and a separate script.
Launching in-session means invoking `Workflow` with that prompt text as a background task. A running `Workflow`
script has no interactive tool available to it — it cannot itself open an `AskUserQuestion` dialog and wait for
an answer mid-execution. This governs how stalls actually get resolved: the script's own per-round narration
(`log()` calls) streams to D live as each aspect completes a round, including stall markers the moment they fire
(Behavior 5, Behavior 6), so D can see a stall as it happens and is never surprised by it — but the run itself
does not block waiting on D. It keeps running every aspect that can still make progress, and completes (returns)
once every aspect is either done or stalled. Only then does the orchestrating session — this skill, running in
the main conversation, outside the background task — surface an `AskUserQuestion` about each stall, exactly as
Behavior 5 describes. If D answers with a way to keep going, the skill relaunches `Workflow` using
`resumeFromRunId` seeded with D's answer: every aspect that already finished replays instantly from cache, and
only the previously-stalled aspect actually re-runs. This can repeat for as many stall-resolve-resume cycles as
the run needs; nothing about it requires the original session to stay open the whole time, since D can also come
back later and resume from the saved run ID.

Launching in-session is the default choice for this reason — D sees live progress and stalls as they happen, and
can cancel at any point. D can instead choose save-only to hand the same prompt to a fresh session later, or go
back and set a cap before launching anything. Save-only mode skips the `Workflow` invocation but writes the
identical prompt text to disk — the file written to disk **every run**, regardless of whether D chooses to
launch it immediately, is this one artifact, never a separate byproduct.

Save location resolves in order: this project's existing temp/output convention if one is documented in its
`CLAUDE.md` or equivalent (e.g. a `## File Organization` section) — else `.claude/gauntlet-loop/` under the
project root, else `~/.claude/gauntlet-loop/runs/` if no project convention is discoverable — never the repo
root or a source directory. When the discovered convention names multiple purpose-specific subdirectories (e.g.
this repo's own `.tmp/plans/`, `.tmp/reports/`, `.tmp/analysis/`, `.tmp/drafts/`), the Gauntlet Prompt is a build
plan handed to `Workflow`, so it saves under the subdirectory that convention names for plans; if none is
plan-shaped, it falls to the convention's most general default subdirectory rather than guessing among the
specific ones. The resolved path is always stated in the response, never asked as a separate decision.

### 8. Cost transparency instead of a silent cap

Because the default loop is genuinely unbounded, the honest mitigation is visibility, not a hidden ceiling: every
aspect reports a per-aspect round update as it happens — that aspect's own round number, its defect count, and
its stall status when Behavior 5 or 6's guard fires. These are aspect-local counters, not a single global "round
N" — aspects fan out with no barrier between them (Behavior 4) and finish at different times, so there is no
shared round clock to report against. What the run's final summary reports instead is a true aggregate:
cumulative agent calls across every aspect, every critic round, integration, and the final panel, summed across
however many `Workflow` launches the run took (an original launch plus any stall-resume relaunches, per
Behavior 7). D sees cost accruing in real time via the per-aspect narration and can cancel at any point;
cancelling preserves all state (rounds completed per aspect, last verdicts, saved Gauntlet Prompt path, run ID
for resuming) rather than discarding it. A numeric cap, when set (Behavior 3), applies per aspect to that
aspect's own per-aspect loop (Behavior 5) and is a hard stop there — the run reports at the cap even without an
empty defect list rather than running past a limit D set. Each time an aspect re-enters its loop after a
final-panel dissent (Behavior 6), it gets a fresh budget of the same cap, since a dissent is a new, narrower
defect list, not a continuation of the old one. The final panel itself is not metered by the numeric cap — it
runs once per integration attempt; the loop it can trigger is bounded by how many times aspects can re-enter
their own capped loops, not by a separate panel-level counter.

## Guardrails

- No gauntlet run without a named, concrete reference. "Make it AAA quality" or "utterly perfect" alone is never
  accepted as one.
- This skill does not fire on a bare comparative aside inside an otherwise ordinary request. It requires either
  explicit invocation or unmistakably gauntlet-shaped language (Usage) — an incidental "as good as X" in passing
  conversation is not, on its own, enough to launch an unbounded multi-agent pipeline.
- No unbounded loop against a reference that can't be normalized to the deliverable's modality — falls back to a
  written rubric and a mandatory cap instead, and Behavior 3's iteration-cap dialog drops the unbounded option
  entirely whenever this fallback is in effect.
- Per-aspect critic verdicts (Behavior 5) are defect lists, each tagged to a rubric line item pre-registered from
  the reference and confirmed with D before build starts (Behavior 3) — bare adjectives ("great", "AAA", "wowed")
  are never an acceptable verdict on their own, and an empty list is the only pass.
- Final-panel verdicts (Behavior 6) are a different, explicitly-scoped format — one of four preference levels
  (clearly prefers build / prefers build / toss-up / prefers reference) per panelist, on that panelist's rubric
  slice only, never a defect list and never a holistic call on the whole build. Unanimous pass requires every
  panelist at _clearly prefers build_.
- Every critic sub-agent, per-aspect and final panel alike, is explicitly prompted as a harsh, adversarial
  critic — assume the build flawed by default and hunt for its weakest points. The defect-list format is a
  check on this, not a substitute for it.
- Per-aspect critics are single, fresh-context instances with no visibility into the build conversation or prior
  rounds' verdicts. The final gate is the only place a multi-critic panel runs; there it is role-differentiated
  by rubric grouping, sized to at least three panelists covering the full confirmed rubric by construction, each
  judging a distinct, non-overlapping slice — not the same question voted on multiple times, which is the
  specific redundancy the single-critic-per-round design (Behavior 5) rejects.
- The final gate's verdict is unanimous: every panelist must land at "clearly prefers build" on their slice — the
  cashed-out meaning of "utterly wowed." A tie, a toss-up, a non-decisive preference, or any single dissent all
  mean not done. Majority approval is never sufficient.
- Producers are never accepted as their own critics — critic and builder are always separate sub-agent instances.
- The builder sub-agent persists across rounds within one aspect's loop and is accountable for not letting a
  previously-flagged, rubric-tagged defect silently reappear; the script's own loop state checks every round for
  a previously-open rubric line item unexpectedly missing from the current defect list without a corresponding
  fix, and treats that as a regression, not a clean pass.
- The integration pass between aspect fan-out and the final panel is a defined step with a named owner (Behavior
  6), never implicit — conflicts between aspects are resolved by rubric priority, and any integration-introduced
  defect that doesn't map to an existing aspect becomes its own cross-cutting aspect rather than being dropped.
- The identical unresolved defect (same rubric line item) surviving three consecutive rounds within one aspect's
  own loop, or the same aspect being routed back by the final panel three times running, marks that aspect
  stalled and stops looping on it rather than continuing silently — it does not block other aspects. A stall is
  never resolved by a running `Workflow` script itself asking D a question; only the orchestrating session does
  that, once the run reports the stall (Behavior 7).
- The Gauntlet Prompt (one artifact: Task, Build Method, Bar to Hit, plus the confirmed rubric) is saved to disk
  on every run, whether or not it's launched immediately, and never written to a repo root or source directory —
  it is the same artifact `Workflow` consumes when launched, not a separate script.
- No irreversible side effects run inside the loop: builder and critic sub-agents are launched with a restricted
  tool set — no deploys, sends, purchases, or writes to production or shared systems, regardless of what the
  ambient session can access. This is enforced at launch, not merely asserted as policy.
- If the `Workflow` tool is unavailable in the current session, the skill states this and does not run a
  degraded substitute — no other mechanism in this skill can perform the fan-out and background execution
  `Workflow` provides.
- A numeric cap, when set, is scoped per aspect per loop entry (Behavior 8) — not a single global scalar shared
  across every loop level — and each re-entry after a final-panel dissent gets a fresh budget.
- Every round of a per-aspect loop reports a per-aspect ledger update — round number, defect count, stall
  status — via the run's live narration before the next round starts on that aspect.
- Every decision point in this skill — reference, modality fallback, iteration cap, launch mode, rubric
  confirmation, decomposition, playback, and both stall escalations — goes through the `ask` skill's
  `AskUserQuestion` format in the orchestrating session, never plain-text prose questions and never an attempt to
  ask from inside a running `Workflow` script. Frontmatter never sets `context: fork`, since these dialogs must
  reach D.
- Setup/mechanical failures (the `Workflow` invocation itself failing to start) are retried up to 3 times per
  this project's `CLAUDE.md` Verification convention, then reported with diagnostics. This bounded retry covers
  only the skill's own setup — the critic-approval loop itself stays unbounded by design.
- If D cancels mid-run, the skill reports the last known state of every aspect (rounds completed, last critic
  verdicts, saved Gauntlet Prompt path, run ID) rather than discarding progress silently.
