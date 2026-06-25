#!/usr/bin/env python3
"""Paperless-ngx post-consume classifier (generic, API-driven).

Runs after every document is consumed. The controlled vocabulary — tags,
document types, correspondents — is pulled LIVE from the Paperless API, so no
site-specific data is baked into this script and it adapts automatically as the
library's tags/types evolve. Claude normalises the metadata against that
vocabulary; high/medium-confidence results are applied and the inbox tag
removed; low-confidence (or any error) leaves the document tagged for review.
Stdlib-only — no third-party packages in the Paperless image.

Env:
  ANTHROPIC_API_KEY            Claude API key (required)
  PAPERLESS_API_TOKEN          Paperless API token (required)
  PAPERLESS_LLM_API_URL        Paperless base URL (default http://localhost:8000)
  PAPERLESS_LLM_MODEL          Claude model id (default claude-opus-4-8)
  PAPERLESS_LLM_INBOX_TAG      review tag name (default "inbox")
  PAPERLESS_LLM_EXTRA_CONTEXT  optional private disambiguation hints (default "")
  DOCUMENT_ID                  injected by Paperless
"""
import base64, json, os, re, sys, urllib.request, urllib.error, urllib.parse, time

API = os.environ.get("PAPERLESS_LLM_API_URL", "http://localhost:8000").rstrip("/")
PTOKEN = os.environ.get("PAPERLESS_API_TOKEN", "")
AKEY = os.environ.get("ANTHROPIC_API_KEY", "")
MODEL = os.environ.get("PAPERLESS_LLM_MODEL", "claude-opus-4-8")
INBOX_NAME = os.environ.get("PAPERLESS_LLM_INBOX_TAG", "inbox")
EXTRA = os.environ.get("PAPERLESS_LLM_EXTRA_CONTEXT", "").strip()
DOC_ID = os.environ.get("DOCUMENT_ID", "")
OCR_MIN = int(os.environ.get("PAPERLESS_LLM_OCR_MIN", "30"))  # below this, fall back to vision

RULES = """For the document below, read its OCR content and current fields, then return clean
normalised metadata via the `classify` tool, following these rules:

document_type — choose EXACTLY ONE from the existing types listed above. A type = what KIND of
  document it is (the subject goes in tags). If none truly fits, pick the closest and set
  confidence=low.

correspondent — the entity that ISSUED the document. Clean canonical Title-Case name; reuse an
  existing correspondent from the list above whenever it matches. NEVER an email address; use the
  full legal name rather than an abbreviation or trading shorthand. If the issuer cannot be
  determined, return "" and confidence=low.

tags — choose ALL that apply ONLY from the existing tag list above (tag the people, property,
  vehicle, subject, etc.). Do NOT invent tags outside that list, EXCEPT financial-year tags of the
  form `fyNN`: if the library uses them, assign the correct one (Australian financial year runs
  1 Jul-30 Jun and is named for the year it ENDS in, so 15 Aug 2022 -> fy23). Do NOT use a
  document-type word as a tag.

title — format `Concise Description [key-id]`. Plain English (translate any other language). Do
  NOT put the correspondent or the date in the title (they have their own fields). Be specific.
  Put a key identifier (invoice/policy/claim/certificate number) in [brackets] at the end only when
  it aids retrieval. Add a person in (parentheses) when it disambiguates. Never output "Untitled" or
  scanner junk — derive a real description from the content.

date — the document's own issue date as YYYY-MM-DD, extracted from the content; fix wrong or
  placeholder dates. If none is findable, return "".

confidence — high (clear), medium (minor uncertainty), low (garbage OCR / unknown issuer / guessed)."""

def log(msg): print(f"[post_consume] {msg}", flush=True)

# ----------------------------------------------------------- paperless api ---
def papi(method, path, data=None):
    body = json.dumps(data).encode() if data is not None else None
    req = urllib.request.Request(f"{API}{path}", data=body, method=method,
        headers={"Authorization": f"Token {PTOKEN}", "Content-Type": "application/json"})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                raw = r.read().decode("utf-8")
                return json.loads(raw, strict=False) if raw.strip() else {}
        except urllib.error.HTTPError as e:
            if e.code in (429, 502, 503) and attempt < 2:
                time.sleep(2); continue
            raise
        except Exception:
            if attempt < 2:
                time.sleep(2); continue
            raise

def fetch_all(ep):
    """Return [{id,name}] for a taxonomy endpoint, following pagination."""
    out, url = [], f"/api/{ep}/?page_size=250&ordering=name"
    while url:
        d = papi("GET", url)
        out += [{"id": x["id"], "name": x["name"]} for x in d.get("results", [])]
        nxt = d.get("next")
        url = nxt.split("/api", 1)[1] if nxt else None
        if url:
            url = "/api" + url
    return out

def find_or_create(ep, name):
    q = urllib.parse.quote(name)
    res = papi("GET", f"/api/{ep}/?name__iexact={q}&page_size=1")
    if res.get("results"):
        return res["results"][0]["id"]
    return papi("POST", f"/api/{ep}/", {"name": name})["id"]

def fetch_bytes(path):
    req = urllib.request.Request(f"{API}{path}", headers={"Authorization": f"Token {PTOKEN}"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read()

def doc_file(doc_id, doc, archive=False):
    """Bytes + media type for the vision fallback. The ORIGINAL is the clean source (no OCR
    text layer to mislead the model); the archive PDF is the fallback when an original scanner
    image is too large for the image endpoint (the PDF render is downsized)."""
    if archive:
        return fetch_bytes(f"/api/documents/{doc_id}/download/?original=false"), "application/pdf"
    blob = fetch_bytes(f"/api/documents/{doc_id}/download/")
    if len(blob) > 28 * 1024 * 1024:
        raise RuntimeError(f"file too large for vision ({len(blob)} bytes)")
    return blob, (doc.get("mime_type") or "application/pdf")

# -------------------------------------------------------------- anthropic ---
def classify(cur, tags, types, corrs, content=None, doc_bytes=None, doc_media=None):
    type_names = [t["name"] for t in types]
    tag_names = [t["name"] for t in tags]
    corr_names = [c["name"] for c in corrs]
    system = (
        "You normalise metadata for a personal Paperless-ngx document archive. Use ONLY the "
        "library's existing vocabulary, provided below.\n\n"
        f"EXISTING DOCUMENT TYPES:\n{', '.join(type_names)}\n\n"
        f"EXISTING TAGS:\n{', '.join(n for n in tag_names if n != INBOX_NAME)}\n\n"
        f"EXISTING CORRESPONDENTS:\n{', '.join(corr_names)}\n\n"
        + (f"ADDITIONAL CONTEXT:\n{EXTRA}\n\n" if EXTRA else "")
        + RULES
    )
    ctx = (f"Current title: {cur.get('title')!r}\n"
           f"Current correspondent: {cur.get('correspondent_name')!r}\n"
           f"Current type: {cur.get('type_name')!r}\n"
           f"Current tags: {cur.get('tag_names')}\n"
           f"Current date: {cur.get('created_date')!r}\n")
    if doc_bytes is not None:
        if (doc_media or "").startswith("image/"):
            src = {"type": "image", "source": {"type": "base64", "media_type": doc_media,
                   "data": base64.b64encode(doc_bytes).decode()}}
        else:
            src = {"type": "document", "source": {"type": "base64", "media_type": "application/pdf",
                   "data": base64.b64encode(doc_bytes).decode()}}
        user = [src, {"type": "text", "text": ctx +
                "\nThe OCR text was empty or unreadable — classify from the attached document above."}]
    else:
        user = ctx + f"\n--- OCR CONTENT (truncated) ---\n{(content or '')[:8000]}"
    tool = {
        "name": "classify",
        "description": "Return normalised metadata for the document.",
        "input_schema": {
            "type": "object",
            "properties": {
                "document_type": ({"type": "string", "enum": type_names} if type_names else {"type": "string"}),
                "correspondent": {"type": "string"},
                "tags": {"type": "array", "items": {"type": "string"}},
                "title": {"type": "string"},
                "date": {"type": "string", "description": "YYYY-MM-DD or empty"},
                "confidence": {"type": "string", "enum": ["high", "medium", "low"]},
                "notes": {"type": "string"},
            },
            "required": ["document_type", "correspondent", "tags", "title", "date", "confidence"],
            "additionalProperties": False,
        },
    }
    payload = {
        "model": MODEL, "max_tokens": 1024, "system": system, "tools": [tool],
        "tool_choice": {"type": "tool", "name": "classify"},
        "messages": [{"role": "user", "content": user}],
    }
    req = urllib.request.Request("https://api.anthropic.com/v1/messages",
        data=json.dumps(payload).encode(), method="POST",
        headers={"x-api-key": AKEY, "anthropic-version": "2023-06-01", "content-type": "application/json"})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=90) as r:
                resp = json.loads(r.read().decode("utf-8"))
            break
        except urllib.error.HTTPError as e:
            if e.code in (429, 500, 529) and attempt < 2:
                time.sleep(3); continue
            raise
    for block in resp.get("content", []):
        if block.get("type") == "tool_use" and block.get("name") == "classify":
            return block["input"]
    raise RuntimeError(f"no tool_use in response: stop_reason={resp.get('stop_reason')}")

# ------------------------------------------------------------------ main ---
def main():
    if not DOC_ID:
        log("no DOCUMENT_ID; nothing to do"); return
    if not (AKEY and PTOKEN):
        log("missing ANTHROPIC_API_KEY or PAPERLESS_API_TOKEN; leaving in inbox"); return

    tags = fetch_all("tags")
    types = fetch_all("document_types")
    corrs = fetch_all("correspondents")
    tag_names = {t["name"] for t in tags}
    type_names = {t["name"] for t in types}
    inbox_id = find_or_create("tags", INBOX_NAME)

    doc = papi("GET", f"/api/documents/{DOC_ID}/")
    content = doc.get("content") or ""

    def name_of(ep, _id):
        if not _id: return None
        try: return papi("GET", f"/api/{ep}/{_id}/").get("name")
        except Exception: return None
    cur = {
        "title": doc.get("title"), "created_date": doc.get("created_date"),
        "correspondent_name": name_of("correspondents", doc.get("correspondent")),
        "type_name": name_of("document_types", doc.get("document_type")),
        "tag_names": [name_of("tags", t) for t in (doc.get("tags") or [])],
    }

    try:
        if len(content.strip()) < OCR_MIN:
            blob, media = doc_file(DOC_ID, doc)
            try:
                result = classify(cur, tags, types, corrs, doc_bytes=blob, doc_media=media)
            except urllib.error.HTTPError:
                # original (often an oversized scanner image) rejected -> retry via archive PDF
                if not doc.get("archived_file_name"):
                    raise
                blob, media = doc_file(DOC_ID, doc, archive=True)
                result = classify(cur, tags, types, corrs, doc_bytes=blob, doc_media=media)
            log(f"doc {DOC_ID}: OCR empty -> vision fallback ({media})")
        else:
            result = classify(cur, tags, types, corrs, content=content)
    except Exception as e:
        log(f"doc {DOC_ID}: classification failed ({e}); leaving in inbox"); return

    conf = result.get("confidence", "low")
    log(f"doc {DOC_ID}: type={result.get('document_type')} corr={result.get('correspondent')!r} "
        f"conf={conf} title={result.get('title')!r} notes={result.get('notes','')[:120]}")

    if conf == "low":
        cur_tags = doc.get("tags") or []
        if inbox_id not in cur_tags:
            papi("PATCH", f"/api/documents/{DOC_ID}/", {"tags": cur_tags + [inbox_id]})
        log(f"doc {DOC_ID}: low confidence -> left in inbox"); return

    # accept only existing tags (+ fyNN financial-year tags); never invent vocabulary
    tag_ids = []
    for t in result.get("tags", []):
        if t == INBOX_NAME:
            continue
        if t in tag_names or re.fullmatch(r"fy\d{2}", t):
            tid = find_or_create("tags", t)
            if tid not in tag_ids:
                tag_ids.append(tid)

    patch = {"title": (result.get("title") or "").strip()[:120], "tags": tag_ids}
    dt = result.get("document_type")
    if dt in type_names:
        patch["document_type"] = find_or_create("document_types", dt)
    corr = (result.get("correspondent") or "").strip()
    if corr:
        patch["correspondent"] = find_or_create("correspondents", corr)
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}", result.get("date") or ""):
        patch["created"] = result["date"]

    papi("PATCH", f"/api/documents/{DOC_ID}/", patch)
    log(f"doc {DOC_ID}: applied ({conf}); removed from inbox")

if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        log(f"unexpected error: {e}")
    sys.exit(0)
