#!/usr/bin/env python3
"""Runs pdfcu over the fixtures with every preset/codec and validates results.

Checks: output opens in qpdf (pikepdf) without errors, same page count, same
extracted text, rendered pages visually close to the original (PSNR), and
text-only documents are compressed losslessly (pixel-identical rendering).

Usage: python3 Tests/verify.py <pdfcu-binary> <fixtures-dir> <out-dir>
"""
import os
import subprocess
import sys

import numpy as np
import pikepdf
import pypdfium2 as pdfium
from pypdf import PdfReader

PDFCU, FIX, OUT = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(OUT, exist_ok=True)

CONFIGS = [
    ("strong", ["-p", "strong"]),
    ("optimal-strong", ["-p", "optimal-strong"]),
    ("optimal", ["-p", "optimal"]),
    ("medium", ["-p", "medium"]),
    ("light", ["-p", "light"]),
    ("manual-200-85", ["--dpi", "200", "--quality", "85"]),
    ("lossless", ["--lossless"]),
    ("keep-page-2", ["-p", "strong", "--keep-pages", "2"]),
    ("gray", ["-p", "optimal", "--color", "gray"]),
    ("bw", ["-p", "optimal", "--color", "bw"]),
]
# Images in these files must get smaller (resolution really reduced) at "strong".
MUST_SHRINK = {"mixed.pdf": 0.5, "scan.pdf": 0.5, "cmyk.pdf": 0.5, "objstm.pdf": 0.5, "pattern_images.pdf": 0.5}
PASSWORDS = {"enc_password.pdf": "secret"}

failures = []


def render(path, password=None):
    doc = pdfium.PdfDocument(path, password=password)
    pages = []
    for i in range(len(doc)):
        bmp = doc[i].render(scale=1.0).to_pil().convert("RGB")
        pages.append(np.asarray(bmp, dtype=np.float32))
    return pages


def psnr(a, b):
    if a.shape != b.shape:
        return 0.0
    mse = float(np.mean((a - b) ** 2))
    return 99.0 if mse == 0 else 10 * np.log10(255.0 ** 2 / mse)


def texts(path, password=None):
    r = PdfReader(path)
    if r.is_encrypted:
        r.decrypt(password or "")
    return [(p.extract_text() or "").strip() for p in r.pages]


rows = []
for name in sorted(os.listdir(FIX)):
    if not name.endswith(".pdf"):
        continue
    if sys.platform.startswith("linux") and name.startswith("enc_"):
        print(f"skip {name}: decryption needs CommonCrypto (macOS)")
        continue
    src = os.path.join(FIX, name)
    pw = PASSWORDS.get(name)
    ref_pages = render(src, pw)
    ref_text = texts(src, pw)
    for cfg, args in CONFIGS:
        dst = os.path.join(OUT, f"{name[:-4]}.{cfg}.pdf")
        cmd = [PDFCU, src, "-o", dst, "-q", "-v"] + args + (["--password", pw] if pw else [])
        p = subprocess.run(cmd, capture_output=True, text=True)
        if cfg == "strong":
            print(f"--- {name} [{cfg}]\n{p.stdout}")
        if p.returncode != 0:
            failures.append(f"{name} [{cfg}]: exit {p.returncode}: {p.stderr.strip()}")
            continue
        try:
            with pikepdf.open(dst) as pdf:
                problems = (pdf.check_pdf_syntax() if hasattr(pdf, "check_pdf_syntax") else pdf.check())
                n = len(pdf.pages)
            if problems:
                failures.append(f"{name} [{cfg}]: qpdf check: {problems[:3]}")
        except Exception as e:  # noqa: BLE001
            failures.append(f"{name} [{cfg}]: cannot open: {e}")
            continue
        if n != len(ref_pages):
            failures.append(f"{name} [{cfg}]: page count {n} != {len(ref_pages)}")
            continue
        out_text = texts(dst)
        if out_text != ref_text:
            failures.append(f"{name} [{cfg}]: extracted text differs")
        out_pages = render(dst)
        if cfg in ("gray", "bw"):
            # no color may remain on the page
            for k, op in enumerate(out_pages):
                chroma = float(np.percentile(np.abs(op[..., 0] - op[..., 1]) + np.abs(op[..., 1] - op[..., 2]), 99.9))
                if chroma > 12:
                    failures.append(f"{name} [{cfg}]: page {k + 1} still has color (chroma {chroma:.0f})")
            to_gray = lambda p: np.repeat((0.299 * p[..., 0] + 0.587 * p[..., 1] + 0.114 * p[..., 2])[..., None], 3, 2)
            ref_cmp = [to_gray(p) for p in ref_pages]
        else:
            ref_cmp = ref_pages
        worst = min(psnr(a, b) for a, b in zip(ref_cmp, out_pages))
        limit = 18.0
        if cfg == "lossless" or name == "text_only.pdf":
            # lossless mode still downsamples: fine text in scans loses some detail
            limit = 99.0 if name == "text_only.pdf" else (30.0 if name == "doc_scan.pdf" else 40.0)
        if cfg == "gray":
            limit = 22.0
        if cfg == "bw":
            limit = 12.0  # thresholding changes the look of scans by design
        if worst < limit:
            failures.append(f"{name} [{cfg}]: render PSNR {worst:.1f} dB < {limit}")
        if cfg == "keep-page-2" and len(ref_pages) >= 2:
            q2 = psnr(ref_pages[1], out_pages[1])
            if q2 < 60:
                failures.append(f"{name} [{cfg}]: protected page 2 changed (PSNR {q2:.1f})")
        if cfg == "bw":
            with pikepdf.open(dst) as pdf:
                filters = set()
                for page in pdf.pages:
                    for _, img in page.images.items():
                        f = img.get("/Filter")
                        filters.add(str(f))
            bilevel = {"/CCITTFaxDecode", "/JBIG2Decode"}
            if name == "doc_scan.pdf" and not (filters & bilevel):
                failures.append(f"{name} [bw]: text scan was not converted to 1-bit ({filters})")
            if name in ("scan.pdf", "mixed.pdf") and (filters & bilevel):
                failures.append(f"{name} [bw]: photo was wrongly converted to 1-bit")
            if name == "doc_scan.pdf":
                # Cross-check decoding with MuPDF (jbig2dec) and, on macOS, with Quartz
                # (Preview), at the native 300 dpi where one image pixel = one device pixel.
                import fitz
                ref = np.asarray(pdfium.PdfDocument(dst)[0].render(scale=300 / 72).to_pil().convert("L")) < 128
                pm = fitz.open(dst)[0].get_pixmap(dpi=300, colorspace=fitz.csGRAY)
                mu = np.frombuffer(pm.samples, np.uint8).reshape(pm.height, pm.width) < 128
                def mismatch(a, b):
                    h_, w_ = min(a.shape[0], b.shape[0]), min(a.shape[1], b.shape[1])
                    return float(np.mean(a[:h_, :w_] != b[:h_, :w_]))
                diff = mismatch(mu, ref)
                print(f"doc_scan bw: filters {filters}, MuPDF vs pdfium differing pixels {diff:.5f}")
                if diff > 0.005:
                    failures.append(f"{name} [bw]: MuPDF renders differently ({diff:.4f})")
                if sys.platform == "darwin":
                    png = dst + ".quartz.png"
                    here = os.path.dirname(os.path.abspath(__file__))
                    subprocess.run(["swift", os.path.join(here, "quartz_render.swift"), dst, png, "300"],
                                   capture_output=True)
                    if not os.path.exists(png):
                        failures.append(f"{name} [bw]: Quartz could not render the result")
                    else:
                        from PIL import Image as _I
                        q = np.asarray(_I.open(png).convert("L")) < 128
                        qd = mismatch(q, ref)
                        print(f"doc_scan bw: Quartz vs pdfium differing pixels {qd:.5f}")
                        if qd > 0.005:
                            failures.append(f"{name} [bw]: Quartz renders differently ({qd:.4f})")
        a, b = os.path.getsize(src), os.path.getsize(dst)
        if cfg == "strong" and name in MUST_SHRINK and b > a * MUST_SHRINK[name]:
            failures.append(f"{name} [{cfg}]: only {100 * (1 - b / a):.0f}% smaller — images not downsampled?")
        rows.append((name, cfg, a, b, worst))

# Master mode must see images painted through tiling patterns (macOS Quartz PDFs).
pat = os.path.join(FIX, "pattern_images.pdf")
if os.path.exists(pat):
    out = subprocess.run([PDFCU, pat, "--list-images"], capture_output=True, text=True).stdout
    print(out)
    if out.count("ppi") < 2:
        failures.append("pattern_images.pdf: images inside tiling patterns not found by --list-images")

print(f"{'file':20s} {'config':16s} {'orig KB':>9s} {'new KB':>9s} {'saved':>7s} {'PSNR':>6s}")
for name, cfg, a, b, q in rows:
    print(f"{name:20s} {cfg:16s} {a / 1024:9.1f} {b / 1024:9.1f} {100 * (1 - b / a):6.1f}% {q:6.1f}")

sizes = {(n, c): b for n, c, a, b, q in rows}
if ("doc_scan.pdf", "bw") in sizes and ("doc_scan.pdf", "optimal") in sizes:
    print(f"doc_scan: optimal {sizes[('doc_scan.pdf', 'optimal')] / 1024:.0f} KB, "
          f"gray {sizes.get(('doc_scan.pdf', 'gray'), 0) / 1024:.0f} KB, bw {sizes[('doc_scan.pdf', 'bw')] / 1024:.0f} KB")

if failures:
    print("\nFAILURES:")
    for f in failures:
        print("  " + f)
    sys.exit(1)
print("\nAll checks passed.")
