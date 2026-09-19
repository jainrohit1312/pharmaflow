# PharmaFlow — User Manual

How to run a pharmacy on PharmaFlow, screen by screen. Written for the person
behind the counter, not for a developer.

Everything here assumes you are signed in to your own pharmacy. PharmaFlow is
multi-tenant: every pharmacy's data is invisible to every other pharmacy, enforced
by the database itself, so two pharmacies can both have a product called "Dolo 650"
and neither can see the other's.

**The one place to start** if something looks wrong: the Ledger and the Inventory
low-stock list are computed by the database from the documents you have posted, so
they are always the record. If a figure on a screen disagrees with what you
expected, the document behind it is the answer.

---

## Contents

1. [Getting in](#getting-in)
2. [The dashboard](#the-dashboard)
3. [Products](#products)
4. [Suppliers and customers](#suppliers-and-customers)
5. [Purchases: ordering and receiving](#purchases-ordering-and-receiving)
6. [Reading a supplier bill from a photo](#reading-a-supplier-bill-from-a-photo)
7. [Inventory: stock, reorder levels and expiry](#inventory-stock-reorder-levels-and-expiry)
8. [Selling at the counter](#selling-at-the-counter)
9. [A bill, and printing it](#a-bill-and-printing-it)
10. [Returns](#returns)
11. [The ledger and payments](#the-ledger-and-payments)
12. [Reports](#reports)
13. [Notifications](#notifications)
14. [The chatbot](#the-chatbot)
15. [Day-to-day recipes](#day-to-day-recipes)
16. [What PharmaFlow deliberately does not do](#what-pharmaflow-deliberately-does-not-do)

---

## Getting in

**Sign up** with an email address and a password. On a new install the first user
becomes the pharmacy's **owner** through onboarding: name the pharmacy, and fill in
its address, GSTIN and drug licence number — those print on every bill you hand a
customer.

A new account that has not been attached to a pharmacy can see nothing, and says so
rather than showing empty screens. That is deliberate: a user without a pharmacy has
no tenant to scope a query to.

**Roles** decide what you may do beyond tenancy:

| Role | Intended for |
| --- | --- |
| `owner` | The person who owns the business — everything |
| `pharmacist` | The counter and the buying |
| `cashier` | The counter |
| `viewer` | Someone who needs to look, not touch |

> **Account confirmation is deliberate (D-060).** The hosted project requires a
> confirmed email address, and that stays on: creating an account is two steps — sign
> the person up, then confirm the address in the Supabase dashboard
> (Authentication → Users). A user who has not been confirmed yet is told their address
> is not confirmed rather than that their password is wrong. This is a policy for a
> shop with a handful of accounts, not a self-service signup, and it can be revisited
> if that changes.

---

## The dashboard

The dashboard is the shell around everything else. On a wide screen it is a
navigation rail down the side; on a phone it is a four-item bar at the bottom
(Dashboard, Products, Sales, Reports) plus a drawer for the rest.

It carries one widget of its own: **Notifications (N)**, the unread count, tappable
straight through to the inbox. At zero it reads *No new notifications* rather than
disappearing — a surface that hides when it has nothing to say is one you forget
exists.

---

## Products

Products → **New product**. What matters on a product:

| Field | Why it matters |
| --- | --- |
| Name, generic name, brand | What search and the bill matcher look at |
| Pack size (`15s`, `10ml`) | Two strengths of one brand are told apart by the pack |
| GST % | What the invoice charges |
| Drug schedule (`OTC`, `H`, `H1`, `X`, `Narcotic`) | A prescription-only schedule puts the sale in the drug register — the bill screen will say so |
| Reorder level | The low-stock alert's threshold: leave it at 0 and this product is never reported as low |
| HSN code | What a GST return wants |

A product also carries **batches** and **aliases** on its detail screen.

- **Batches** are what actually holds stock. You rarely create one by hand: receiving
  a purchase creates or tops up the batch it names, and each batch keeps its own
  cost basis (landed cost per unit, so free/scheme units do not overstate the value
  of what is on the shelf).
- **Aliases** are the text a supplier prints on their bill. Add "DOLO-650 TAB" to
  Dolo 650 once and the next bill from that supplier matches the line instantly, with
  no guessing. Aliases are per supplier; an alias with no supplier is a
  pharmacy-wide one, learned from a bill that named no distributor.

---

## Suppliers and customers

**Suppliers** carry the GSTIN and drug licence that a purchase document needs, and a
preferred channel (WhatsApp or email) for sending them a purchase order.

**Customers** are optional at the counter. A cash sale to a walk-in needs no
customer at all; putting a bill on a customer's account is what creates a
receivable, and that is what the customer ledger shows.

Both have search and filters, and both have a detail screen with their own
documents.

---

## Purchases: ordering and receiving

A purchase document moves through two states that matter:

1. **Draft** — lines can be edited freely. Nothing has happened yet.
2. **Ordered** — you have sent it to the supplier. Editing the *lines* of an ordered
   document returns it to draft, on purpose: the supplier's confirmed order is now
   stale and needs re-confirming. The screen tells you it did this. Editing only the
   notes or the invoice number keeps it ordered.
3. **Received** — the goods arrived. **This is the moment stock moves**, for every
   line, once. A document that has posted stock is corrected by a **return**, never
   by an edit.

Receiving a purchase is where you enter, per line, the batch number, the expiry
date, the quantity, any free/scheme quantity, the rate, the discount and the MRP.
Free units count as physical stock (they are on the shelf and will be dispensed),
which is why a scheme line needs a landed cost — the app works that out for you.

**Purchase returns** → New purchase return: pick the received invoice, say how many
units of which lines came back, and the credit note is worked out as a *slice of the
invoice's own stored line amounts* — a return of 4 units of a line that was billed
with a discount credits what the invoice charged for 4 units, not the list price.
You cannot return more than was billed, less what has already come back, and you
cannot return more than the batch holds.

---

## Reading a supplier bill from a photo

Purchase → the bill reader.

1. **Photograph the bill** (or pick a picture). It is uploaded to a private,
   pharmacy-scoped store, and read by the vision model.
2. **Check the header**: supplier, invoice number and invoice date. The reader warns
   about anything it had to guess — a date it read day-first, a quantity it rounded,
   an invoice number it could not find.
3. **Check the lines.** Each line shows the text the bill printed and the product the
   app thinks it is. Where the app is not certain, it *suggests* catalogue products —
   with the reason: a text you confirmed before on this supplier's bills, a spelling
   similarity, or a meaning similarity. **A suggestion is only ever offered, never
   applied.** Nothing changes until you tap it.
4. **Save.** The purchase is written, stock moves, and what you confirmed is
   remembered as an alias — so the next bill from that supplier is easier.

**If the reader got the bill wrong, you can have it read again.** Under the photo
there is a small **"Read it again"** with a counter beside it — *Attempt 2 of 3*. It
asks first, because a read costs one AI call, and the counter says which attempt your
tap would spend. **A bill gets three reads**; after the third the button says "Max
attempts reached", and choosing the file again is how you start over. Reading again
**keeps everything you have already corrected** — the supplier, your notes, and every
line you have touched — and replaces only what the reader produced: the invoice number,
the date and the lines.

If the reader is busy (the model is rate-limited), the app says so once and offers a
retry. It does not retry by itself: a second attempt costs the same quota, and doing
it invisibly would spend it twice.

---

## Inventory: stock, reorder levels and expiry

Inventory has three views:

- **Stock** — every product with what is on hand and what it is worth at cost
  (landed cost, so scheme stock is valued correctly). Filter by "in stock" or "out of
  stock", and search by name, generic name or brand.
- **Low stock** — the reorder list: products that have fallen *below* the level you
  set, worst shortfall first, with **how many units would close the gap**. A product
  sitting exactly *at* its level is not on this list: that is where you meant to act,
  not where you are already late. A product with a level of 0 has no threshold and is
  never reported.
- **Expiry** — batches that still hold stock and are expiring inside the horizon,
  bucketed by urgency. An expiry calendar shows a month at a time.

**Stock adjustments** record a correction against a batch — a breakage, a
miscount. A decrease that would take a batch below zero is refused, with the
database's own words, and nothing moves.

> The expiry figures are shown at **MRP**, not at cost, and the stock valuation at
> **cost**: the batch view does not carry a landed cost per batch, and substituting
> the purchase rate would overstate exactly the scheme stock the landed cost exists
> to get right.

---

## Selling at the counter

Sales → **New sale**. Add lines by searching the catalogue (name, generic name or
barcode), choose the batch the units come from (FEFO — soonest expiry first), and
take payment.

- The cart's figures are computed once, by the same helper the write uses, so what
  you showed the customer is what the till stored.
- **Payment** can be cash, card, UPI, bank, wallet, on credit, or other. Anything
  short of the total becomes a **balance due**, and a sale on credit becomes a
  receivable in the customer's ledger.
- Where the goods are going (the place of supply) decides whether the invoice
  charges CGST + SGST or IGST. The common case — a walk-in, or a customer in your own
  state — defaults to your own state.
- A line under a prescription-only schedule marks the bill as belonging in the drug
  register, and the bill screen says so.

---

## A bill, and printing it

Tap a sale to open its bill. It shows what was sold and what it came to **from the
document's own stored columns**, never recomputed — a bill that recalculated its own
total could only disagree with the ledger entry it posted.

**Print** produces an 80mm thermal receipt. It carries your pharmacy's name,
address, GSTIN and drug licence; the document number and time; each line with how it
was priced; the tax heads; the total; how it was paid; and the balance due if there
is one. Amounts print as `Rs 1,234.00` — deliberately not the `₹` glyph, which the
PDF fonts and many thermal printers cannot render.

A bill you open from a stale link says *not found* rather than spinning for ever.

---

## Returns

**Sale returns** (Returns → New sale return) work like purchase returns but for the
customer side: pick the bill the goods were sold on, say how many units of which
lines came back, choose how the money went back, and decide whether the units go
**back into stock** or are written off as damaged/unsellable. The credit is a slice
of the sold line's own stored amounts, so a discounted line is credited what was
charged.

---

## The ledger and payments

Ledger is kept per party, for suppliers and customers. Choose one and you see:

- **Their balance**, read in the direction that party matters: what you owe the
  supplier, or what the customer owes you.
- **Every entry behind it**, newest first, each labelled from your side — *we owe
  more*, *we paid*, *they owe more*, *they paid* — because "debit" and "credit" mean
  opposite things depending on which party is on screen.
- **Record payment** (or **Take payment**) against that party, which posts the
  payment and the ledger entry together.

The balance is not a stored number: it is read from the ledger entries themselves,
which is the record. Entries appear as documents are posted — a purchase credits a
supplier, a sale debits a customer, and payments and returns settle them.

If a party's ledger cannot be read, the screen says so and offers a retry. Entries
load a page at a time; a page that fails to load leaves the page you already have on
screen and tells you it failed.

---

## Reports

The reports read server-side aggregates, one query each:

- **Summary** — sales, purchases and what they came to over a window.
- **Top products** — best sellers by revenue or quantity, with the window and metric
  stated. Note that returns are **not** netted off this figure; the report says so
  itself.
- **Dead stock** — what has not moved in a long time, which is money sitting on a
  shelf.
- **Expenses** — costs, recorded against the categories you use.

---

## Notifications

The inbox carries, in one place:

- **Low-stock alerts** and **expiry alerts** — answered live from the database when
  you open the screen, so they are never stale. They are questions about stock now,
  not stored messages.
- **Messages** — anything the app has told you, with an unread count on the
  dashboard.

An alert that could not be *delivered* is still visible here: the in-app list is the
surface that carries the message either way, and the place a failed dispatch is
discovered.

> **Automatic dispatch is not switched on.** Low-stock and expiry alerts appear in
> this list and are not sent anywhere. Sending them (over WhatsApp or email) needs
> provider credentials that are not configured yet, and the dispatch log — which
> records every attempt, including the ones that could not be made — is what will
> make "did we tell this supplier?" answerable when they are.

---

## The chatbot

Chatbot asks questions about *your* pharmacy and answers from the same aggregates
the reports use. Try:

- *"What is low on stock?"*
- *"What is expiring in the next 90 days?"*
- *"What sold best last month?"*
- *"What has not moved in 90 days?"*
- *"How much did I sell in August?"*

**It never invents a number.** The model's only job is to pick which report your
question is asking about; every figure in the answer comes from that report, and
under each answer the app shows which report it was and what it was asked
(`within 90 days`, `at most 5 rows`) plus any caveat the report itself states (like
*returns are not subtracted*).

Two things it will not do, by design: it answers only from a closed set of reports
(so it cannot answer about a single product, a single customer or a forecast — those
need a new report, not a better prompt), and it changes nothing. It moves no stock,
posts no entry and sends no message.

If it cannot answer your question it says so in plain prose — that is a normal
answer, not an error, and there is nothing to retry. If it *could not be asked*
(the model was busy), you get an error card and one retry button, for that same
question.

---

## Day-to-day recipes

**Take a sale.** Sales → New sale → search the product → choose the batch → add
lines → take payment → print. If the customer wants it on account, name the customer
and take a part payment; the rest becomes a balance due.

**Take delivery of an order.** Purchase → open the order → receive it → enter batch,
expiry, quantity, free quantity, rate, discount and MRP per line → save. Stock moves
once, at that moment. Check the invoice number and date while you are there.

**Photograph a bill someone brings in.** Purchase → bill reader → photograph →
correct the header and lines → save. What you confirmed becomes an alias.

**Decide what to reorder.** Inventory → Low stock. The top of the list is the worst
shortfall; the badge says how many units would close the gap.

**Check what is about to expire.** Inventory → Expiry (or the calendar, for a
month). Then decide whether to return it, discount it, or write it off — a write-off
is a stock adjustment.

**Settle a supplier.** Ledger → Suppliers → the supplier → Record payment. Their
balance and their payment history are the same screen.

**Check the month.** Reports → Summary for the window; Top products for what is
moving; Expenses for what the month cost.

---

## What PharmaFlow deliberately does not do

These are decisions, not defects — each one is recorded in `DECISIONS.md` with its
reason:

- **It does not work offline.** Every read and write goes to the hosted database.
  (Drift is declared in the project but unused; offline-first is deferred.)
- **It does not reorder by itself, and it does not send anything automatically.**
  You place the order; the app tells you what to order. Alerts are shown, not
  dispatched.
- **It does not push notifications to a phone yet.** The inbox is the surface.
- **It does not let you edit a document that has moved stock.** Correct it with a
  return, or with a stock adjustment — the record of what actually happened is what
  the ledger and the stock rollup are built from.
- **It does not recompute the total on your bill.** It prints what was charged.
- **It does not let you change a role or a pharmacy id on your own profile.** Those
  go through onboarding, so a user cannot promote themselves or move between
  tenants.
