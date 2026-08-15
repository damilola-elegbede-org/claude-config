# Worked Examples

Three full runs across the three target types this skill sees. Each shows what a real finding looks like, what
gets rejected, how the Purple loop breaks a mitigation, and how White resolves it.

Findings are abridged — a real run returns more per team. What is not abridged is the _shape_: **id, claim,
location, scenario, stake**. The examples use the canonical ID format throughout: `R1-F1` is Red's first finding
from round 1, `O1-F1` is Orange's first, `R1-M1` is Blue's mitigation answering `R1-F1`, and `R2-F1` is a finding
that first appeared in round 2. Blue's mitigations are written `R1-M1 → R1-F1`, showing the `responds_to` link;
`R1-M3-r2` is a revised mitigation (`revision_of: R1-M3`) replacing a broken `R1-M3`. `location` is compressed into the claim here because
these targets are prose — on a code or document target it is an explicit `file:line` or section reference.

---

## Example 1 — A business decision

**Target:** "Should we charge per-seat or per-agent-hour?"
**Domain:** pricing decision, prose, no artifact on disk.

### Round 1

**Red** (4 of 9 findings)

> **R1-F1.** Per-agent-hour bills against a unit we cannot currently measure.
> _Scenario:_ A customer disputes a $2,400 invoice. We have no per-customer agent-hour ledger — only aggregate
> API spend — so we cannot reconstruct the bill. We refund in full to keep the account.
> _Stake:_ full revenue loss on disputed invoices, plus the credibility cost of a bill we can't defend.
>
> **R1-F2.** An agent that loops burns the customer's money and blames us.
> _Scenario:_ A misconfigured workflow retries 400 times overnight. A $200/mo customer wakes to a $4,100 invoice
> they did not authorize and did not benefit from.
> _Stake:_ refund plus churn plus the story they tell three peers.
>
> **R1-F3.** Per-agent-hour punishes exactly the behaviour we want to grow — heavy usage.
> _Scenario:_ The power user who would become the reference customer throttles their own usage in month two to
> control spend. Usage growth flattens and reads as weak product-market fit.
> _Stake:_ the metric we're raising on becomes the metric the pricing suppresses.
>
> **R1-F4.** Per-seat is trivially arbitraged when the "user" is an agent.
> _Scenario:_ One customer buys two seats and routes twelve engineers' work through a shared service account.
> _Stake:_ revenue decoupled from value delivered, and no clean way to enforce without invasive monitoring.

_Rejected as a finding:_ "Usage-based pricing can be unpredictable for customers." True of the category, applies
to a neighbouring sounder version, no scenario, no stake. Generic criticism (see `attack-library.md` §Calibration).

**Yellow**

> Metering per-agent-hour requires per-customer attribution through the whole fleet — currently the traces are
> per-run, not per-tenant. That is 3–5 weeks of work touching the run logger, the billing join, and the invoice
> renderer. Nobody is currently assigned to billing. Per-seat ships in under a week against the existing Stripe
> integration.

**Orange** _(design flaws, not incidents)_

> **O1-F1.** R1-F1 is not an incident, it is a design flaw. Any pricing model that bills against an unmeasured unit
> produces disputes structurally, not occasionally. The redesign: metering is a _prerequisite_ to the pricing
> model, not a follow-up to it. Cost of not fixing: defending every invoice by hand, forever.
>
> **O1-F2.** R1-F2 is also structural. Unbounded consumption billing with no ceiling makes catastrophic invoices a
> matter of when. The redesign is a hard cap, not vigilance.

**Green**

> Leading indicator: the ratio of agent-hours billed to outcomes delivered per customer. It moves before churn
> does. Checkpoint: a pre-committed review at 90 days with an explicit criterion — if median customer spend
> varies more than 3x month over month, the model is wrong. Kill switch: pricing changes are reversible for the
> first two cohorts if we do not publish the rate card as permanent. Irreversible: the first public rate card.
> Publishing "$X/agent-hour" and retracting it costs more than launching late.

**Blue** _(seeded with Red's 9)_

> **R1-M1 → R1-F1:** Build per-tenant metering before announcing. _Signal:_ metering coverage < 100% of billable runs.
> _Containment:_ invoice manually for the first 10 customers. _Residual:_ metering itself can be wrong.
> **R1-M2 → R1-F2:** Hard per-customer monthly cap, default $500, raised on request. _Signal:_ any account at >70% of
> cap mid-month. _Containment:_ hard stop at cap, not a warning. _Residual:_ a legitimate heavy user hits the cap
> at 2am and work stops.
> **R1-M3 → R1-F3:** Volume discount tiers so marginal cost falls with usage. _Signal:_ usage growth decelerating in
> cohort month 2. _Residual:_ discounting erodes the margin the model exists to protect.
> **R1-M4 → R1-F4:** _Concede._ Seat enforcement against agent traffic requires monitoring we are not willing to build.

### Round 2 — Purple

**Red re-attacks:**

> **Broke R1-M3.** Volume discounts don't address R1-F3, they relocate it. The user still watches a meter; they just
> watch it at a better rate. _Scenario:_ the power user still self-throttles in month two, because the anxiety is
> about unpredictability, not unit price. Discounting changes the price and not the predictability.
> **Broke R1-M2, partially.** A hard stop at cap creates a _new_ failure that did not exist: the customer's
> production workload halts mid-run at 2am with no human awake. We converted a billing risk into an availability
> risk and did not tell anyone.
> **R1-M1 holds.** Metering-before-announcing removes the precondition rather than managing it.
> **New finding R2-F1:** the $500 default cap is itself an anchor. Customers will read it as the expected spend,
> and it will suppress expansion revenue independently of anything else.

**Blue responds:**

> **R1-M3-r2** (`revision_of: R1-M3`)**:** Replace volume discounts with a _committed-spend_ model — customer picks
> a monthly ceiling up front and gets that capacity. Predictability is the product, not the discount. _Residual:_
> under-committed customers churn at renewal rather than mid-month.
> **R1-M2-r2** (`revision_of: R1-M2`)**:** Cap triggers a soft stop with a 24h grace window and an alert, not a
> hard stop. _Residual:_ a runaway loop can still spend one grace window's worth.
> **R2-F1:** _Concede._ Any default is an anchor. Choosing not to publish a default and setting it per-customer at
> onboarding trades the anchor for onboarding friction.

### Round 3 — Purple

> Red: nothing new. `R1-M3-r2` and `R1-M2-r2` hold under re-attack; R2-F1 is conceded rather than contested.
> **Converged.**

### White

**VERDICT: PROCEED WITH CONDITIONS** — per-agent-hour with committed spend, gated on metering.

**Conditions gating launch:**

1. **Per-tenant metering ships before the rate card is published.** _(Orange O1-F1 — design flaw. Closes R1-F1's whole
   class: you cannot defend a bill you cannot reconstruct.)_
2. **Committed-spend ceiling with a soft stop and 24h grace, not a hard cap.** _(Purple round 2 — Blue's first cap
   converted a billing risk into an availability risk. Closes R1-F2 without creating an outage.)_
3. **Set the ceiling per-customer at onboarding; publish no default.** _(R2-F1, conceded as unfixable in the
   abstract — accepts onboarding friction to avoid anchoring expansion revenue.)_
4. **Pre-commit the 90-day review criterion now, in writing.** _(Green — a checkpoint with no pre-committed
   criterion is momentum with a calendar invite.)_

**Accepted as residual risk:** seat arbitrage is unenforceable without monitoring we won't build (R1-M4, conceded) —
which is itself an argument for consumption pricing, so the concession is consistent with the verdict.

**Judged immaterial:** three Red findings about competitor response. Real, but they apply equally to every pricing
model considered, so they do not discriminate between the options in front of us.

---

## Example 2 — A technical design

**Target:** "Add a Redis cache in front of the pricing API to cut p99 latency."
**Domain:** system change, spec + existing code.

**Red** (abridged)

> **R1-F1.** Cache invalidation is not specified for the one case that matters: a price change mid-session.
> _Scenario:_ Ops updates a price at 14:02. A customer holds a cached quote for the TTL and checks out at 14:07 at
> the old price. We honour it or we break the checkout.
> _Stake:_ revenue leakage per stale quote, or a broken flow at the highest-intent moment.
> **R1-F2.** The cache becomes a hard dependency the moment it is fast enough to rely on.
> _Scenario:_ Redis is unavailable. Origin now sees 100% of traffic at a volume it hasn't served since the cache
> shipped, having never been load-tested at that level again.
> _Stake:_ the cache outage becomes a full outage — worse than no cache.
> **R1-F3.** p99 latency may not be cache-bound at all.
> _Scenario:_ The p99 tail is dominated by a slow downstream FX lookup on cache-miss paths. Caching the wrapper
> leaves the tail untouched and the project reports success on p50 while p99 is unchanged.
> _Stake:_ weeks spent, the actual problem still present, and a metric that hides it.

**Yellow:** two weeks including load tests, but only if the FX lookup is profiled first — otherwise the estimate
is for the wrong work.

**Orange:** R1-F2 is a design flaw. A cache that silently becomes load-bearing is structural; the redesign is an
explicit degraded mode with origin capacity provisioned for full traffic, not a monitoring alert.

**Green:** instrument cache hit ratio _and_ origin-capacity headroom from day one; the leading indicator for R1-F2 is
headroom falling, which happens months before the outage. Kill switch: a flag that bypasses cache entirely — and
it must be exercised in production monthly, or it is not a kill switch, it is a hope.

**Blue → Purple:**

> R1-M2: "Alert on Redis health." **Broken** — an alert doesn't create origin capacity; it tells you the outage
> started. Blue revises to: provision origin for 100% of peak and re-test quarterly. Holds.
> R1-M3: "Profile before building." **Holds** — removes the precondition.

**VERDICT: REVISE.** _(Orange O1-F2 — the current design makes the cache load-bearing without provisioning for its
absence. The idea survives; this version doesn't.)_
Top fix: profile the p99 tail before building anything (R1-F3 — if the tail is FX-bound, the entire project is aimed
at the wrong target and every other finding is moot).

---

## Example 3 — A written claim

**Target:** a draft post claiming "our agent fleet cut PR review time by 60%."
**Domain:** artifact, a claim with evidence behind it.

**Red**

> **R1-F1.** Selection effect in the sample. _Scenario:_ the 60% is measured over PRs the fleet chose to review —
> which skew small and mechanical. Large PRs still queue for humans and are excluded.
> _Stake:_ the claim is true of the sample and false of the population; one informed reader recomputing it
> publicly costs more credibility than the post earns.
> **R1-F2.** "Review time" is undefined. _Scenario:_ if it means time-to-first-comment, an instant bot comment moves
> it to near zero without any review having happened. Time-to-merge probably did not move at all.
> _Stake:_ the strongest reading is trivially true; the interesting reading is unsupported.
> **R1-F3.** No control period. _Scenario:_ team headcount and PR volume both changed in the window.
> _Stake:_ attribution to the fleet is unsupported by the data as gathered.

**Orange:** R1-F2 is a design flaw in the claim itself, not a wording problem — a metric that improves when nothing
happens will keep producing misleading numbers regardless of how this one sentence is phrased.

**Green:** state the definition, sample, and window inline. Falsifiability check: what would make you retract
this? If nothing would, don't publish it.

**Blue:** "Add a footnote defining review time." **Broken in Purple** — a footnote does not fix a metric that is
wrong; it discloses that it is wrong in smaller type. Revised: report time-to-merge on all PRs, with the sample
and window stated in the sentence itself, and drop the single headline percentage if it does not survive.

**VERDICT: REVISE.** The finding is likely real but the claim as written does not survive its own evidence. Fixes:
(1) recompute on all PRs, not fleet-selected ones; (2) report time-to-merge, defined inline; (3) state the window
and what else changed in it; (4) if the number drops below the threshold worth posting, that is the answer.

---

## What the examples are demonstrating

- **A finding is claim + scenario + stake.** Everything without all three was rejected in every example above.
- **Orange is not a Red restatement.** In all three, Orange took one Red finding and said _this is structural_ —
  which is what moved Examples 2 and 3 to REVISE rather than PROCEED WITH CONDITIONS.
- **The Purple loop earns its cost.** In every example, at least one Blue mitigation broke. In Example 1, Blue's
  first cap converted a billing risk into an availability risk — a _new_ failure introduced by the fix, which a
  single-pass review would have shipped as "handled."
- **Concession is a real result.** R1-F4 and R2-F1 in Example 1 were conceded, reached White, and appear in the
  verdict as accepted residual risk rather than being quietly dropped.
- **White subtracts as well as ranks.** Example 1's competitor-response findings were real and still immaterial,
  because they did not discriminate between the options. Saying so explicitly is part of the verdict.
