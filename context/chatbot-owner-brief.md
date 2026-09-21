# The chatbot's owner-intelligence brief — what it asked for, and how it reads against the repository today

**Provenance.** Pasted by the owner on 2026-09-22 as `PharmaFlow chatbot owner…txt` ("PharmaFlow
chatbot: owner use cases and DeepSeek implementation brief", prepared for Rohit Jain). It is a
**third-party review**, not this repository's own plan: it says so itself, and it pins itself to
commit `25615b0d47008df16eb09db79011fbf1965fabf3` (19 September 2026), which is **60 commits back**
from `main` — it predates migrations `00031`–`00049` (Phase 6.5a, 6.5c and 7a) and therefore knows
nothing about the approval rail, the four sale types, or the sale document.

**It is not one of the plan's phases.** `MASTER_PLAN.md`'s sequence (6.5b → 7b → 7c) is unchanged and
still has the receiver app next; taking this brief up first was a **deliberate reorder** by the owner,
recorded in `PROGRESS.md` and in **D-089**.

**The full 160-question catalogue is NOT reproduced here** — it lives with the owner, and the twenty
directions below are its index. This file records *what the brief asks for*, *how its claims read
against the code as it is now*, and *which parts are done*.

---

## 1. What it got right (verified against the current code, not the pin)

Its diagnosis of the chatbot was accurate. Each of these was checked in the working tree and each was
still true when Phase A started:

| Its finding | Where it still was |
|---|---|
| "Bold cannot render" | `message_bubble.dart` rendered `Text(message.text)` |
| "Every summary sounds similar" | `answer.ts`'s `renderSummary` returned one fixed sales→purchases→stock paragraph |
| "Returned row count can be mistaken for full count" | every list template counted `rows.length` off a capped report |
| "Low-stock sentence and predicate disagree" | copy said *"at or below"*; `00027`'s report filters `total_qty < min_stock_level` |
| "Expiry answer may misstate horizon" | the sentence printed the model's `days`, not the horizon the report clamped to |
| The classifier has no entity parameter and no business clock | `schema.ts`: five reports, `^\d{4}-\d{2}-\d{2}$` date validation only |
| It cites D-026 (never free-form SQL) and D-053 (templated phrasing) as the constraints to keep | both decisions exist and say exactly that |

**Phase A status: the first five are CLOSED** (`f9be7d1`, `83cecc6`, `a4022d1`) except the exact
totals — see §3 below.

## 2. Where it collides with decisions this repository has already made

Flagged rather than implemented as written, because two of its sections re-derive, or contradict,
things already recorded here:

- **Its §7 "cost snapshot work" and its Direction 03 (profit) re-derive a decided shape.**
  `MASTER_PLAN.md` → Phase 7 §2 / **D-068** already specifies `sale_items.cost_basis_per_unit`,
  `cost_total` and `gross_profit` as **immutable sale-time snapshots**, and already settles that a
  hospital's share is computed on **GST-inclusive** gross profit. The brief proposes a different column
  set (`sale_item_cost_per_base_unit`, `cost_amount`, `cost_method`, …) as though nothing existed. New
  names for a decided shape would be the second mechanism this repository forbids; **the repo's own
  record wins, and the brief's Direction 03 is Phase 7b/7c's work rather than new work.**
- **Its §6 four-pharmacy access model is a proposal, not a finding.** It is *right* that
  `profiles.pharmacy_id` + `get_my_pharmacy_id()` is single-pharmacy and cannot serve an owner
  dashboard — but `MASTER_PLAN.md`'s Phase 7 tenancy note says the opposite about the *layer* ("four
  pharmacies is four rows and four sets of rules, not a new tenancy layer"). Whatever gets built for
  cross-outlet owner reading, the `organizations` / `organization_memberships` sketch is **not
  recorded anywhere** and the owner has not been asked. Treat §6 as an open design question.
- **Its §4 acceptance scenario 6 ("an arbitrary supplied pharmacy/organization ID cannot broaden
  access") is already the standing rule** (D-004: the tenant is never an argument) and is asserted in
  the committed SQL tests.

## 3. The gap table (§5), item by item, as it stands now

**Fixed by Phase A:**

- Bold cannot render → the emphasis marker (D-089 §1).
- Every summary sounds similar → a summary declares its `subject` (D-089 §3).
- Low-stock wording vs its predicate → the copy now says "below" (D-089 §2).
- Expiry horizon misstated → the sentence is written from the query that ran (D-089 §4).
- Capped rows read as a full count → **partly**: a full page now says "at least". The exact
  `total_count` still needs the `{meta, rows}` envelope (below).

**Still open, and now with a reason each:**

- **Exact totals and `has_more`** need the two `00027` reports to answer in the `{meta, rows}` shape
  `top_products` and `dead_stock` already carry. That is a **live RPC's contract**, so it must ship
  with the alert screens that read it (`notifications_repository.dart`, `inventory_repository.dart`,
  `alert_payloads.dart` and their tests) — its own chunk, named in D-089's consequences.
- **The date validation is format-level only** (`asDate` is a shape check) and there is **no trusted
  business clock** in the classifier input; `report_summary` falls back to `current_date` server-side.
  A "today" that resolves in the database's timezone is a real gap and is not fixed.
- **`report_summary` mixes current stock into a historical period** — its `stock` section has no
  historical cutoff. D-089 §3 stops the *sentence* from attaching a period to stock ("Stock on hand
  **now**"), which is the honest half; the envelope still has no snapshot.
- **Cross-outlet owner access** is absent (§2 above).
- **Exact historical profit/COGS** is Phase 7b/7c (D-068).
- **Receipts ≠ invoice-paid amounts**: `report_summary` sums `sales.amount_paid` by `sale_date`, and
  customer-linked checkout receipts are also in `payments`. The brief's "collections trap" is real and
  untouched.
- **Inactive products are excluded from `expiring_batches`** (`p.is_active`) — a genuine exposure gap,
  and a behaviour change to a committed report, so not done.
- **`dead_stock`'s never-sold branch has no first-receipt age test** — newly stocked items qualify as
  dead.
- **The staff audit trail covers seven document tables**, not the masters or every line (migration
  `00019`).

## 4. The rollout it proposes (its §10), and which parts are done

| Its phase | What it is | Status |
|---|---|---|
| **A** | readable rich answers, localized templates, relevant metrics, period/scope/provenance, honest limitations, the wording/count/horizon fixes | **PARTLY DONE** — rendering, subject selection and all three fixes are in; **language templates and follow-up chips remain** |
| **B** | organization/outlet membership, outlet selector, all-authorized-store mode, product identity mapping, product stock lookup, party balances, invoice drill-down | not started |
| **C** | cost policy, sale/return cost snapshots, payment source/allocation data, cash closing, profit/receivables/payables/collections/expense reports | not started — **and its cost half is Phase 7b/7c's (D-068)** |
| **D** | supplier terms, return deadlines, lead times, lost-demand capture, inventory state, transfer workflows, reorder/expiry/dead-stock/transfer recommendations | not started |
| **E** | saved reports, durable scoped context, exports, task status, schedules/channels | not started |

## 5. The twenty directions, as the capability backlog (its §3)

Each is one line of purpose; the brief's 160 numbered questions (Q001–Q160) sit under these headings in
the owner's copy. The tags were the brief's own coverage classification — **A** existing report
foundation, **B** new report over existing data, **C** new foundation needed, **D** external
integration needed — and **B/C are not "already working"**; nothing here should be described as
supported until it is.

1. **Daily business and sales overview** — "aaj business kaisa raha?" without opening screens (mostly B).
2. **Specific invoices and product sales** — from a total to its supporting transactions (B/C).
3. **Profit, margin and expense control** — revenue vs profit, margin explanations (C: needs COGS).
4. **Current stock and availability** — exactly what is available and where (B/C: sellable vs physical).
5. **Expiry, batch exposure and recall** — recoverable stock before it becomes a loss (B/C/D).
6. **Dead stock and money tied up** — capital that can be released (A/B/C).
7. **Reorder planning and lost demand** — prevent stockouts without overbuying (C).
8. **Purchasing, supplier rates and schemes** — actual buying cost, not invoice headline rates (A/B/C).
9. **Supplier payments and credit control** — what is owed, when, and which credits are pending (B/C/D).
10. **Customer and hospital receivables** — collect without confusing it with sales (B/C/D).
11. **Cash drawer, UPI and bank matching** — book entries vs money actually received (B/C/D).
12. **Comparing four pharmacies** — owner-level decisions across authorized stores (C).
13. **Inter-pharmacy transfer planning** — use stock already owned before buying more (C).
14. **Returns, damages and supplier claims** — the financial result of a return (B/C).
15. **Staff activity and exception review** — entries worth checking, with evidence (B/C).
16. **Customer service and repeat business** — availability and service, never clinical advice (B/C).
17. **Product identity and data quality** — the same query meaning the right medicine (B/C).
18. **Tax data, registers and export readiness** — records for review, not a claim of compliance (B/C/D).
19. **Forecasting and what-if planning** — options and assumptions, never facts (C).
20. **Owner workflows, alerts and conversation controls** — routines, saved views, exports, tasks (B/C).

## 6. Its acceptance scenarios (§12) — the testable spec, kept

Thirty of them, and worth keeping as the backlog's definition of done. The ones Phase A touches:

1. "Aaj sale kitni hai" resolves on the configured local day at the UTC/IST boundary — **not done** (no
   business clock).
2. "Kal" in a follow-up resolves consistently; an invalid range asks for clarification — **not done**.
3. A sales question shows the requested sales metrics, not a generic paragraph led by purchases —
   **done** (`83cecc6`).
4. Assistant bold renders as bold; user input is displayed safely; tables work on mobile — **bold done,
   no tables yet** (`f9be7d1`).
12. Limited results show the full total or explicitly state only returned rows — **done as "at least N"**
   (`a4022d1`); an exact total is the envelope chunk.
14. Expiry display uses the SQL-effective horizon and separates already-expired — **done** (`a4022d1`;
   the expired/upcoming split was already there).
24. LLM/provider failures yield an actionable error state, not an empty business result — **already done**
   pre-existing (D-042/D-033).
25. Prompt-like instructions in product names or questions cannot invoke SQL or business writes —
   **already the standing rule** (D-026; history is carried as data and labelled as context).

## 7. Its "files DeepSeek should inspect" (§11) — read against the repo

Its file list is broadly right, with two corrections worth recording: the chat UI's screen is
`app/lib/features/chatbot/presentation/chatbot_screen.dart` (there is no `chatbot/presentation/…`
directory beyond it), and the dependencies it lists as untouchable are pinned in `app/pubspec.yaml`
(Riverpod 3.0.3 codegen, Freezed 3.2.3, Dart ^3.8.0) — **this project does not move them for a
rendering convenience**, which is why the marker is a hand-written reader rather than a markdown
package.
