---
name: colorwheel
description: Vet any idea, artifact, or output by running it through all seven InfoSec color-wheel team constructs — Red attacks it, Blue mitigates, Yellow prices the build, Orange hardens the design, Green makes failure visible, Purple re-attacks the mitigations until nothing new surfaces, White issues the verdict. Read-only; returns PROCEED / PROCEED WITH CONDITIONS / REVISE / KILL plus a ranked fix list. Use when D says "run this through colorwheel", "red team blue team this", "wargame this idea", "stress-test this", or hands over an idea, plan, spec, draft, or output and asks whether it holds up. Not for genuine penetration testing or security auditing of real systems — those route to security-review.
argument-hint: "[idea, artifact, file, PR, or output to vet] [--deep]"
metadata:
  category: orchestration
---

# /colorwheel

## Usage

```bash
/colorwheel <the idea, artifact, or path to vet>   # default depth: subagent fan-out
/colorwheel <target> --deep                        # escalates to a Workflow with adversarial verification
/colorwheel                                        # vets the last substantive output in the conversation
```

Also triggers without the slash on "red team blue team this", "wargame this", "stress-test this idea", "poke holes
in this", or D handing over a plan and asking whether it survives scrutiny. It does **not** fire on a passing "is
this any good?" inside an otherwise ordinary request — see Guardrails.

Named for the InfoSec color wheel (April C. Wright, _Orange Is the New Purple_, Black Hat USA 2017), which extends
the classic Red/Blue pair with Yellow (builders) and the secondary teams that mix them. This skill uses those seven
constructs as vetting lenses on any subject, not as a security assessment of a real system.

## Description

One model reviewing its own idea converges toward agreement with it. This skill breaks that by splitting the review
into seven adversarial roles with genuinely different jobs, running the ones that can be independent as separate
subagents with no visibility into each other, and then making the defender's answers survive a re-attack before any
of it reaches a verdict.

All seven constructs fire on every run. They do not all fire as parallel agents, because three of them are defined
by their inputs: Blue answers Red, Purple _is_ the attack↔mitigate loop rather than a perspective, and White judges
what survived. Behavior 3-5 fixes the sequencing that makes each construct coherent.

The skill is **read-only**. It never edits the artifact, never commits, and never needs a worktree — so it is safe
to fire at a repo you don't own, a draft you haven't saved, or an idea that exists only in the conversation. Its
output is a verdict plus a ranked list of prescribed fixes, which D can hand to `/implement` or apply by hand.

Boundaries against its siblings: `gauntlet-loop` _builds_ a deliverable up to a named reference's bar; this vets
something that already exists. `/review` and `/security-review` own code review and real security work. `/verify`
runs the project's actual gates. `/colorwheel` runs none of those — it reasons about a subject and reports.

## Expected Output

```text
User: /colorwheel — should BareClaude charge per-seat or per-agent-hour?
Claude: Target: a pricing-model decision (prose, no artifact on disk).
        Round 1 — full wheel: Red, Yellow, Orange, Green in parallel, then Blue.
        (4 agents return; Blue runs against Red's 9 findings)
        Round 2 — Purple: Red re-attacks Blue's 9 mitigations.
        (3 mitigations broken, 2 new findings)
        Round 3 — Purple: Red re-attacks the revised 5.
        (nothing new — converged)
        White: scoring 11 surviving findings against upside.

        VERDICT: PROCEED WITH CONDITIONS — per-agent-hour, gated on metering.

        Top fixes, ranked:
        1. Meter agent-hours before announcing the price — Red broke every
           per-hour variant that bills against an unmeasured unit. (Orange:
           this is a design flaw, not an incident.)
        2. Cap per-customer monthly spend — Red's runaway-loop attack turns
           a $200/mo customer into a $4k invoice and a refund.
        3. ...

        Full report: .tmp/reports/colorwheel-pricing-model-20260814-1732.md
        11 agent calls, 3 rounds.
```

## Behavior

### 1. Resolve the target

The target is whatever D handed over: an idea in prose, a file, a directory, a repo, a URL, a PR, or — with no
argument — the last substantive output in the conversation. The skill reads it before any team runs, and states in
one line what it resolved the target to be, so a misread is caught before agents spend tokens on the wrong subject.

If the target is genuinely ambiguous (two candidate artifacts, or "this" with no clear referent), it asks through
the `ask` skill's format rather than guessing. That is the only dialog this skill opens on a normal run.

### 2. Translate the seven constructs to the target's domain

The wheel is a security model; most targets are not systems. Before any team runs, the skill states the domain
translation it will use, so every team is asking a question that actually applies:

| Team       | Security role                      | The question it asks of any target                                                                                                             |
| ---------- | ---------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| **Red**    | Offense — prove an attack path     | How does this fail, get gamed, or get beaten? Who is served by its failure, and what is the strongest case against it?                         |
| **Blue**   | Defense — detect, contain, respond | For each Red finding: what mitigates it, what is the early-warning signal, and what contains it if it happens anyway?                          |
| **Yellow** | Builders                           | Can this actually be built or executed with the time, money, skills, and attention available? What does it really cost, and who does the work? |
| **Orange** | Red + Yellow                       | Which Red findings are _design_ flaws rather than incidents? What must change in the thing itself so the attack stops being possible?          |
| **Green**  | Blue + Yellow                      | What instrumentation, checkpoints, reversibility, and kill-switches must be built in from day one so failure is visible early and recoverable? |
| **Purple** | Red + Blue, fused                  | Do Blue's mitigations actually hold? (Not a perspective — the loop in Behavior 4.)                                                             |
| **White**  | Referee                            | What survived, what is the residual risk against the upside, what is the verdict, and which fixes matter most?                                 |

Red, Yellow, Orange, and Green are the only lenses that can form an opinion without another team's output. That is
why they, and only they, run as the parallel wave.

### 3. Round 1 — the full wheel pass

Read [references/team-prompts.md](references/team-prompts.md) before spawning anything — it holds the literal
scaffold each team receives, and a team prompted generically produces generic findings. Red additionally works
[references/attack-library.md](references/attack-library.md), which is its version of an ATT&CK matrix: twelve
attack classes with per-domain cash-outs. A checklist of concrete techniques outperforms an invitation to be
creative, which is the entire reason ATT&CK exists.

Two waves:

- **Wave A (parallel):** Red, Yellow, Orange, and Green, each a separate subagent with no visibility into the
  others' findings and no access to this conversation beyond the resolved target. Independence is the point — a
  shared context is how four lenses collapse into one opinion.
- **Wave B:** Blue, seeded with Red's findings. Blue running before Red exists has nothing to defend against, so
  this wave is sequential by construction, not by preference.

Every finding, from any team, must be specific and located: the claim, the concrete failure scenario that makes it
real, and — for Blue — the mitigation with its early-warning signal. Bare adjectives ("risky", "solid", "won't
scale") are rejected back to the team for specifics; they are not findings.

Red is prompted as a genuine adversary: assume the target is flawed and hunt its weakest point, rather than
producing a balanced assessment. A balanced Red team is a wasted agent — White does the balancing.

### 4. Rounds 2 onward — the Purple loop

This is where the exercise earns its cost. Blue proposing a mitigation nobody tested is the standard failure mode
of an idea review: it ships as "handled" while the hole is still open.

Each Purple round is two agents:

1. **Red re-attacks** every mitigation Blue proposed last round, and is told explicitly that breaking a mitigation
   is the goal — not re-listing what it already found.
2. **Blue responds** to whatever broke, either with a stronger mitigation or by conceding the finding as
   unmitigated. A conceded finding is a legitimate outcome and carries forward to White as residual risk.

**Converged** means a Purple round in which Red surfaces no new _material_ finding — one that would change the
verdict or add a line to the ranked fix list. A rephrasing of an already-open finding is not new.

**Cap:** round 1 plus at most 3 Purple rounds, 4 total. At the cap the run reports what is still contested rather
than continuing — a still-contested finding reaches White flagged as unresolved, never silently dropped.

**Ledger:** the loop's state — per finding, whether it is open, mitigated, broken, conceded, or unresolved — is
carried by the orchestrating session at default depth, and by the `Workflow` script's own loop state at `--deep`,
the same pattern `gauntlet-loop` uses. A finding closes only when Blue has a mitigation _and_ the following Red
round failed to break it. Red's silence alone never closes a finding.

Yellow, Orange, and Green are recalled only if the design materially changes mid-loop — i.e. Blue's mitigation
alters what is being built, not just how it is watched. Recalling them every round would re-emit round 1 in
different words at full price.

### 5. White — verdict and ranked fixes

White runs once, last, and is the only agent that sees everything: all findings, the full ledger, what broke, what
held, and what was conceded. Its output is two things and nothing else:

**The verdict**, exactly one of:

- **PROCEED** — nothing surviving is material. Ship it.
- **PROCEED WITH CONDITIONS** — sound, but specific fixes must land first. White names which conditions gate it.
- **REVISE** — a design flaw Orange identified makes the current shape wrong. The idea may survive; this version
  doesn't.
- **KILL** — an unmitigated finding is fatal, or the cost Yellow priced exceeds the upside.

**The ranked fix list**: each entry states the change, the team that found the need, and the specific failure it
closes. Ranking is by the damage each fix prevents, not by effort. Fixes are prescribed, never applied.

White is also the only place a finding's severity is judged. Individual teams report what they found; weighting is
White's job alone, which is what keeps Red's maximalism from becoming the verdict by default.

This separation is the direct lesson of **Team B (1976)**, the canonical red-team failure: a panel selected for
pessimism worst-cased a threat assessment, was substantively wrong about the magnitude, and had its findings taken
as conclusions. The 1978 Senate committee endorsed competitive analysis as a concept while faulting Team B's
composition — the concept survives only when the adversary does not also write the verdict.
[references/practice-and-sources.md](references/practice-and-sources.md) §5 maps each Team B failure to the
guardrail it produced here.

### 6. Depth tiers

**Default** — subagent fan-out from the orchestrating session. Round 1 is 5 agents, each Purple round is 2, White
is 1: roughly 8–12 agents per run. Cheap enough to fire casually, which is the point of the tier existing.

**`--deep`** — the same structure on the `Workflow` tool, plus adversarial verification: before White scores it,
every surviving Red finding faces independent skeptics prompted to _refute_ it, and a finding a majority refutes is
dropped. This is what stops a plausible-but-wrong finding from reaching the verdict. If the `Workflow` tool is
unavailable in the session, `--deep` says so and stops rather than silently running the default tier — D asked for
verification and would otherwise get an unverified answer that looks identical.

`Workflow` scripts cannot call `Date.now()`, so the report's timestamp is stamped by the orchestrating session
after the run returns, never from inside the script.

### 7. Report

The verdict and the top fixes always print inline — that is the answer, and it should not require opening a file.
The full report — every finding, every mitigation, the ledger, what was conceded, and what was refuted at `--deep`
— is written to the project's temp convention, `.tmp/reports/colorwheel-<slug>-<timestamp>.md` in this repo, and
never to a repo root or source directory. The resolved path is stated, never asked about.

Agent count and round count are reported with the verdict. A run that hits the round cap, or that dropped findings
at `--deep` verification, says so explicitly — a truncated review that reads as a complete one is worse than no
review.

## References

Bundled with the skill — read the first two before a run, not after.

- [references/team-prompts.md](references/team-prompts.md) — the literal prompt scaffold for every team, plus the
  shared finding format. Load before spawning Wave A.
- [references/attack-library.md](references/attack-library.md) — Red's twelve attack classes (assumption inversion,
  incentive/Goodhart, adversarial user, base rate, stress, dependency, timing, reversibility, second-order,
  selection bias, steelman, falsifiability), Blue's seven mitigation classes, and a per-domain cash-out table.
  Red and Blue both work it.
- [references/worked-examples.md](references/worked-examples.md) — three complete runs (a pricing decision, a
  caching design, a written claim), each showing findings that were accepted, findings that were rejected as
  generic, a Blue mitigation broken in the Purple loop, and how White resolved it.
- [references/practice-and-sources.md](references/practice-and-sources.md) — the real-world grounding: the color
  wheel's origin (Wright, Black Hat 2017), the lineage from the Vatican _advocatus diaboli_ through Kriegsspiel to
  UFMCS, what the empirical literature actually shows (Schwenk's meta-analyses, Klein's premortem, Schweiger et
  al.), Zenko's six best practices mapped to this skill's mechanics, the Team B failure modes, and how AI red
  teaming and purple teaming do this today. Full citations.

Two findings from that literature shape the design and are worth stating up front: structured dissent
**outperforms no-conflict review**, but no specific dissent structure has been shown superior to another — so this
skill claims only the former. And structured conflict **costs decision acceptance** even as it raises decision
quality, which is why the output is a ranked, prescribed fix list issued by a separate referee rather than an
undifferentiated pile of objections.

## Guardrails

- Read-only, always. This skill never edits the target, never commits, never opens a worktree. Blue and Green
  produce prescriptions; applying them is a separate, explicit act by D or another skill.
- Team prompts come from [references/team-prompts.md](references/team-prompts.md), not improvised per run. An
  improvised Red prompt reliably produces a balanced essay, which is the one thing Red must not return.
- Red is prompted adversarially but is never handed a conclusion to reach. A team selected or steered toward a
  predetermined finding is advocacy, not a red team — the specific, documented failure of Team B (1976).
- No agent grades its own homework (Zenko). Red never evaluates its own findings' severity, Blue never judges
  whether its own mitigation held, and the verdict is issued by an agent that produced none of the findings.
- Genuine security work is not this skill. Real penetration testing, vulnerability assessment, or auditing a live
  system routes to `/security-review` or the `security-auditor` agent. `/colorwheel` uses the color wheel as a
  reasoning structure and produces no security assurance about any real system.
- All seven constructs fire on every run. Sequencing differs by construct (Behavior 3-5) but no construct is
  skipped because the target seems not to need it — that judgment is White's, after the fact, not a pre-filter.
- Purple is never spawned as a round-1 parallel agent. It has no inputs to fuse before Red and Blue have run; it is
  the loop in Behavior 4.
- Wave A agents never see each other's findings. Four lenses sharing a context is one lens.
- Every finding is specific and located — claim, concrete failure scenario, and for Blue a mitigation with its
  early-warning signal. Adjectives alone are rejected back for specifics, never recorded as findings.
- Red is prompted adversarially, not neutrally, and its maximalism is expected. Balancing happens once, in White.
- A finding closes only when Blue mitigated it _and_ the next Red round failed to break that mitigation. Red not
  re-raising a finding is never sufficient on its own.
- Conceded and unresolved findings always reach White and always appear in the report. Nothing is dropped for
  being inconvenient to the verdict.
- The loop is capped at round 1 plus 3 Purple rounds. Hitting the cap is reported as a fact of the run, not
  smoothed over into a clean verdict.
- The verdict is exactly one of PROCEED / PROCEED WITH CONDITIONS / REVISE / KILL. No hedged or compound verdicts —
  conditions are what PROCEED WITH CONDITIONS is for.
- `--deep` without the `Workflow` tool stops and says so. It never degrades to the default tier while still
  labelling itself deep.
- This skill does not fire on a passing "is this any good?" or "any thoughts?" inside an ordinary request. It needs
  explicit invocation or unmistakably vetting-shaped language — a multi-agent run is not a conversational reflex.
- Any dialog this skill opens (target disambiguation only, on a normal run) goes through the `ask` skill's
  `AskUserQuestion` format, never plain-text prose questions.
- Setup failures — a subagent or `Workflow` invocation failing to start — retry up to 3 times per this project's
  `CLAUDE.md` Verification convention, then report with diagnostics rather than continuing with a partial wheel.
