# munin_vision — the reading brain's Python half.
#
# Endpoints (all file access is by ABSOLUTE path, and the path must be inside
# VAULT_PATH — this sidecar reads nothing else):
#   GET  /health
#   POST /extract  {path}  → {text, reader, pages}   embedded text layer (pypdf)
#                                                     or office/html text (markitdown)
#   POST /render   {path}  → {pages: [{n, jpeg_base64}]}  capped page renders (pymupdf)
#   POST /fints/transactions  {blz,url,login,pin,product_id,start,end}
#        → {rows, accounts}   read-only FinTS statement fetch (python-fints)
#
# Originals are opened read-only; nothing here ever writes to a document.
import base64
import datetime as dt
import os
import time
from pathlib import Path

from fastapi import FastAPI, HTTPException
from fints.client import SYSTEM_ID_UNASSIGNED, FinTS3PinTanClient, NeedTANResponse
from fints.exceptions import (
    FinTSClientPINError,
    FinTSClientTemporaryAuthError,
    FinTSDialogInitError,
)
from pydantic import BaseModel

VAULT = Path(os.environ.get("VAULT_PATH", "/vault")).resolve()

app = FastAPI(title="munin_vision")


class PathIn(BaseModel):
    path: str


def checked(path: str) -> Path:
    p = Path(path).resolve()
    if not p.is_relative_to(VAULT):
        raise HTTPException(status_code=403, detail="path outside vault")
    if not p.is_file():
        raise HTTPException(status_code=404, detail="not found")
    return p


@app.get("/health")
def health():
    return {"ok": True, "service": "munin_vision"}


@app.post("/extract")
def extract(body: PathIn):
    p = checked(body.path)
    if p.suffix.lower() == ".pdf":
        return {"text": pdf_text(p), "reader": "pypdf", "pages": pdf_pages(p)}
    return {"text": office_text(p), "reader": "markitdown", "pages": 1}


def pdf_pages(p: Path) -> int:
    from pypdf import PdfReader

    return len(PdfReader(str(p)).pages)


def pdf_text(p: Path) -> str:
    from pypdf import PdfReader

    try:
        reader = PdfReader(str(p))
        return "\n\n".join((page.extract_text() or "") for page in reader.pages).strip()
    except Exception:
        # encrypted/odd PDFs — the ladder falls through to OCR
        return ""


def office_text(p: Path) -> str:
    from markitdown import MarkItDown

    result = MarkItDown().convert(str(p))
    return (result.text_content or "").strip()


@app.post("/render")
def render(body: PathIn):
    import fitz  # pymupdf

    p = checked(body.path)
    if p.suffix.lower() != ".pdf":
        raise HTTPException(status_code=400, detail="not a pdf")

    doc = fitz.open(str(p))
    pages = []
    for n in range(min(len(doc), 20)):  # cap: 20 pages per document
        pix = doc[n].get_pixmap(dpi=150, colorspace=fitz.csRGB)
        # Long-edge ceiling at 2000px (paperless-gpt-style cap), rescale if over.
        if max(pix.width, pix.height) > 2000:
            scale = 2000 / max(pix.width, pix.height)
            pix = doc[n].get_pixmap(dpi=max(72, int(150 * scale)), colorspace=fitz.csRGB)
        jpeg = pix.tobytes("jpeg")
        pages.append({"n": n + 1, "jpeg_base64": base64.b64encode(jpeg).decode()})
    doc.close()
    return {"pages": pages}


# ---------------------------------------------------------------- FinTS (P3)
# Read-only statement fetch via get_transactions (HKKAZ) — never the HKEKA
# PDF API. Credentials arrive per-request from the web app's env; nothing
# here is ever logged or returned in a response. The DK product registration
# ID identifies MUNIN to the banks — each self-hoster registers their own
# free ID at fints.org; shipping one in a public repo is forbidden by DK.
#
# SCA: this sidecar only supports a decoupled two-step mechanism (e.g.
# Sparkasse's pushTAN 2.0), where approval happens in the banking app —
# never a typed TAN. A bank that offers only typed-TAN mechanisms gets a
# clear tan_required error instead of a prompt this sidecar cannot show.
#
# State: python-fints can persist system_id, BPD/UPD and the selected TAN
# mechanism/medium via client.deconstruct(including_private=True) — never the
# PIN (see FinTS3Client._deconstruct_v1 / FinTS3PinTanClient._deconstruct_v1
# in python-fints' client.py). The caller may hand back a previous
# client_state; when it already names a TAN mechanism, fetch_tan_mechanisms()
# and TAN-medium selection are skipped, so the bank sees a returning system
# instead of registering Munin as new on every fetch. On success (and on a
# TAN timeout, if a system ID has been assigned by then) the response carries
# the new client_state for the caller to store.

_PIN_BLOCK_MSG = "Refusing to use PIN after block"


class FinTSIn(BaseModel):
    blz: str
    url: str
    login: str
    pin: str
    product_id: str
    start: str
    end: str | None = None
    client_state: str | None = None  # base64 of a previous deconstruct()


class _TanTimeout(Exception):
    """Approval was not given within the mechanism's poll budget."""


class _TypedTanRequired(Exception):
    """The bank wants a typed TAN; only app-approval pushTAN is supported."""


def _tan_wait_params(mech):
    """(wait_before_first_poll, wait_before_next_poll, decoupled_max_poll_number),
    defaulting to 5s / 2s / 60 polls when the mechanism leaves one unset."""
    first = getattr(mech, "wait_before_first_poll", None)
    nxt = getattr(mech, "wait_before_next_poll", None)
    max_polls = getattr(mech, "decoupled_max_poll_number", None)
    return (
        int(first) if first is not None else 5,
        int(nxt) if nxt is not None else 2,
        int(max_polls) if max_polls is not None else 60,
    )


def _select_tan_mechanism(client):
    """Pick a decoupled two-step mechanism and return (parameters, restored).

    If a restored client_state already named a two-step mechanism (anything
    but "999", the one-step/no-TAN placeholder), that choice is trusted as-is
    and fetch_tan_mechanisms() — the bootstrap that makes the bank register a
    new customer system — is skipped entirely, `restored` is True.

    Otherwise this is today's behaviour: fetch_tan_mechanisms(), then prefer
    a mechanism whose parameters carry decoupled_max_poll_number, then one
    whose name mentions "push", else leave python-fints' own choice (usually
    the bank's single offered mechanism) untouched. `restored` is False.
    """
    current = client.get_current_tan_mechanism()
    if current and current != "999":
        mechs = client.get_tan_mechanisms()
        if current in mechs:
            return mechs[current], True
        # Named a mechanism the (offline) BPD doesn't know — treat as if no
        # mechanism had been restored and fall through to a full fetch.

    client.fetch_tan_mechanisms()
    mechs = client.get_tan_mechanisms()
    candidates = {k: m for k, m in mechs.items() if k != "999"}
    decoupled = [k for k, m in candidates.items() if getattr(m, "decoupled_max_poll_number", None)]
    push = [k for k, m in candidates.items() if "push" in (m.name or "").lower()]
    chosen = next(iter(decoupled), None) or next(iter(push), None)
    if chosen is not None:
        client.set_tan_mechanism(chosen)
    return mechs.get(client.get_current_tan_mechanism()), False


def _select_tan_medium(client):
    if not client.is_tan_media_required():
        return
    _, media = client.get_tan_media()
    if len(media) == 0:
        client.selected_tan_medium = ""
    else:
        client.set_tan_medium(media[0])  # one medium, or several → the first


def _client_state(client) -> str | None:
    """Base64 of deconstruct(including_private=True), or None if no system ID
    has been assigned yet (nothing useful to restore later)."""
    system_id = getattr(client, "system_id", None)
    if not system_id or system_id == SYSTEM_ID_UNASSIGNED:
        return None
    return base64.b64encode(client.deconstruct(including_private=True)).decode()


def _resolve_tan(client, mech, response):
    """Resolve a (possible) NeedTANResponse via decoupled polling."""
    if not isinstance(response, NeedTANResponse):
        return response
    if not response.decoupled:
        raise _TypedTanRequired()
    first_wait, next_wait, max_polls = _tan_wait_params(mech)
    time.sleep(first_wait)
    for _ in range(max_polls):
        response = client.send_tan(response, "")
        if not isinstance(response, NeedTANResponse):
            return response
        time.sleep(next_wait)
    raise _TanTimeout()


def _is_pin_error(e: Exception) -> bool:
    return isinstance(e, FinTSClientPINError) or _PIN_BLOCK_MSG in str(e)


def _row(tx, iban: str) -> dict:
    data = tx.data
    amount = data.get("amount")
    cents = int((amount.amount * 100).to_integral_value()) if amount is not None else 0
    booked = data.get("date") or data.get("entry_date")
    ext = (data.get("end_to_end_reference") or "").strip()
    return {
        "iban": iban,
        "booked_at": booked.isoformat() if booked else "",
        "amount_cents": cents,
        "payer": data.get("applicant_name") or data.get("posting_text") or "",
        "description": data.get("purpose") or "",
        "external_id": None if (not ext or ext.upper() == "NOTPROVIDED") else ext,
    }


@app.post("/fints/transactions")
def fints_transactions(body: FinTSIn):
    start = dt.date.fromisoformat(body.start)
    end = dt.date.fromisoformat(body.end) if body.end else dt.date.today()

    def bail(e: Exception, client=None, restored: bool = False):
        if isinstance(e, FinTSClientTemporaryAuthError):
            raise HTTPException(
                status_code=502, detail={"error": "online banking is locked", "locked": True}
            )
        if _is_pin_error(e):
            raise HTTPException(
                status_code=502,
                detail={"error": "bank rejected the PIN or login", "pin_error": True},
            )
        detail = {"error": str(e) or e.__class__.__name__}
        if restored and isinstance(e, FinTSDialogInitError):
            # The one python-fints exception raised specifically when dialog
            # initialization — the step that submits the restored system ID —
            # fails for a reason that isn't already a PIN or lock error above.
            # Only set when we actually skipped the bootstrap on a restored
            # client_state; never retried here, just flagged for the caller.
            detail["state_invalid"] = True
        raise HTTPException(status_code=502, detail=detail)

    def bail_tan(e: Exception, client=None):
        state = _client_state(client) if client is not None else None
        extra = {"client_state": state} if state else {}
        if isinstance(e, _TypedTanRequired):
            raise HTTPException(
                status_code=502,
                detail={
                    "error": "the bank asked for a typed TAN; only app-approval pushTAN is supported",
                    "tan_required": True,
                    **extra,
                },
            )
        raise HTTPException(
            status_code=502,
            detail={"error": "approval was not given in time", "tan_timeout": True, **extra},
        )

    client = None
    restored_from_state = False
    try:
        kwargs = {"from_data": base64.b64decode(body.client_state)} if body.client_state else {}
        client = FinTS3PinTanClient(
            body.blz, body.login, body.pin, body.url, product_id=body.product_id, **kwargs
        )
        mech, restored_from_state = _select_tan_mechanism(client)
        if not restored_from_state:
            _select_tan_medium(client)
    except Exception as e:
        bail(e, client=client, restored=restored_from_state)

    rows: list[dict] = []
    accounts_report: list[dict] = []

    try:
        with client:
            if client.init_tan_response:
                try:
                    _resolve_tan(client, mech, client.init_tan_response)
                except (_TanTimeout, _TypedTanRequired) as e:
                    bail_tan(e, client=client)

            try:
                accounts = _resolve_tan(client, mech, client.get_sepa_accounts())
            except (_TanTimeout, _TypedTanRequired) as e:
                bail_tan(e, client=client)

            for acc in accounts:
                iban = getattr(acc, "iban", None) or getattr(acc, "accountnumber", None) or ""
                try:
                    txs = _resolve_tan(client, mech, client.get_transactions(acc, start, end))
                except (_TanTimeout, _TypedTanRequired):
                    raise
                except Exception as e:
                    if isinstance(e, FinTSClientTemporaryAuthError) or _is_pin_error(e):
                        raise
                    accounts_report.append({"iban": iban, "error": str(e) or e.__class__.__name__})
                    continue

                accounts_report.append({"iban": iban, "rows": len(txs)})
                rows.extend(_row(tx, iban) for tx in txs)
    except HTTPException:
        raise
    except (_TanTimeout, _TypedTanRequired) as e:
        bail_tan(e, client=client)
    except Exception as e:
        bail(e, client=client, restored=restored_from_state)

    result = {"rows": rows, "accounts": accounts_report}
    state = _client_state(client)
    if state:
        result["client_state"] = state
    return result
