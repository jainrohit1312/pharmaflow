# PharmaFlow — Master Plan

Roadmap for Phases 1-7, optimized for the 1M token context window: 2 phases
per chat with a ~600k handoff trigger, leaving buffer for degradation and
recovery.

---

## Chat Strategy

| Chat | Phases | Target context |
|---|---|---|
| 1 | Phase 0 | [DONE] ~110k |
| 2 | Phase 1 + Phase 2 | ~350k |
| 3 | Phase 3 + Phase 4 | ~390k |
| 4 | Phase 5 + Phase 6 | ~280k |

---

## Dependency Graph

```
Phase 0  Foundation (schema + RLS + auth + shell)   [DONE]
   |
   v
Phase 1  Masters (products, suppliers, customers)
   |
   v
Phase 2  Purchase + Inventory + Batch tracking
   |
   v
Phase 3  Sales/POS + Returns + GST billing
   |
   +--------------------------+
   |                          |
   v                          v
Phase 4  Ledger + Payments   Phase 5  AI OCR + Notifications
   |                          |
   +------------+-------------+
                v
Phase 6  Testing + Deployment + Documentation
```

Phase 4 and Phase 5 both depend only on Phase 3 (sales produce the ledger
entries Phase 4 reports on, and the real data Phase 5's AI matches against).
They can be built in either order; the chat plan keeps 4 in Chat 3 and
5 in Chat 4.

---

## Phase 1 — Masters (Product + Supplier + Customer)

**Goal:** Full CRUD for products (with multi-batch), suppliers, customers.

**Database (already exists):** `products`, `product_batches`,
`product_aliases`, `suppliers`, `customers`

**Flutter Files (~70):** `features/products/`, `features/suppliers/`,
`features/customers/`

Each module follows the same pattern:

```
data/<x>_repository.dart
application/<x>_list_controller.dart, <x>_form_controller.dart,
            <x>_detail_controller.dart
presentation/<x>_screen.dart, <x>_form_screen.dart, <x>_detail_screen.dart
presentation/widgets/<x>_card.dart, <x>_filter_bar.dart
```

**Estimated Context:** ~150k tokens

---

## Phase 2 — Purchase + Inventory + Batch Tracking

**Goal:** Purchase entry, GRN, batch/expiry tracking, stock levels.

**Database (already exists):** `purchases`, `purchase_items`,
`purchase_returns`, `purchase_return_items`, `stock_adjustments`

**Views:** `product_stock`, `batch_status`

The ledger/stock/audit trigger functions are already written in
`20260918000010_triggers.sql` but commented out with `TODO(phase-2)`
markers (lines 150, 200, 266, 298, 340). Enabling them is a migration, not
a rewrite.

**Flutter Files (~90):** `features/purchase/`, `features/inventory/`,
`features/returns/`

**Estimated Context:** ~200k tokens

---

## Phase 3 — Sales/POS + Returns + GST Billing

**Goal:** POS screen, GST invoice, sale returns, thermal print.

**Database (already exists):** `sales`, `sale_items`, `sale_returns`,
`sale_return_items`, `payments`

**Flutter Files (~120):** `features/sales/`, `features/returns/` (extend)

**Estimated Context:** ~250k tokens

---

## Phase 4 — Ledger + Payments + Reports

**Goal:** Supplier/customer ledgers, payment recording, P&L reports.

**Database (already exists):** `payments`, `ledger_entries`, `expenses`

**Flutter Files (~70):** `features/ledger/`, `features/reports/`

**Estimated Context:** ~140k tokens

---

## Phase 5 — AI OCR + Smart Matching + Notifications

**Goal:** Gemini Vision OCR, fuzzy product match, WhatsApp/FCM/Email.

**Database Changes:** enable `pgvector`, add `products.embedding` column,
add `device_tokens` table, add `notification_logs` table

**Supabase Edge Functions (~5):** `ocr-purchase-bill`,
`save-purchase-from-ocr`, `match-product`, `send-notification`,
`chat-sql-agent`

**Flutter Files (~80):** `features/purchase_ocr/`,
`features/notifications/`, implement service stubs

**Estimated Context:** ~180k tokens

**Chunks (built in Chat 4):**

- **A** — the database foundation (migration 00022: `pgvector`, the
  `products.embedding` column, `device_tokens`, `notification_logs`, the private
  `purchase-bills` bucket)
- **B** — the AI OCR core (`ocr-purchase-bill`, the capture/verify screen, the save)
- **C** — smart matching (`match-product`, the embedding backfill, the vector floor)
- **D** — notifications (`send-notification`, the two alert sources, the in-app inbox)
- **E** — the chatbot (`chat-sql-agent` and the two remaining aggregates) — **the
  last Phase 5 chunk**

Auto-send PO — send an approved PO to the supplier over their `preferred_channel` —
was a candidate sixth chunk and is **deferred to Phase 6** (D-052): it needs a
WhatsApp Meta account, a SendGrid key and supplier channel preferences, none of which
exist yet, and manual sending is adequate until they do.

---

## Phase 6 — Testing + Deployment + Documentation

**Goal:** Production readiness.

**Deliverables:** 80% test coverage, Windows build fix, Android APK,
iOS TestFlight, Vercel deploy, Edge Function secrets, user manual.

**Flutter Files (~50):** expand `app/test/`, `docs/`

**Estimated Context:** ~100k tokens

**Add-ons (deferred from Phase 5):**

- **Auto-send PO** (D-052) — on approval, send the PO to the supplier over their
  `preferred_channel`. It rides with Phase 6's deployment work because it waits on the
  same WhatsApp Meta account, SendGrid key and supplier channel preferences that
  Phase 6's Edge Function secrets and alert triggers (D-046) configure.

---

## Phase 6.5 — The Marg Import, the Receiver, and the Approval RBAC

**Recorded:** 2026-09-20. **A stub, and not detailed in the main** — the phase's items are the
owner's own names for it, and beyond the approval system's shape (below) nothing else is known,
so nothing else is written here. It exists so that Phase 7's sequencing pointer names a phase
that is actually in the plan.

**Three sub-chunks, in this order** (owner, 2026-09-20):

- **Phase 6.5a — the Marg import.** The data import from Marg.
- **Phase 6.5b — the receiver app.** A receiving role/flow.
- **Phase 6.5c — the full approval RBAC.** One unified approval mechanism for every action that
  needs one: a sale edit, a purchase delete, a return, a stock adjustment, **a discount above
  10%** (D-071), a customer or product edit.

**6.5c is specified as far as its shape:** action-type based — **a table with an `action_type`
enum and a `payload` jsonb**. **The exact list of action types is still to come from the owner**,
at 6.5c design time; it is recorded as an open question rather than guessed at.

**Decisions:** none yet — 6.5c's come first, and `DECISIONS.md`'s next free numbers are
**D-065** and **D-066**, left unwritten on purpose. Phase 7's are D-067–D-072.

**Estimated Context:** not estimated — the phase has no shape yet beyond the above.

---

## Phase 7 — Pharmacy Business Logic

**Recorded:** 2026-09-20. **A requirement record — nothing here is built or started.** It is
written down so the business rules are not re-derived later, and it is detailed enough to be
built from as written. **Revised three times on 2026-09-20**: the sale types went three →
three-plus-shares → **four**, and the profit-sharing partner went doctor → **hospital** with
fixed percentages.

**Goal:** the business logic of the pharmacy group — **four pharmacies, each inside a
different hospital**; **hospital** profit-sharing deals (50% / 60%, and **two real 0% deals**,
in exchange for premises and patient flow); and an owner who bears all the expenses.
**Doctors are recorded on sales for prescription compliance and take no share** (D-068, D-072).

**Sequencing (owner, 2026-09-20):**

```
Phase 6 chunk 4  →  the Vercel deploy            (where the project stands now)
Phase 6.5a       →  the Marg import
Phase 6.5b       →  the receiver app
Phase 6.5c       →  the full approval RBAC, with the schema for every action type
Phase 7a         →  the four sale types          (uses 6.5c's approval for the discount)
Phase 7b         →  hospital profit sharing
Phase 7c         →  the reports
```

**Built so far (2026-09-20) — Phase 7a's durable layer, and only that.** Four additive migrations
(`20260920000033`…`…000036`) and `supabase/tests/phase7a_sale_types.sql` (53 assertions, 0 FAIL)
carry: the `sale_type` enum and the `sales` columns (**eleven** of the twelve below — see D-067 on
the deferred approval FK); `admissions` and the patient fields on `customers` with a server-generated
patient code (**D-074**); the GST basis for a pharmacy sale, tax-inclusive with the product's own
slab winning and one named 5% default (**D-075**); `payment_allocations` plus `collect_payment()`
and the two balance readers; `hospitals` + `pharmacies.hospital_id` + `doctors` (pulled forward from
§2 and §D-072); and `checkout_sale()` rewritten to price and validate per type — with a documented
compatibility seam so a payload that names no `sale_type` behaves exactly as it did before.
**Nothing is pushed to the hosted project, and no Flutter file changed**: the POS flow, the widgets
and the keyboard contract are **not started**. **Not built, unchanged from the text below:**
`hospital_profit_sharing`, every share and settlement RPC (§2 — 7b), the reports (§5 — 7c),
`approval_requests` (6.5c), and the four markup percentages (§7 item 1).

**HARD DEPENDENCY: Phase 7a depends on Phase 6.5c's approval infrastructure.** No soft
reference and no client-invented id — `sales.discount_above_limit_request_id` is a **real
foreign key** to `approval_requests(id)`, so it cannot be created until 6.5c's table exists
(D-071). Phase 6 itself is still open: chunk 4's Vercel deploy and the provider credentials are
where the project stands.

**Tenancy note:** the multi-tenant model this needs **already exists** — `pharmacies`
(`supabase/migrations/20260918000003_core_tables.sql:3`), a `pharmacy_id` on every table,
per-tenant RLS (D-004) and `get_my_pharmacy_id()` server-side (D-015). Four pharmacies is four
rows and four sets of rules, not a new tenancy layer.

**Decisions:** **D-067** (four sale types), **D-068** (hospital profit sharing — percentages,
and 0% is a value), **D-069** (expense categories), **D-070** (the package service markup),
**D-071** (the discount cap and its approval), **D-072** (the doctors master).

### 1. Four sale types — D-067

"**Pharmacy sale**" is the business's umbrella name for the first two: both retail-priced,
both subject to the 10% discount cap (D-071), both carrying a hospital share (D-068).
**Package and transfer are separate categories** — no discount concept and no share.

| Type | Rate | Hospital share | Bill fields |
|---|---|---|---|
| `counter` — walk-in, hospital or outside patient | MRP − discount | **yes** | `patient_name` (**mandatory**), `patient_mobile` (**mandatory**), `patient_address` (optional), `doctor_name` (**mandatory for Schedule H/H1/X**) |
| `ipd_admission` — an admitted patient | MRP − discount | **yes** | the counter fields **+** `hospital_reference` (OPD/IPD number, **mandatory**) |
| `package` — the hospital buying for its package patients | purchase rate + `pharmacies.package_markup_percent` | **no** — the hospital is the *buyer* (D-070) | patient name + mobile **required** (revised 2026-09-20, D-067 — traceability, while the hospital stays the debtor); `hospital_reference` |
| `transfer` — stock moving between locations | purchase rate, **no markup** | **no** | `from_location`, `to_location`, `transfer_reason` (the brief's `reason`), `transfer_note_no` |

An **IPD sale is not a package sale**: it is a retail-priced sale to an admitted patient. A
transfer never leaves the owner's hands, so **no GST** is charged on it.

**Schema:** the `sale_type` enum (`counter`, `ipd_admission`, `package`, `transfer`), plus
twelve columns on `sales` — `sale_type` (`not null default 'counter'`), `hospital_id`
(**snapshot**, from the pharmacy's own hospital), `patient_name`, `patient_mobile`,
`patient_address`, `doctor_name`, `doctor_id` (→ `doctors`, D-072), `hospital_reference`,
`from_location`, `to_location`, `transfer_note_no`, `discount_above_limit_request_id`
(D-071). `customer_id` already exists (the registered-patient link);
`doctor_name`/`doctor_id` are the prescription record, not a profit-sharing one.

### 2. Hospital profit sharing — D-068

Applies to **`counter` and `ipd_admission` only**. A package sale and a transfer carry no
share.

`GP = sale_value − cost_total` · `Hospital Share = GP × share%` ·
`Owner Share = GP − Hospital Share` · `Owner Net = Σ Owner Share − Σ Expenses` (monthly).

| Pharmacy | Hospital | Share |
|---|---|---|
| Arihant Pharmacy | Rohit Kidney & Stone | **50%** |
| Erika Prime Pharmacy | Govardhan Hospital | **60%** |
| Medicotraders | Jain Hospital | **0%** |
| Sudha Pharmacy | Pandey Hospital | **0%** |

**0% is a value, not an absence.** Two pharmacies have a real 0% deal — no share transaction
is written and the whole gross profit is the owner's. Nothing may read a 0% rule as "no rule
configured".

- **`hospitals`** — `id, name, address, city, state, contact_person, contact_phone,
  contact_email, gstin, notes, is_active, created_at, updated_at`. **New table.**
- **`pharmacies.hospital_id`** — references `hospitals`; one pharmacy sits in exactly one
  hospital.
- **`hospital_profit_sharing`** — `id, pharmacy_id, hospital_id, gross_profit_share_percent,
  effective_from, effective_to, notes, created_at, updated_at`: **dated** rules, so a changed
  deal does not move a settled month.
- **`sale_items`** — `cost_basis_per_unit numeric(12,4)`, `cost_total numeric(14,2)`,
  `gross_profit numeric(14,2)`: **snapshots at sale time**, because cost changes over time.

**Doctors take no share** — `doctor_name`/`doctor_id` are the prescription record (D-072).
The earlier `profit_sharing_rules` name is withdrawn before it was built. **`gross_profit` is
computed from a tax-inclusive `total_amount`, so it currently includes the GST collected —
that has to be settled together with N-14, not after it** (D-068).

### 3. Expense categories — D-069

One fixed set: `salary`, `staff_food`, `breakage`, `stationery`, `printer`, `utilities`,
`rent`, `misc`. **The client already keeps a different fixed list** — see D-069 for the
reconciliation that precedes the constraint. The owner bears these; a hospital's share is not
reduced by them.

### 4. RPCs

- `pharmacy_monthly_pnl(pharmacy_id, month)` → the full breakdown
- `hospital_monthly_settlement(hospital_id, month)` → for hospitals **above 0%** share
- `expense_summary(pharmacy_id, month, category)`
- `package_sale_monthly(pharmacy_id, month)` → total cost + markup + what the hospital owes
- `doctor_referral_report(doctor_id, from, to)` → optional trend, not a settlement

### 5. Reports

Monthly P&L per pharmacy · **hospital-wise settlement** (only hospitals above 0%) · **package
sale statement** (what the hospital owes) · doctor referral report (optional — a trend, not a
settlement) · expense breakdown by category · counter sale bill (patient + doctor details) ·
IPD sale bill (hospital reference) · package sale invoice (hospital format) · transfer note.

### 6. GST — ANSWERED for a pharmacy sale (D-075); the compliance question and the package treatment are still open (N-14)

**Answered 2026-09-20 for a pharmacy sale (D-075), and this supersedes the instruction below for
that case.** The owner's patient-first billing brief settles the basis: the rate on a line **is the
price the customer pays** and GST is **extracted** from it (₹105 at 5% = ₹100 taxable + ₹5 tax), the
**product's own slab wins including a recorded zero**, a missing slab falls back to **one named 5%
POS default** (not the old blanket 12%), **MRP is a ceiling** on a retail rate, and
`products.gst_percent` is read for the first time. What follows stays true only for the
**compliance** reading and for a **package** line's treatment, which is still unstated (open item 5
below).

The owner said *"B2C sale hai to GST ka koi matlab nahi hai."* GST applies to retail pharmacy
sales in India regardless of B2B/B2C; B2C only means no buyer GSTIN is needed. Three possible
meanings, and the answer decides the work:

1. GST is charged but **not shown as its own line** on the bill;
2. the pharmacy sits in a **hospital-exempt category** (needs a CA to confirm — rare);
3. it is a **display choice only** (safe).

**DO NOT change any GST logic BEYOND what D-075 settles until the owner answers.** The question to put to them:

> Kya aapka matlab hai:
> (a) GST charge karni hai but bill par separate line item nahi dikhani?
> (b) Aapki pharmacy hospital exemption category mein hai?
> (c) Kuch aur?

It is tracked as **N-14** in `PROGRESS.md`'s open-items table. What exists today and is not to
be touched meanwhile: GST is implemented end to end — `sale_items.gst_percent` with its four
tax columns, the bill whose tax heads sum to the tax charged (D-057), and the report that
shows them.

**The profit-sharing half of this is settled and no longer waits on the answer** (owner,
2026-09-20): the hospital's share is calculated on **GST-inclusive** gross profit, and the
**owner bears the GST out of their own share** — an accepted business model, not an accounting
error (D-068). What remains open under **N-14** is only the **compliance** question: whether GST
is charged on a B2C sale at all, or whether this pharmacy sits in a hospital-exempt category. If
it comes back "no GST on B2C", the tax columns carry zeros and the formula is unchanged.

### 7. Open items (flagged with the brief, not resolved)

1. **Package markup percentages for the four pharmacies** — the owner supplies each value when
   the pharmacy is configured; the column default is **20** (D-070).
2. **The transfer's from/to location format** — plain text, or a foreign key to a `locations`
   table? **No `locations` table exists in the repository** (and neither does a schema-wide
   convention for one), so this is recorded as an open question rather than assumed. The brief's
   column list says `text`, and text is what is recorded — but a `locations` master is the
   obvious later move, and choosing text now is what makes it a migration later.
3. ~~**The above-10% discount flow: blocking or retroactive?**~~ **RESOLVED (owner, 2026-09-20):
   blocking** — the sale cannot be recorded until the approval exists (D-071).
4. ~~**Does an unconfigured pharmacy refuse a package sale?**~~ **RESOLVED (2026-09-20, built):** it
   **refuses**, and the column is now nullable with **no default** — the brief says *"do not silently
   guess unresolved settings"*, which is the same rule the GST slab and a 0% share already follow
   (D-070). The four real values are still the owner's to supply, and item 1 stands unchanged.
5. **What a package sale multiplies, and what it charges tax on** — both still unstated, and both
   multiply or apply to every package line. The rate is resolved as the batch's **landed cost**
   where one is recorded and its **purchase rate** otherwise (the opening-stock catalogue has no
   landed cost, so a fallback is required to keep the flow working); D-070 records the two
   candidates as different numbers. A package line with **no recorded slab is refused** rather than
   taxed at the counter's 5% default — a refusal, not an answer (N-15).

**Estimated Context:** not yet estimated — Phase 7 has no chunk breakdown yet.

---

## Context Budget

| Phase | Estimated tokens | Chat |
|---|---|---|
| Phase 0 | ~110k | 1 [done] |
| Phase 1 | ~150k | shares Chat 2 |
| Phase 2 | ~200k | shares Chat 2 |
| Phase 3 | ~250k | shares Chat 3 |
| Phase 4 | ~140k | shares Chat 3 |
| Phase 5 | ~180k | shares Chat 4 |
| Phase 6 | ~100k | shares Chat 4 |
| **Total** | **~1.13M** | **4 chats** |

Note: 1M context allows 2 phases/chat with a ~600k handoff trigger, leaving
~400k of buffer for degradation and recovery.
