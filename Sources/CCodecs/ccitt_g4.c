/* CCITT Group 4 (T.6) encoder, same algorithm as libtiff's Fax3Encode2DRow. */
#include "ccodecs.h"
#include <stdlib.h>
#include <string.h>

typedef struct { unsigned short len; unsigned short code; } g4code;

/* {length in bits, code} for run lengths 0..63 */
static const g4code white_term[64] = {
  {8,0x35},{6,0x07},{4,0x07},{4,0x08},{4,0x0B},{4,0x0C},{4,0x0E},{4,0x0F},
  {5,0x13},{5,0x14},{5,0x07},{5,0x08},{6,0x08},{6,0x03},{6,0x34},{6,0x35},
  {6,0x2A},{6,0x2B},{7,0x27},{7,0x0C},{7,0x08},{7,0x17},{7,0x03},{7,0x04},
  {7,0x28},{7,0x2B},{7,0x13},{7,0x24},{7,0x18},{8,0x02},{8,0x03},{8,0x1A},
  {8,0x1B},{8,0x12},{8,0x13},{8,0x14},{8,0x15},{8,0x16},{8,0x17},{8,0x28},
  {8,0x29},{8,0x2A},{8,0x2B},{8,0x2C},{8,0x2D},{8,0x04},{8,0x05},{8,0x0A},
  {8,0x0B},{8,0x52},{8,0x53},{8,0x54},{8,0x55},{8,0x24},{8,0x25},{8,0x58},
  {8,0x59},{8,0x5A},{8,0x5B},{8,0x4A},{8,0x4B},{8,0x32},{8,0x33},{8,0x34}};
/* makeup codes for 64..1728 step 64 (index = run/64 - 1) */
static const g4code white_makeup[27] = {
  {5,0x1B},{5,0x12},{6,0x17},{7,0x37},{8,0x36},{8,0x37},{8,0x64},{8,0x65},
  {8,0x68},{8,0x67},{9,0xCC},{9,0xCD},{9,0xD2},{9,0xD3},{9,0xD4},{9,0xD5},
  {9,0xD6},{9,0xD7},{9,0xD8},{9,0xD9},{9,0xDA},{9,0xDB},{9,0x98},{9,0x99},
  {9,0x9A},{6,0x18},{9,0x9B}};
static const g4code black_term[64] = {
  {10,0x37},{3,0x02},{2,0x03},{2,0x02},{3,0x03},{4,0x03},{4,0x02},{5,0x03},
  {6,0x05},{6,0x04},{7,0x04},{7,0x05},{7,0x07},{8,0x04},{8,0x07},{9,0x18},
  {10,0x17},{10,0x18},{10,0x08},{11,0x67},{11,0x68},{11,0x6C},{11,0x37},{11,0x28},
  {11,0x17},{11,0x18},{12,0xCA},{12,0xCB},{12,0xCC},{12,0xCD},{12,0x68},{12,0x69},
  {12,0x6A},{12,0x6B},{12,0xD2},{12,0xD3},{12,0xD4},{12,0xD5},{12,0xD6},{12,0xD7},
  {12,0x6C},{12,0x6D},{12,0xDA},{12,0xDB},{12,0x54},{12,0x55},{12,0x56},{12,0x57},
  {12,0x64},{12,0x65},{12,0x52},{12,0x53},{12,0x24},{12,0x37},{12,0x38},{12,0x27},
  {12,0x28},{12,0x58},{12,0x59},{12,0x2B},{12,0x2C},{12,0x5A},{12,0x66},{12,0x67}};
static const g4code black_makeup[27] = {
  {10,0x0F},{12,0xC8},{12,0xC9},{12,0x5B},{12,0x33},{12,0x34},{12,0x35},{13,0x6C},
  {13,0x6D},{13,0x4A},{13,0x4B},{13,0x4C},{13,0x4D},{13,0x72},{13,0x73},{13,0x74},
  {13,0x75},{13,0x76},{13,0x77},{13,0x52},{13,0x53},{13,0x54},{13,0x55},{13,0x5A},
  {13,0x5B},{13,0x64},{13,0x65}};
/* 1792..2560 step 64, shared by both colors */
static const g4code ext_makeup[13] = {
  {11,0x08},{11,0x0C},{11,0x0D},{12,0x12},{12,0x13},{12,0x14},{12,0x15},{12,0x16},
  {12,0x17},{12,0x1C},{12,0x1D},{12,0x1E},{12,0x1F}};
/* vertical codes for d = b1 - a1 = -3..3 */
static const g4code vcodes[7] = {
  {7,0x03},{6,0x03},{3,0x03},{1,0x01},{3,0x02},{6,0x02},{7,0x02}};

typedef struct {
  uint8_t *buf;
  size_t len, cap;
  uint32_t acc;
  int nbits;
  int failed;
} bitw;

static void putbits(bitw *w, unsigned code, int len) {
  w->acc = (w->acc << len) | (code & ((1u << len) - 1));
  w->nbits += len;
  while (w->nbits >= 8) {
    if (w->len >= w->cap) {
      size_t ncap = w->cap * 2 + 1024;
      uint8_t *nb = (uint8_t *)realloc(w->buf, ncap);
      if (!nb) { w->failed = 1; w->nbits = 0; return; }
      w->buf = nb; w->cap = ncap;
    }
    w->buf[w->len++] = (uint8_t)(w->acc >> (w->nbits - 8));
    w->nbits -= 8;
  }
}

static void putspan(bitw *w, int span, int black) {
  const g4code *term = black ? black_term : white_term;
  const g4code *makeup = black ? black_makeup : white_makeup;
  while (span >= 2624) {
    putbits(w, ext_makeup[12].code, ext_makeup[12].len); /* 2560 */
    span -= 2560;
  }
  if (span >= 64) {
    int m = span / 64; /* 1..40 */
    if (m <= 27) putbits(w, makeup[m - 1].code, makeup[m - 1].len);
    else putbits(w, ext_makeup[m - 28].code, ext_makeup[m - 28].len);
    span -= m * 64;
  }
  putbits(w, term[span].code, term[span].len);
}

/* first index >= bs (< be) whose pixel differs from color, or be */
static int finddiff(const uint8_t *row, int bs, int be, int color) {
  while (bs < be && row[bs] == color) bs++;
  return bs;
}

static int finddiff2(const uint8_t *row, int bs, int be, int color) {
  return bs < be ? finddiff(row, bs, be, color) : be;
}

int ccodecs_ccitt_g4_encode(const uint8_t *pixels, int width, int height,
                            uint8_t **out, size_t *out_len) {
  if (width <= 0 || height <= 0) return -1;
  bitw w = {0};
  w.cap = (size_t)width * (size_t)height / 16 + 1024;
  w.buf = (uint8_t *)malloc(w.cap);
  if (!w.buf) return -2;
  uint8_t *white = (uint8_t *)calloc((size_t)width, 1);
  if (!white) { free(w.buf); return -2; }
  const uint8_t *rp = white;
  const int bits = width;
  for (int y = 0; y < height; y++) {
    const uint8_t *bp = pixels + (size_t)y * (size_t)width;
    int a0 = 0;
    int a1 = bp[0] != 0 ? 0 : finddiff(bp, 0, bits, 0);
    int b1 = rp[0] != 0 ? 0 : finddiff(rp, 0, bits, 0);
    for (;;) {
      int b2 = finddiff2(rp, b1, bits, b1 < bits ? rp[b1] : 0);
      if (b2 >= a1) {
        int d = b1 - a1;
        if (!(-3 <= d && d <= 3)) { /* horizontal mode */
          int a2 = finddiff2(bp, a1, bits, a1 < bits ? bp[a1] : 0);
          putbits(&w, 0x1, 3);
          if (a0 + a1 == 0 || bp[a0] == 0) {
            putspan(&w, a1 - a0, 0);
            putspan(&w, a2 - a1, 1);
          } else {
            putspan(&w, a1 - a0, 1);
            putspan(&w, a2 - a1, 0);
          }
          a0 = a2;
        } else { /* vertical mode */
          putbits(&w, vcodes[d + 3].code, vcodes[d + 3].len);
          a0 = a1;
        }
      } else { /* pass mode */
        putbits(&w, 0x1, 4);
        a0 = b2;
      }
      if (a0 >= bits) break;
      int c = bp[a0];
      a1 = finddiff(bp, a0, bits, c);
      b1 = finddiff(rp, a0, bits, !c);
      b1 = finddiff(rp, b1, bits, c);
    }
    rp = bp;
  }
  /* EOFB */
  putbits(&w, 0x001, 12);
  putbits(&w, 0x001, 12);
  if (w.nbits > 0) putbits(&w, 0, 8 - w.nbits);
  free(white);
  if (w.failed) { free(w.buf); return -2; }
  *out = w.buf;
  *out_len = w.len;
  return 0;
}
