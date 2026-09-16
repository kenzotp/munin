# RESEARCH — the design research behind Munin (verified Sept 2026)

Conclusions from two research sweeps (OSS repos; German banking/tax) plus local
infrastructure checks. Sources were live links at research time; the ranked
"steal list" at the bottom is the operative summary.

## Document management & OCR

**paperless-ngx** (GPL-3.0, ~45k★, dominant). Steal:
- Consume/hot-folder pipeline: watch → stage → single-consumer pipeline →
  archive; inotify with **polling fallback for SMB/NFS** (our NAS case);
  checksum dedupe with delete/flag policy.
- Metadata model: tags (hierarchical), correspondents, document types, storage
  paths, **typed custom fields** (monetary/date/bool/select) + symmetric
  document links — the shape of our Postgres schema.
- Storage-path templating with conditionals → the mechanism for organizing
  files back onto shares.
- Non-LLM sklearn classifier for suggestions (trains on accept/reject);
  audit log + trash (GoBD-ish); ASN/barcode ingestion; consume-subfolder
  workflows (folder = rule input).
- Avoid: copying the Django monolith; don't auto-LLM every field.

**icereed/paperless-gpt** (MIT, very active). Steal:
- Tag-triggered dual mode (`review` vs `-auto`), prompts as hot-reloadable
  templates constrained to the EXISTING tag vocabulary (LLM can't invent
  taxonomy).
- VLM OCR mechanics: render pages to images with hard caps (max dim 10k px,
  40M total pixels, ≤600 DPI, ~10 MB JPEG auto-resize); recognized text goes
  back as document CONTENT sidecar — never overwrite the original (GoBD).
- Graceful partial failure: bad fields → retry partials → FAIL tag for review.

**invoice-x/invoice2data** (MIT, active 2026). Steal:
- YAML template = issuer fingerprint (keywords) + typed regex field dict
  (`decimal_comma`, German `date_formats`, `lines` plugin for Positionen).
- Cascading text backends; embedded text short-circuits OCR.
- The 2026 hybrid: deterministic templates first → LLM fallback on miss →
  **promote confirmed LLM output into a new YAML template**. Beats pure regex
  AND pure LLM for recurring German vendors. Plan: hand-write ~10 templates
  for the top ~10 recurring vendors; ignore the community template library.

**Dead ends (verified):** naiveHobo/InvoiceNet (dead since 2024), Papermerge
("seeking maintainers"). Mayan EDMS (single maintainer), docspell (multi-user
Scala — only its email-ingestion idea matters). No active OSS "BERT for
invoices" — the field moved to VLM OCR + structured prompts and commercial
DocAI. Train nothing.

**tfeldmann/organize** (MIT, v3 2026): steal the rule DSL shape
(locations → filters → actions, `sim` dry-run, conflict-resolution on move) —
schema only, no dependency. No better-maintained OSS competitor exists.

**PDF/OCR engines 2026:**
- **docling** (IBM, MIT, 66k★): primary for PDF text + tables (TableFormer
  ~97.9% cell accuracy). Not a field extractor (~63% field-level invoice
  accuracy measured) — extraction stays template/LLM.
- **PaddleOCR** (Apache-2.0): strongest raw OCR for Kassenbon-style thermal
  receipts. Fallback.
- Surya (good, but weight-license gates commercial use), docTR (no structure),
  unstructured (generic ETL), Tesseract (baseline only).
- **VLM OCR** for true scans: gemma4 26b vision (local Ollama) with
  deterministic sum-checksums afterwards (never trust VLM digit strings).

**microsoft/markitdown** (MIT, ~185k★, very active): converts PDF, Word,
Excel, PowerPoint, **Outlook .msg**, EPUB, HTML, CSV/JSON/XML, ZIP → Markdown.
PDF = embedded text ONLY (no scan OCR without Azure); images EXIF+OCR; audio
transcription. Lightweight core, opt-in extras, CLI + library (+ MCP server).
**Role in Munin:** the universal cheap rung for every non-PDF or text-layer
file — this is what makes the whole-PC file optimizer classify everything, not
just PDFs. Security: use `convert_local()`/`convert_stream()` (their documented
safe path for untrusted input), inside the sidecar container.
**Hub status:** not installed anywhere (host + all containers checked);
open-webui supports a docling RAG engine but has it disabled — no conflicts.

## Receipt ↔ bank matching (the composite we build)

- **Firefly III** (AGPL, active): typed rule triggers (amount, description
  operators, IBAN/account/name, SEPA CI, dates with relative arithmetic) +
  strict AND / loose OR; "Bills" matcher = expected amount min/max + recurring
  date window (the single best recurring-invoice matcher idea).
- **beancount-import** (GPL-2.0, active): best matching engine — amount equal +
  dates within ±5 days, cleared↔uncleared constraint only, per-source metadata
  for idempotent re-imports, import-row↔import-row matches (catches card
  payment pairs), ranked candidates + diff-preview confirm UI; account
  prediction = decision tree trained on accepted history (our categorizer).
- **Actual Budget** (MIT, active): import dedupe = exact amount + near-date
  fuzzy pass; known failure mode: pending→posted transitions duplicate —
  solved by (rounded amount, ±N days, IBAN) + a stable `dedupe_key`
  (fitid / SEPA CREDITOR ID), never name strings.

## German bank connectivity (ranked, 2026 reality)

1. **FinTS via python-fints** (raphaelm, active, v5 docs): the OSS standard for
   Sparkasse/Volksbank. Needs: BLZ + online-banking login + PIN + bank FinTS
   endpoint + **DK product registration ID** (10–15 working days — file
   immediately, see docs/DK-REGISTRATION.md). PSD2 TANs: decoupled SCA
   supported; Sparkasse S-pushTAN wants an app-confirmation per new session →
   build an async approval flow, persist dialog state.
2. **Enable Banking** (free "restricted production" for self-linked accounts):
   the Nordigen replacement; 2700+ banks incl. N26, Sparkassen, ING, DKB.
   Already proven in Actual Budget; Firefly integration in progress. Gotchas:
   ≥90-day history window, ~90-day re-auth cadence, third-party dependency.
3. ~~GoCardless Bank Account Data~~ — **closed to new signups since July
   2025**. Do not build on it.
4. Hibiscus/hbci4java (willuhn.de) — battle-tested Java fallback if
   python-fints chokes on a specific bank.
- Not viable: Tink, finAPI (Qonto), Plaid, direct XS2A (needs eIDAS
  certificates).
- **PayPal: no PSD2 route, verified** (wallet ≠ payment account). Sources:
  confirmation mails (already flowing into the mail app) + bank-debit matching;
  optional PayPal Transaction Search API (OAuth, free).

## German freelance tax (what to encode)

- Booking line: belegdatum + valuta, external id, Verwendungszweck,
  counterparty (name/IBAN/creditor-id), amount_gross, direction, category,
  vat_rate (19/7/0), vat_amount/net_amount, vorsteuer flag, scope
  (business|private — EÜR/USt sums business ONLY), document_id + hash,
  ust_va_key (Kz 81/44/66 …).
- Category triple: {default VAT rate, EÜR line, SKR03/04 code, USt-VA key}.
- EÜR: live per-category report. USt-VA: worksheet for manual ELSTER filing
  (direct transmission = SaaS/ERiC territory — out of scope). DATEV: CSV
  Buchungsstapel-style + zip of Belegbilder (the Papierkram-proven subset,
  accepted by Steuerberater).
- **E-Rechnung duty**: receiving XRechnung/ZUGFeRD mandatory since 1.1.2025 →
  inbound parser = structured XML, zero OCR, free accuracy. Issuing duties
  phase in 2027 (>€800k) / 2028 (all). Fakturama = only OSS invoicing suite
  with XRechnung, desktop Java, no useful API — integration declined; invoices here are self-generated anyway.
- GoBD: immutable originals, no hard deletes (storno), audit trail of every
  booking change, machine-readable export, + we write a Verfahrensdokumentation.
- 2026 numbers: Kleinunternehmer §19 = €25k prev-year / €100k current; USt-VA
  obligation only from €9k prev-year USt (new 2026).

## Local infrastructure (checked 2026-09-16)

- A local gaming PC with `gemma4:26b-a4b-it-qat` 15 GB (vision-capable) in
  Ollama on ~20 GB VRAM runs it; any 8–12 GB VRAM GPU fits qwen2.5-vl:7b.
- Hub: 71 GB free; 35 containers; **no existing document-management stack**;
  `ollama-ha` HAProxy (port 11434) load-balances LAN Ollama hosts:
  192.168.0.253 "eth" (llama3.2:3b + **bge-m3** embeddings), 192.168.0.122
  (this PC — the vision model). Munin reaches both through ollama-ha, exactly
  like the mail stack does.
- markitdown/docling: absent everywhere — fresh install in the sidecar.

## RANKED STEAL LIST (the operative summary)

1. Checksum-gated consume pipeline, polling-capable watcher (paperless-ngx).
2. Hybrid extraction ladder: embedded text → vendor YAML templates → LLM
   fallback → one-click promote-to-template (invoice2data 2026 pattern).
3. VLM-OCR mechanics: capped page rendering, text as sidecar, originals
   immutable, review/auto tag modes (paperless-gpt).
4. Typed custom-field document schema + symmetric document links (paperless
   v2 custom fields) = our Postgres model.
5. Storage-path templating with conditionals (paperless v2.13) = the file
   organizer's target-path language.
6. Bill-style matcher: amount range + date window + IBAN/creditor tokens;
   exact-amount ±5-day one-off matching; cleared↔uncleared; ranked candidate
   UI (Firefly bills + beancount-import).
7. Decision-tree categorizer trained on own confirmations (beancount-import).
8. Consume-subfolder workflows: intake folder = pre-assigned tags (paperless).
9. Barcode/ASN ingestion: separator-sheet splitting, archive serials (zxing).
10. Paperless-compatible `POST /api/upload`: existing mobile/share apps work
    on day one.
