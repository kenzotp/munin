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
