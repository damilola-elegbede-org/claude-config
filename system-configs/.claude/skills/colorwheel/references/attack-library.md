# Attack and Mitigation Library

Red's equivalent of MITRE ATT&CK, generalized past security. ATT&CK works because it is a _checklist of concrete
techniques_ rather than an invitation to be creative — a red teamer who works the matrix finds things that one who
improvises misses. This file is that matrix for arbitrary targets.

Red works this list. Not every entry applies to every target; an entry that doesn't apply is skipped silently
rather than forced.

## Red — attack classes

### A1. Assumption inversion

List every load-bearing assumption, then negate each. The assumption nobody wrote down is the one that kills the
target, so surface the implicit ones first: what does this take for granted about users, markets, timelines,
people, or the world staying as it is?

- _Strong_: "This assumes customers churn at under 3%/mo. At 6% — the category median — payback never happens."
- _Weak_: "There are a lot of assumptions here."

### A2. Incentive attack (Goodhart)

Every mechanism rewards some behaviour. Ask what behaviour _this_ rewards, and what someone optimizing purely for
the reward would do. Then ask who is served by the target failing — inside the org, not just outside.

- Classic shape: the metric becomes the goal, the goal is abandoned, and the metric still looks good.

### A3. The adversarial user

Not the confused user — the one who actively wants to abuse, game, or extract from this. Free tiers get farmed,
refund policies get exploited, rate limits get parallelized, generous defaults get drained. For non-product
targets: who benefits from misreading this, and can they?

### A4. Base rate

What is the historical failure rate of this class of thing, and what specifically makes this an exception? "We'll
execute better" is not an exception. If the base rate is unknown, that itself is the finding.

### A5. Stress and scale

Break the operating range in both directions: 10x volume, 0.1x volume, 3x the timeline, half the budget, the key
person gone, the founder distracted, the champion leaving the account. Most designs are only sound in the range
their author imagined.

### A6. Dependency attack

Enumerate everything external that must stay true — a vendor, an API, a price, a regulation, a person's goodwill, a
platform's terms. For each: what is the day-one impact when it stops? Single points of failure hide in things
assumed permanent.

### A7. Timing attack

What if this takes three times as long? What has to be true about _when_ things happen in what order? Sequencing
failures — building the machinery before validating demand, announcing before you can deliver — are the most common
and least detected class in D's own build gates.

### A8. Reversibility

What is unrecoverable if this is wrong? Money spent, trust burned, data deleted, a public commitment, a hire, a
migration. Reversibility is not a nice-to-have — it is what determines how much of the rest of the analysis has to
be right.

### A9. Second-order effects

What does this cause that nobody is modelling? The fix that creates the next problem; the incentive that reshapes
behaviour a quarter later; the precedent that constrains the next decision. First-order reasoning is where most
plans stop.

### A10. Selection and survivorship

Is the evidence base biased? Comparable successes are visible; comparable failures are not. Enthusiastic early
users are not the market. Anyone who agreed with this in conversation is a biased sample of people who talk to you.

### A11. The strongest opposing case

Steelman the position that this is wrong. Not a caricature — the version a smart, informed person who has seen this
fail before would actually argue. If no such person could exist, the target may be unfalsifiable, which is finding
A12.

### A12. Falsifiability

What observation would prove this wrong? If nothing could, there is nothing to defend and no way to learn — this is
simultaneously Red's finding and Green's most urgent one.

## Blue — mitigation classes

Blue's mitigations should name their class. A mitigation that doesn't fit one is usually a wish.

| Class         | What it does                                   | Real example                                   | Not this                             |
| ------------- | ---------------------------------------------- | ---------------------------------------------- | ------------------------------------ |
| **Eliminate** | Removes the failure's precondition             | Don't hold the data at all                     | "Handle the data carefully"          |
| **Cap**       | Bounds the blast radius                        | Hard per-customer monthly spend limit          | "Watch for runaway usage"            |
| **Detect**    | Names a measurement and a threshold that fires | Alert when weekly active drops below N         | "Monitor engagement"                 |
| **Contain**   | Limits damage after the fact                   | Staged rollout, feature flag, rollback path    | "Be ready to revert"                 |
| **Transfer**  | Moves the risk to someone equipped for it      | Insurance, a vendor SLA, an escrow             | "They'll probably handle it"         |
| **Defer**     | Buys information before committing             | Pilot with 3 customers before the build        | "Start small" with no exit criterion |
| **Accept**    | Explicit, priced, recorded residual risk       | "We accept churn up to 6%; above that we stop" | Silence                              |

**Accept is a first-class answer.** A concession that names the exposure beats a mitigation that hides it. The
failure mode Blue must avoid is the control that sounds like control: _monitor, document, be careful, communicate,
align, keep an eye on._ None of those name a measurement, a threshold, or an actor.

## Domain cash-outs

The same attack class looks different by target type. Red should pick the framing that fits what it was handed.

| Attack              | Business/strategy target               | Technical/system target                     | Written artifact or claim                 |
| ------------------- | -------------------------------------- | ------------------------------------------- | ----------------------------------------- |
| A1 Assumptions      | Market size, churn, willingness to pay | Load profile, latency budget, data shape    | Premises stated as given                  |
| A2 Incentives       | What the comp plan actually rewards    | What the metric makes engineers optimize    | Who benefits from this framing            |
| A3 Adversarial user | Refund and free-tier abuse             | Injection, quota exhaustion, replay         | Quote-mining, motivated misreading        |
| A4 Base rate        | Category success rate                  | Failure rate of this pattern in production  | How often claims of this type hold up     |
| A5 Stress           | 10x customers, founder distracted      | 10x traffic, dependency at p99              | Does it hold at the edges it doesn't cite |
| A6 Dependency       | One channel, one big customer          | One vendor, one region, one library         | One source carrying every claim           |
| A7 Timing           | Build-before-validate ordering         | Migration order, deploy sequencing          | Conclusion that outruns its evidence      |
| A8 Reversibility    | Hires, public commitments, pricing     | Schema migrations, deletions, API contracts | Published statements, retractions         |
| A9 Second-order     | Precedent set for later decisions      | The fix's new failure mode                  | What readers will do with this            |
| A10 Selection       | Talking only to enthusiasts            | Testing only the happy path                 | Citing only confirming sources            |
| A11 Steelman        | The competitor's actual case           | The rejected simpler architecture           | The strongest counter-argument            |
| A12 Falsifiability  | What kills this idea                   | What would signal the design is wrong       | What evidence would retract it            |

## Calibration

Red's volume is not evidence of severity — White weighs. But two failure modes are Red's own to avoid:

- **Generic criticism.** "This might not scale" applies to everything and therefore says nothing. Every finding
  must be one that would _not_ apply to a neighbouring, sounder version of the target.
- **Attacking the strawman.** Attack what the target actually says, including its most careful reading. A finding
  that dissolves once someone clarifies the target was never a finding.
