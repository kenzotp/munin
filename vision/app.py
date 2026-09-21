# munin_vision — the reading brain's Python half.
#
# Endpoints (all file access is by ABSOLUTE path, and the path must be inside
# VAULT_PATH — this sidecar reads nothing else):
#   GET  /health
#   POST /extract  {path}  → {text, reader, pages}   embedded text layer (pypdf)
#                                                     or office/html text (markitdown)
#   POST /render   {path}  → {pages: [{n, jpeg_base64}]}  capped page renders (pymupdf)
#
# Originals are opened read-only; nothing here ever writes to a document.
import base64
import os
from pathlib import Path

from fastapi import FastAPI, HTTPException
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
# Read-only statement fetch. Credentials arrive per-request from the web app's
# env; nothing is logged or persisted here. The DK product registration ID
# must never be shipped in a public repo — each self-hoster registers their own.

class FinTSIn(BaseModel):
    blz: str
    url: str
    login: str
    pin: str
    product_id: str
    start: str
    end: str | None = None


@app.post("/fints/transactions")
def fints_transactions(body: FinTSIn):
    import datetime as dt

    from fints.client import FinTS3PinTanClient

    start = dt.date.fromisoformat(body.start)
    end = dt.date.fromisoformat(body.end) if body.end else dt.date.today()

    def tan_err(e: Exception) -> bool:
        msg = str(e) or ""
        return "tan" in msg.lower() or "3920" in msg or "NeedTAN" in e.__class__.__name__

    try:
        client = FinTS3PinTanClient(
            body.blz, body.login, body.pin, body.url, product_id=body.product_id
        )
        accounts = client.get_sepa_accounts()
    except Exception as e:
        raise HTTPException(
            status_code=502,
            detail={"error": str(e) or e.__class__.__name__, "tan_required": tan_err(e)},
        )

    rows = []
    per_account = []
    for acc in accounts:
        per_account.append(f"{getattr(acc, 'iban', None) or getattr(acc, 'accountnumber', '?')} ({acc.type})")
        try:
            statement = client.get_statement(full_account_ref=acc, start_date=start, end_date=end)
        except Exception as e:
            if tan_err(e):
                raise HTTPException(status_code=502, detail={"error": str(e) or e.__class__.__name__, "tan_required": True})
            continue  # skip an account that won't play; fetch the rest

        for tx in statement:
            data = tx.data
            amount = data.get("amount")
            cents = int(round(float(amount.value) * 100)) if amount is not None else 0
            purpose = " ".join(data.get("purpose") or [])
            ext = data.get("id") or data.get("end_to_endreference") or None
            iban = getattr(acc, "iban", None)
            rows.append(
                {
                    "booked_at": str(data.get("date") or data.get("entry_date") or ""),
                    "amount_cents": cents,
                    "payer": data.get("applicant_name") or data.get("posting_text") or "",
                    "description": purpose,
                    "iban": iban,
                    "external_id": f"{iban}:{ext}" if (iban and ext) else None,
                }
            )

    return {"rows": rows, "accounts": per_account}
