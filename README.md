# munin

The vault that remembers. A self-hosted **document & finance brain**: every
invoice, receipt and contract — from mail, scanners, or your PC's folders —
lands in one place, reads itself, gets categorized, and connects to your bank
accounts. Built for German freelancers (EÜR, USt, DATEV export) and useful to
anyone who wants their paperwork organized and their spending understood.

Named after Munin, Odin's raven of memory. Its companion project
[**hugin**](https://github.com/kenzotp/hugin) — the raven of thought — is the
PC-side file organizer that sweeps folders and hands finance documents over.

## What it does

- **Reads everything**: PDFs (structure + tables via docling), Office/Outlook/
  EPUB/HTML/CSV (markitdown), true scans via a local vision model (VLM OCR) —
  originals stay immutable, recognized text is stored as a sidecar.
- **Understands invoices**: vendor templates first, LLM fallback, then an
  arithmetic checksum (net + VAT = total) — mismatches go to a review queue,
  never silently stored. Confirm an LLM extraction once, and it becomes a
  deterministic template for that vendor.
- **Matches money to paper**: bank statements (FinTS/PSD2) are deduplicated
  and matched to documents by exact amount, date window and IBAN/creditor
  tokens — with a ranked confirmation UI. Transfers between your own accounts
  never double-count.
- **German tax pack**: categories carry VAT rates + EÜR lines, live EÜR,
  USt-Voranmeldung worksheet, DATEV CSV + receipt-image export, inbound
  ZUGFeRD/XRechnung e-invoice parsing.
- **Dashboards**: where the money went, subscriptions and price creep,
  missing receipts, duplicate charges, upcoming debits.

## Status

Pre-alpha — design and research phase. See
[ROADMAP.md](ROADMAP.md) and
[docs/RESEARCH.md](docs/RESEARCH.md) for the architecture and the
open-source work this design draws from.

## Architecture (planned)

- **Phoenix LiveView** app (Elixir) — snappy server-rendered UI, Oban workers
  for the document/bank pipelines, Postgres via Ecto, multi-user from day one.
- **Python sidecar** — docling, markitdown, python-fints; OCR via a local
  vision model (Ollama) with a provider-agnostic fallback chain.
- **Documents are immutable** — originals are never modified; recognized text
  lives in sidecars. Audit log on every booking-relevant change. Built to be
  GoBD-compatible (no hard deletes, machine-readable exports).

## Principles

1. Your documents stay yours: local-first, originals immutable.
2. Bank access is **read-only by design** — the app can never send payments.
3. Secrets in instance config, never in the repo.
4. Deterministic before LLM: templates and checksums first, models where they
   earn their keep.

## License

MIT — see [LICENSE](LICENSE).
