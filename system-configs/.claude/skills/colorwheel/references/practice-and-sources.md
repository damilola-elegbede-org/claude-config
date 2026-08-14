# Practice and Sources

This skill is not a metaphor. Structured adversarial review is a real, documented discipline with a lineage, an
empirical evidence base, published best practices, and well-studied failure modes. This file records what that
literature actually says and how each finding is encoded in the skill — so the design can be checked against the
practice rather than asserted.

## 1. Where the color wheel comes from

The **InfoSec Color Wheel** was introduced by **April C. Wright** in _Orange Is the New Purple_ at **Black Hat USA
2017**. Wright's contribution was adding **Yellow** — the builders — to the classic Red/Blue pair, which makes the
secondary teams possible: Red + Blue = Purple, Red + Yellow = Orange, Blue + Yellow = Green, with **White** as the
neutral coordinating function. **Louis Cremen** later popularized it as a single infographic in _Introducing the
InfoSec colour wheel_ (HackerNoon).

The wheel's own thesis is the reason this skill uses all seven rather than just Red and Blue: Wright's argument is
that Builders, Defenders, and Breakers interact poorly, and that an organization is only secure when every color
is strong _and_ talking to the others. A two-team review reproduces exactly the gap she was describing.

Worth noting honestly: several commentators argue the colors are better understood as **mindsets or functions than
as literal teams**. That reading is the one this skill adopts — they are lenses applied to a subject, not staffing.

## 2. The lineage outside security

Red teaming predates computers by roughly a millennium, and its non-security lineage is what licenses applying it
to ideas, plans, and drafts rather than only to systems:

- **The Devil's Advocate** (_advocatus diaboli_) — the Vatican office, dating to roughly the 11th century, formally
  charged with arguing _against_ candidates for sainthood. The original institutionalized structured dissent, and
  the direct ancestor of the modern term.
- **Kriegsspiel** — the Prussian General Staff's 19th-century wargame, where an opposing staff played the enemy
  with real freedom of action rather than as a scripted foil.
- **Israel's AMAN military intelligence directorate** — post-1973 reforms institutionalizing a dissent function
  after an intelligence failure attributed to consensus.
- **CIA Team A / Team B (1976)** — the canonical competitive-analysis exercise, and the canonical cautionary tale.
  See §5.
- **UFMCS, Fort Leavenworth** — the U.S. Army's _University of Foreign Military and Cultural Studies_, whose **Red
  Team Handbook** was renamed **The Applied Critical Thinking Handbook**. Its stated premise is that organizations
  "court failure in predictable ways, by degrees and almost imperceptibly, according to their mindsets, biases, and
  experience" — and that these failure sources are simple, observable, repeated, and preventable. Its tool index
  includes Premortem Analysis, Key Assumptions Check, Problem Restatement, Outside-In Thinking, Quality of
  Information Check, Mitigating Groupthink, and Logic of Failure — several of which appear in this skill's
  `attack-library.md`.
- **Business adoption** — **Bryce Hoffman**, _Red Teaming: How Your Business Can Conquer the Competition by
  Challenging Everything_ (Crown Business, 2017), written after Hoffman attended the UFMCS Red Team Leader Program.
  His three-phase structure — question unquestioned assumptions, imagine what could go wrong and right, then
  apply contrarian thinking to the plan itself — maps closely onto this skill's Red → Orange/Green → Purple flow.

## 3. What the evidence actually says

The empirical record supports structured dissent, with real caveats this skill should not overstate.

**Structured dissent beats no dissent.** Schwenk's meta-analyses (1989, _Strategic Management Journal_ 10:303–306;
1990, _Organizational Behavior and Human Decision Processes_ 47(1):161–176) found **devil's advocacy outperformed
the no-conflict expert approach in general**. Schweiger, Sandberg & Ragan (1986, _Academy of Management Journal_
29(1):51–71) found both dialectical inquiry and devil's advocacy produced **higher-quality recommendations and
assumptions than consensus**.

**No clear winner among dissent methods.** Schwenk 1990 found neither devil's advocacy nor dialectical inquiry
reliably better than the other, and dialectical inquiry's advantage over the expert approach was _not_ demonstrated
on relatively ill-structured tasks. Implication for this skill: don't claim a specific structure is optimal — claim
only that structured adversarial review beats an unstructured single-perspective one, which is what the data
supports.

**Dissent has a cost the design must absorb.** Schweiger et al. found consensus groups reported **more
satisfaction, more desire to keep working together, and greater acceptance of the decision**. Structured conflict
buys decision quality and spends decision acceptance. This is precisely why **White exists as a separate,
weighting, verdict-issuing role** and why the output is a _ranked_ fix list rather than an undifferentiated pile of
objections — an unranked wall of criticism is the form most likely to be rejected wholesale.

**Prospective hindsight is a real effect.** Gary Klein's **premortem** (_Performing a Project Premortem_, HBR
85(9):18–19, September 2007) works by assuming the project **has already failed** and asking what _did_ go wrong —
not what _might_. Klein's basis is research showing that imagining an event has already occurred increases the
ability to identify future outcomes. Encoded in this skill: Red is prompted to prove the target flawed, not to
assess whether it might be, and Green is prompted to assume the target shipped and something is already wrong.
The known limitation applies here too — presuming failure can surface threats that are not in fact real, which is
exactly the error **White's weighting pass** and **`--deep`'s refutation pass** exist to catch.

**Structured techniques get skipped in practice.** RAND RR1408, _Assessing the Value of Structured Analytic
Techniques in the U.S. Intelligence Community_, studies why analysts don't use established tradecraft even when
trained in it. The operational lesson: a technique only helps if it is cheap enough to actually run — which is the
argument for this skill's default tier existing at all rather than everything requiring `--deep`.

## 4. Zenko's six best practices, and how this skill implements them

**Micah Zenko**, _Red Team: How to Succeed by Thinking Like the Enemy_ (Basic Books, 2015) — the most cited
practitioner synthesis, drawing on seventeen case studies across military, intelligence, homeland security, and
private sectors. His six best practices, mapped:

| Zenko's practice                                     | How `/colorwheel` implements it                                                                                                                |
| ---------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| **1. The boss must buy in**                          | D invokes it deliberately; findings are advisory and never applied. A red team run over the sponsor's objection produces reports nobody reads. |
| **2. Outside and objective, while inside and aware** | Wave A subagents get the target and nothing else — no conversation history, no prior findings. Independent, but scoped to the real subject.    |
| **3. Fearless skeptics with finesse**                | Red is prompted adversarially and explicitly told not to soften findings by proposing fixes; White supplies the finesse by weighting.          |
| **4. Have a big bag of tricks**                      | `attack-library.md` — 12 attack classes with per-domain cash-outs, so Red works a matrix instead of improvising and going stale.               |
| **5. Be willing to hear bad news and act on it**     | Conceded and unresolved findings always reach White and always appear in the report. Nothing is dropped for being inconvenient.                |
| **6. Red team just enough, but no more**             | Tiered depth; the Purple loop stops on convergence rather than running to a fixed count; Yellow/Orange/Green are not re-run each round.        |

Zenko's two recurring maxims are both load-bearing here: **"You cannot grade your own homework"** — which is the
entire argument for separate subagents over inline self-review — and **"The boss must buy in."**

His central caveat is the one this skill's guardrails encode: **not all red teams are created equal, and some cause
more damage than they prevent.**

## 5. Known failure modes — Team B and after

**Team B (1976)** is the canonical negative case, and every one of its failures has a matching guardrail.

President Ford's PFIAB commissioned outside groups to re-analyze the same classified data the CIA's "Team A" held.
Team B, led by Richard Pipes and including Paul Nitze, William Van Cleave, and Paul Wolfowitz, was **selected for
members inclined toward more pessimistic views**. The 1978 Senate Select Committee on Intelligence report
**supported competitive analysis as a concept but found the composition of Team B flawed**.

What went wrong, and the guardrail each produces:

| Team B failure                                                                       | Guardrail in this skill                                                                                                                                     |
| ------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Selection bias** — team stacked toward a predetermined conclusion                  | Red is prompted adversarially but is not _given_ a conclusion; White, which issues the verdict, sees every team's output and is a different agent from Red. |
| **Worst-casing over analysis** — critics called it "howling at the moon"             | Every finding requires a concrete scenario and a stake. Adjectives are rejected. `--deep` runs skeptics prompted to _refute_ each surviving finding.        |
| **Substantive inaccuracy** — predicted ~500 Backfire bombers by 1984; actual was 235 | Red's volume is explicitly not evidence of severity; White weighs, and is told this is the specific error it exists to prevent.                             |
| **Politicization / leaking**                                                         | Read-only, local, no external publication. The report goes to `.tmp/reports/` and nowhere else.                                                             |

The sharpest irony is worth keeping in view: a 1989 internal CIA review found the Soviet threat had been
**substantially overestimated** every year from 1974–1986 — so Team B was right that the estimate was flawed, and
wrong about the direction. **Being correct that something is wrong does not make your alternative right.** That is
why REVISE and KILL require an identified design flaw or an unmitigated finding, not merely Red's dissatisfaction.

A second documented failure mode: **red teaming as theater** — running the exercise for the appearance of rigor,
with no mechanism to act on the result. Zenko's practices 1 and 5 both target it. This skill's counterpart is that
its output is a _ranked, prescribed_ fix list tied to specific failures, not a discussion.

## 6. The modern practice this generalizes from

**Purple teaming and adversary emulation.** The mature form of Red/Blue is not two teams in opposition but a
feedback loop: Red runs a technique, Blue checks whether it alerted, detections get tuned, repeat. **MITRE ATT&CK**
made this systematic by turning "attack" into an enumerable matrix of techniques; **Atomic Red Team** and **MITRE
Caldera** let a defender fire individual techniques to validate detections without a full engagement. The design
principle this skill borrows: **a checklist of concrete techniques outperforms an invitation to be creative** —
hence `attack-library.md` rather than "think of what could go wrong."

**AI red teaming** is the most active current application and the closest analog to what this skill does, since its
target is model behavior rather than an exploitable system:

- **NIST AI RMF** places red teaming in the _Measure_ function; **NIST AI 100-2** provides the adversarial ML
  attack taxonomy, extended in its 2025 edition to LLM-specific vectors (prompt injection, jailbreaking) and to
  autonomous agent vulnerabilities including indirect prompt injection, memory poisoning, and tool supply-chain
  attacks. NIST's practical guidance is that **automated and manual testing must be combined** — neither alone is
  sufficient.
- **Frontier lab practice** differs enough to be instructive. Anthropic's frontier red teaming defines threat
  models first — what information is dangerous, how it combines into harm, and at what accuracy and frequency it
  becomes dangerous — then has domain experts spend 100+ hours probing, and runs multi-hundred-attempt campaigns.
  OpenAI iterates from a hypothesis of highest-risk areas across rounds as mitigations land. The **Frontier Model
  Forum**'s issue brief on red teaming covers the shared ground.
- **The standardization gap** is the field's acknowledged core problem: different developers use different
  techniques for the same threat model, making cross-system comparison unreliable. This is the same reason this
  skill fixes its structure, its finding format, and its verdict vocabulary rather than improvising per run.

One empirical result worth carrying: attack success against LLM-backed agents rose from **11% to 81%** when red
teamers developed techniques tailored to the specific target rather than reusing baseline patterns (CAISI with the
UK AI Security Institute, using AgentDojo). Generic attacks badly understate real exposure — which is why
`attack-library.md` requires every finding to be one that would _not_ apply to a neighbouring, sounder version of
the target.

## 7. Citations

**The color wheel**

- April C. Wright, _Orange Is the New Purple_, Black Hat USA 2017 —
  <https://www.blackhat.com/us-17/briefings.html>
- Louis Cremen, _Introducing the InfoSec colour wheel_, HackerNoon —
  <https://hackernoon.com/introducing-the-infosec-colour-wheel-blending-developers-with-red-and-blue-security-teams-6437c1a07700>

**Red teaming, practice and doctrine**

- Micah Zenko, _Red Team: How to Succeed by Thinking Like the Enemy_, Basic Books, 2015. CFR teaching notes —
  <https://static.cfr.org/sites/default/files/Red%20Team%20Teaching%20Notes.pdf>
- UFMCS, _The Applied Critical Thinking Handbook_ (formerly _The Red Team Handbook_), v8.1, Sep 2016 —
  <https://www.benning.army.mil/CFDP_INST_HW/content/2E%20Applied%20Critical%20Thinking%20Handbook%20v8%201_Sep'16.pdf>
- Bryce G. Hoffman, _Red Teaming: How Your Business Can Conquer the Competition by Challenging Everything_, Crown
  Business, 2017.

**Analytic tradecraft**

- CIA Center for the Study of Intelligence, _A Tradecraft Primer: Structured Analytic Techniques for Improving
  Intelligence Analysis_, March 2009 — <https://www.cia.gov/resources/csi/static/Tradecraft-Primer-apr09.pdf>
  (Key Assumptions Check p.7, Quality of Information Check p.10, ACH p.14, Devil's Advocacy p.17, Team A/Team B
  p.19)
- Richards J. Heuer Jr. & Randolph H. Pherson, _Structured Analytic Techniques for Intelligence Analysis_, 3rd ed.,
  CQ Press, 2021.
- RAND RR1408, _Assessing the Value of Structured Analytic Techniques in the U.S. Intelligence Community_ —
  <https://www.rand.org/content/dam/rand/pubs/research_reports/RR1400/RR1408/RAND_RR1408.pdf>

**Empirical evidence**

- Gary Klein, _Performing a Project Premortem_, Harvard Business Review 85(9):18–19, Sep 2007 —
  <https://hbr.org/2007/09/performing-a-project-premortem>
- Veinott, Klein & Wiggins, _Evaluating the effectiveness of the PreMortem technique on plan confidence_, ISCRAM 2010.
- C. R. Schwenk, _A meta-analysis on the comparative effectiveness of devil's advocacy and dialectical inquiry_,
  Strategic Management Journal 10:303–306, 1989.
- C. R. Schwenk, _Effects of Devil's Advocacy and Dialectical Inquiry on Decision Making: A Meta-Analysis_,
  Organizational Behavior and Human Decision Processes 47(1):161–176, 1990.
- Schweiger, Sandberg & Ragan, _Group Approaches for Improving Strategic Decision Making: A Comparative Analysis of
  Dialectical Inquiry, Devil's Advocacy, and Consensus_, Academy of Management Journal 29(1):51–71, 1986 —
  <https://journals.aom.org/doi/10.5465/255859>
- Irving L. Janis, _Groupthink: Psychological Studies of Policy Decisions and Fiascoes_, 2nd ed., 1982.

**Team B**

- Senate Select Committee on Intelligence, unclassified report on the Team A/Team B episode, 1978.
- Anne Hessing Cahn, _Killing Detente: The Right Attacks the CIA_, Penn State Press, 1998.
- Richard Pipes, _Team B: The Reality Behind the Myth_, Commentary, October 1986.

**Modern application**

- MITRE ATT&CK — <https://attack.mitre.org/> · Atomic Red Team — <https://github.com/redcanaryco/atomic-red-team>
  · MITRE Caldera — <https://caldera.mitre.org/>
- NIST AI Risk Management Framework — <https://www.nist.gov/itl/ai-risk-management-framework>
- NIST AI 100-2, _Adversarial Machine Learning: A Taxonomy and Terminology of Attacks and Mitigations_ (2025 ed.)
- Frontier Model Forum, _What is Red Teaming?_ —
  <https://www.frontiermodelforum.org/uploads/2023/10/FMF-AI-Red-Teaming.pdf>
- Anthropic, _Frontier threats red teaming for AI safety_ —
  <https://www.anthropic.com/news/frontier-threats-red-teaming-for-ai-safety> · _Challenges in Red Teaming AI
  Systems_ — <https://www.anthropic.com/news/challenges-in-red-teaming-ai-systems>
