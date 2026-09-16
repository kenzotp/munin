# ROADMAP

Phases are deliberately shippable one at a time; each leaves the app usable.

## P1 — Vault
Server skeleton (Phoenix LiveView + Ecto + Postgres + Docker), upload +
mobile-scan endpoint (PWA share-target, paperless-compatible `POST /api/upload`),
dedupe (SHA-256), the text ladder (embedded text → docling → VLM OCR for true
scans), list/view/full-text search UI. Deliverable: scan anything, find anything.

## P2 — Understanding
Classification (document type, private/business, vendor — strict-JSON LLM with
template fast-paths), the extraction ladder (vendor YAML templates → LLM
fallback → arithmetic checksum → promote-to-template), review queue, invoice
detail view, reminders (due dates, notice periods, warranties, return
windows), audit log.

## P3 — Money
Bank connections: FinTS (Sparkasse-family) + a PSD2 aggregator for app-only
banks + payment-confirmation mails. Two-tier statement dedupe (content hash +
external id), document↔transaction matching engine (exact amount, ±date
window, IBAN/creditor tokens, recurring-amount ranges) with a ranked confirm
UI, own-account transfer pairing, categorization stack (rules → trained
classifier → LLM).

## P4 — Cockpit
Cashflow dashboards, business/private split, savings cockpit (subscription and
recurring detection, price-creep alerts, fee audit, missing-receipt finder,
duplicate-charge finder, cashflow forecast), monthly digest (mail/webhook).

## P5 — Tax (DE pack)
Live EÜR, USt-Voranmeldung worksheet, DATEV CSV + receipt-image zip export,
inbound ZUGFeRD/XRechnung parser → booking proposals, outgoing-invoice tracker
(paid/unpaid via bank matching), Verfahrensdokumentation template.

## P6 — and beyond
Ask-the-vault chat over your structured data; barcode separator-sheet splitting
and archive serial numbers; whole-file-optimizer hooks via the companion
project Hugin; public API + webhooks; insurance overlap detector; vehicle and
travel files.

The full design rationale and research backing these phases lives in
[docs/RESEARCH.md](docs/RESEARCH.md).
