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
    ("strong-jpegli", ["-p", "strong", "-c", "jpegli"]),
    ("optimal-jpegli", ["-p", "optimal", "-c", "jpegli"]),
    ("light-jpegli", ["-p", "light", "-c", "jpegli"]),
    ("strong-jp2", ["-p", "strong", "-c", "jpeg2000"]),
    ("medium-jp2", ["-p", "medium", "-c", "jpeg2000"]),
    ("manual-200-85", ["--dpi", "200", "--quality", "85"]),
    ("lossless", ["--lossless"]),
]
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
        cmd = [PDFCU, src, "-o", dst, "-q"] + args + (["--password", pw] if pw else [])
        p = subprocess.run(cmd, capture_output=True, text=True)
        if p.returncode != 0:
            failures.append(f"{name} [{cfg}]: exit {p.returncode}: {p.stderr.strip()}")
            continue
        try:
            with pikepdf.open(dst) as pdf:
                problems = pdf.check()
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
        worst = min(psnr(a, b) for a, b in zip(ref_pages, out_pages))
        limit = 18.0
        if cfg == "lossless" or name == "text_only.pdf":
            limit = 99.0 if name == "text_only.pdf" else 40.0
        if worst < limit:
            failures.append(f"{name} [{cfg}]: render PSNR {worst:.1f} dB < {limit}")
        a, b = os.path.getsize(src), os.path.getsize(dst)
        rows.append((name, cfg, a, b, worst))

print(f"{'file':20s} {'config':16s} {'orig KB':>9s} {'new KB':>9s} {'saved':>7s} {'PSNR':>6s}")
for name, cfg, a, b, q in rows:
    print(f"{name:20s} {cfg:16s} {a / 1024:9.1f} {b / 1024:9.1f} {100 * (1 - b / a):6.1f}% {q:6.1f}")

if failures:
    print("\nFAILURES:")
    for f in failures:
        print("  " + f)
    sys.exit(1)
print("\nAll checks passed.")
