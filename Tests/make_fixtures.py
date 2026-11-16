#!/usr/bin/env python3
"""Generates test PDFs covering the cases the compressor must handle.

Requires: reportlab, pillow, numpy, pikepdf
Usage: python3 Tests/make_fixtures.py <output-dir>
"""
import io
import os
import sys

import numpy as np
import pikepdf
from PIL import Image
from reportlab.lib.colors import CMYKColor, HexColor
from reportlab.lib.pagesizes import A4
from reportlab.lib.utils import ImageReader
from reportlab.pdfgen import canvas

OUT = sys.argv[1] if len(sys.argv) > 1 else "fixtures"
os.makedirs(OUT, exist_ok=True)
W, H = A4
rng = np.random.default_rng(42)


def photo(w, h, mode="RGB"):
    """Smooth synthetic 'photo' with some texture."""
    y, x = np.mgrid[0:h, 0:w].astype(np.float32)
    r = 127 + 120 * np.sin(x / w * 6.0) * np.cos(y / h * 4.0)
    g = 127 + 120 * np.sin((x + y) / (w + h) * 9.0)
    b = 127 + 120 * np.cos(np.hypot(x - w / 2, y - h / 2) / max(w, h) * 12.0)
    img = np.stack([r, g, b], axis=-1) + rng.normal(0, 6, (h, w, 3))
    img = Image.fromarray(np.clip(img, 0, 255).astype(np.uint8), "RGB")
    return img.convert(mode) if mode != "RGB" else img


def text_page(c, title, lines=40):
    c.setFont("Helvetica-Bold", 18)
    c.drawString(60, H - 70, title)
    c.setFont("Times-Roman", 11)
    for i in range(lines):
        c.drawString(60, H - 100 - i * 16, f"Line {i + 1}: The quick brown fox jumps over the lazy dog. 0123456789")
    # vector graphics
    c.setStrokeColor(HexColor("#C0392B"))
    c.setLineWidth(2)
    for i in range(12):
        c.circle(W - 120, 140, 10 + i * 6)
    c.setFillColor(CMYKColor(0.1, 0.6, 0.9, 0.1))
    c.rect(60, 60, 200, 40, fill=1)


def jpeg_reader(img, q=95):
    buf = io.BytesIO()
    img.save(buf, "JPEG", quality=q)
    buf.seek(0)
    return ImageReader(buf)


# 1. Text and vectors only, uncompressed content streams
c = canvas.Canvas(f"{OUT}/text_only.pdf", pagesize=A4, pageCompression=0)
for p in range(5):
    text_page(c, f"Text only page {p + 1}")
    c.showPage()
c.save()

# 2. Mixed document: text pages + photo pages + transparency + gray + palette
c = canvas.Canvas(f"{OUT}/mixed.pdf", pagesize=A4, pageCompression=1)
text_page(c, "Mixed: text page")
c.showPage()
c.drawImage(jpeg_reader(photo(3000, 2000)), 60, 300, width=6 * 72, height=4 * 72)  # ~500 ppi
c.setFont("Helvetica", 12)
c.drawString(60, 270, "Photo above is 3000x2000 px placed at 6x4 inch (500 ppi).")
c.showPage()
text_page(c, "Text + images", lines=12)
rgba = photo(800, 600).convert("RGBA")
alpha = Image.fromarray((np.linspace(0, 255, 800)[None, :].repeat(600, 0)).astype(np.uint8))
rgba.putalpha(alpha)
c.drawImage(ImageReader(rgba), 60, 300, width=200, height=150, mask="auto")  # Flate + SMask
c.drawImage(ImageReader(photo(1200, 900, "L")), 300, 300, width=200, height=150)  # gray, raw Flate
pal = photo(600, 400).convert("P", palette=Image.ADAPTIVE, colors=16)
c.drawImage(ImageReader(pal), 60, 120, width=200, height=133)
c.showPage()
c.save()

# 3. Scan-like: full page gray image at 300 dpi
c = canvas.Canvas(f"{OUT}/scan.pdf", pagesize=A4)
scan = photo(2480, 3508, "L")
c.drawImage(jpeg_reader(scan, 92), 0, 0, width=W, height=H)
c.showPage()
c.save()

# 4. CMYK JPEG
c = canvas.Canvas(f"{OUT}/cmyk.pdf", pagesize=A4)
c.drawImage(jpeg_reader(photo(1600, 1200).convert("CMYK"), 95), 60, 300, width=400, height=300)
c.showPage()
c.save()

# 5. Same document re-saved with object streams, and encrypted variants
with pikepdf.open(f"{OUT}/mixed.pdf") as pdf:
    pdf.save(f"{OUT}/objstm.pdf", object_stream_mode=pikepdf.ObjectStreamMode.generate)
    pdf.save(f"{OUT}/enc_aes256.pdf", encryption=pikepdf.Encryption(owner="owner", user="", R=6))
    pdf.save(f"{OUT}/enc_aes128.pdf", encryption=pikepdf.Encryption(owner="owner", user="", R=4, aes=True))
    pdf.save(f"{OUT}/enc_rc4.pdf", encryption=pikepdf.Encryption(owner="owner", user="", R=3, aes=False, metadata=False))
    pdf.save(f"{OUT}/enc_password.pdf", encryption=pikepdf.Encryption(owner="owner", user="secret", R=6))

# 6. Duplicated image on many pages (each page embeds its own copy)
c = canvas.Canvas(f"{OUT}/duplicates.pdf", pagesize=A4)
img = photo(1000, 700)
for p in range(4):
    buf = io.BytesIO()
    img.save(buf, "PNG")
    buf.seek(0)
    c.drawImage(ImageReader(buf), 60, 400, width=300, height=210)
    c.drawString(60, 380, f"Page {p + 1}")
    c.showPage()
c.save()

# 7. Damaged xref: break startxref offset
data = open(f"{OUT}/mixed.pdf", "rb").read()
idx = data.rfind(b"startxref")
broken = data[:idx] + b"startxref\n123\n%%EOF\n"
open(f"{OUT}/broken_xref.pdf", "wb").write(broken)

print("fixtures written to", OUT)
for f in sorted(os.listdir(OUT)):
    print(f"  {f:22s} {os.path.getsize(os.path.join(OUT, f)) / 1024:9.1f} KB")
