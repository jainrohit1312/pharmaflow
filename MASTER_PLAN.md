# PharmaFlow — Master Plan

Roadmap for Phases 1-6, optimized for the 1M token context window: 2 phases
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
