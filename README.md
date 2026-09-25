# Munin

The vault that remembers. A self-hosted **document & finance brain**: every
invoice, receipt and contract — from mail, scanners, or your PC's folders —
lands in one place, reads itself, gets categorized, and connects to your bank
accounts. Built for German freelancers (EÜR, USt, DATEV export) and useful to
anyone who wants their paperwork organized and their spending understood.

Named after Munin, Odin's raven of memory. Its companion project
[**Hugin**](https://github.com/kenzotp/hugin) — the raven of thought — is the
PC-side file organizer that sweeps folders and hands finance documents over.

## What it does

- **Reads everything**: PDFs (structure + tables via docling), Office/Outlook/
  EPUB/HTML/CSV (markitdown), true scans via a local vision model (VLM OCR) —
  originals stay immutable, recognized text is stored as a sidecar.
- **Understands invoices**: vendor templates first, LLM fallback, then an
  arithmetic checksum (net + VAT = total) — mismatches go to a review queue,
  never silently stored. Confirm an LLM extraction once, and it becomes a
  deterministic template for that vendor.
- **Local-first inference, always**: OCR and classification/extraction try a
  local Ollama model first — set `LOCAL_LLM_URL` (e.g. `http://host:11434`)
  and, if you don't want the default, `LOCAL_LLM_MODEL`. Cloud (OpenRouter) is
  only used as a fallback, and only when you opt in with `CLOUD_FALLBACK=true`
  — with it off (the default), no document ever leaves the machine, which
  matters most for tax documents. If the local model is unreachable and cloud
  is off, the document is simply retried later, never marked failed.
- **Matches money to paper**: bank statements (FinTS/PSD2) are deduplicated
  and matched to documents by exact amount, date window and IBAN/creditor
  tokens — with a ranked confirmation UI. Transfers between your own accounts
  never double-count.
- **Works today without bank APIs**: paste CSV exports (German bank formats
  parse as-is) or use the built-in simulator. Real FinTS sync is read-only
  and activates with your own free DK product registration (fints.org) —
  set `FINTS_*` env vars; registration IDs are personal and never shipped in
  this repo. Once configured, a daily Oban job pulls the last 14 days
  automatically at 05:00 Europe/Berlin — turn it off with `BANK_SYNC=off`,
  or change the time with `BANK_SYNC_CRON` (default `0 5 * * *`).
- **German tax pack**: categories carry VAT rates + EÜR lines, live EÜR,
  USt-Voranmeldung worksheet, DATEV CSV + receipt-image export, inbound
  ZUGFeRD/XRechnung e-invoice parsing.
- **Dashboards**: where the money went, subscriptions and price creep,
  missing receipts, duplicate charges, upcoming debits.

## Status

**P1+P2 LIVE (2026-09-16/17)** — document vault (SHA-256 dedupe), classification, invoice money extraction with checksum gate, reminder pipeline, review UI. Design history: see
[ROADMAP.md](ROADMAP.md) and
[docs/RESEARCH.md](docs/RESEARCH.md) for the architecture and the
open-source work this design draws from.

## Architecture

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
