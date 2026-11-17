/* JBIG2 (ITU T.88) lossless encoder: one immediate generic region, template 0,
   TPGDON, MQ arithmetic coder. Output is the embedded stream format used by
   PDF /JBIG2Decode (page information + generic region segments). */
#include "ccodecs.h"
#include <stdlib.h>
#include <string.h>

static const struct { unsigned short qe; unsigned char nmps, nlps, sw; } QE[47] = {
  {0x5601,1,1,1},{0x3401,2,6,0},{0x1801,3,9,0},{0x0AC1,4,12,0},{0x0521,5,29,0},
  {0x0221,38,33,0},{0x5601,7,6,1},{0x5401,8,14,0},{0x4801,9,14,0},{0x3801,10,14,0},
  {0x3001,11,17,0},{0x2401,12,18,0},{0x1C01,13,20,0},{0x1601,29,21,0},{0x5601,15,14,1},
  {0x5401,16,14,0},{0x5101,17,15,0},{0x4801,18,16,0},{0x3801,19,17,0},{0x3401,20,18,0},
  {0x3001,21,19,0},{0x2801,22,19,0},{0x2401,23,20,0},{0x2201,24,21,0},{0x1C01,25,22,0},
  {0x1801,26,23,0},{0x1601,27,24,0},{0x1401,28,25,0},{0x1201,29,26,0},{0x1101,30,27,0},
  {0x0AC1,31,28,0},{0x09C1,32,29,0},{0x08A1,33,30,0},{0x0521,34,31,0},{0x0441,35,32,0},
  {0x02A1,36,33,0},{0x0221,37,34,0},{0x0141,38,35,0},{0x0111,39,36,0},{0x0085,40,37,0},
  {0x0049,41,38,0},{0x0025,42,39,0},{0x0015,43,40,0},{0x0009,44,41,0},{0x0005,45,42,0},
  {0x0001,45,43,0},{0x5601,46,46,0}};

typedef struct {
  uint32_t A, C;
  int CT;
  uint8_t *buf;   /* buf[0] is the virtual byte preceding the code stream */
  size_t bp, cap;
  int failed;
  uint8_t I[65536], MPS[65536];
} mq;

static void mq_grow(mq *e) {
  if (e->bp + 2 < e->cap) return;
  size_t ncap = e->cap * 2 + 4096;
  uint8_t *nb = (uint8_t *)realloc(e->buf, ncap);
  if (!nb) { e->failed = 1; return; }
  e->buf = nb; e->cap = ncap;
}

static void byteout(mq *e) {
  mq_grow(e);
  if (e->failed) return;
  if (e->buf[e->bp] == 0xFF) {
    e->bp++; e->buf[e->bp] = (uint8_t)(e->C >> 20); e->C &= 0xFFFFF; e->CT = 7;
  } else if (e->C < 0x8000000) {
    e->bp++; e->buf[e->bp] = (uint8_t)(e->C >> 19); e->C &= 0x7FFFF; e->CT = 8;
  } else {
    e->buf[e->bp]++;
    if (e->buf[e->bp] == 0xFF) {
      e->C &= 0x7FFFFFF;
      e->bp++; e->buf[e->bp] = (uint8_t)(e->C >> 20); e->C &= 0xFFFFF; e->CT = 7;
    } else {
      e->bp++; e->buf[e->bp] = (uint8_t)(e->C >> 19); e->C &= 0x7FFFF; e->CT = 8;
    }
  }
}

static void renorm(mq *e) {
  do {
    e->A <<= 1; e->C <<= 1; e->CT--;
    if (e->CT == 0) byteout(e);
  } while ((e->A & 0x8000) == 0);
}

static void encode_bit(mq *e, int cx, int d) {
  int i = e->I[cx];
  uint32_t qe = QE[i].qe;
  if (d == e->MPS[cx]) {
    e->A -= qe;
    if ((e->A & 0x8000) == 0) {
      if (e->A < qe) e->A = qe; else e->C += qe;
      e->I[cx] = QE[i].nmps;
      renorm(e);
    } else {
      e->C += qe;
    }
  } else {
    e->A -= qe;
    if (e->A < qe) e->C += qe; else e->A = qe;
    if (QE[i].sw) e->MPS[cx] = (uint8_t)(1 - e->MPS[cx]);
    e->I[cx] = QE[i].nlps;
    renorm(e);
  }
}

static void flush(mq *e) {
  uint32_t temp = e->C + e->A;
  e->C |= 0xFFFF;
  if (e->C >= temp) e->C -= 0x8000;
  e->C <<= e->CT; byteout(e);
  e->C <<= e->CT; byteout(e);
  mq_grow(e);
  if (e->buf[e->bp] != 0xFF) { e->bp++; e->buf[e->bp] = 0xFF; }
  e->bp++; e->buf[e->bp] = 0xAC;
}

static void put32(uint8_t *p, uint32_t v) {
  p[0] = (uint8_t)(v >> 24); p[1] = (uint8_t)(v >> 16); p[2] = (uint8_t)(v >> 8); p[3] = (uint8_t)v;
}

static inline int px(const uint8_t *img, int w, int h, int x, int y) {
  return (x >= 0 && x < w && y >= 0 && y < h) ? img[(size_t)y * w + x] : 0;
}

int ccodecs_jbig2_generic_encode(const uint8_t *pixels, int width, int height,
                                 uint8_t **out, size_t *out_len) {
  if (width <= 0 || height <= 0) return -1;
  mq *e = (mq *)calloc(1, sizeof(mq));
  if (!e) return -2;
  e->cap = (size_t)width * height / 32 + 4096;
  e->buf = (uint8_t *)malloc(e->cap);
  if (!e->buf) { free(e); return -2; }
  e->buf[0] = 0; e->bp = 0;
  e->A = 0x8000; e->C = 0; e->CT = 12;

  const int w = width, h = height;
  int ltp = 0;
  for (int y = 0; y < h; y++) {
    const uint8_t *row = pixels + (size_t)y * w;
    int same = y > 0 ? memcmp(row, row - w, (size_t)w) == 0
                     : (memchr(row, 1, (size_t)w) == NULL);
    encode_bit(e, 0x9B25, same ^ ltp);
    ltp = same;
    if (ltp) continue;
    for (int x = 0; x < w; x++) {
      int cx = px(pixels, w, h, x - 1, y)
             | px(pixels, w, h, x - 2, y) << 1
             | px(pixels, w, h, x - 3, y) << 2
             | px(pixels, w, h, x - 4, y) << 3
             | px(pixels, w, h, x + 3, y - 1) << 4
             | px(pixels, w, h, x + 2, y - 1) << 5
             | px(pixels, w, h, x + 1, y - 1) << 6
             | px(pixels, w, h, x, y - 1) << 7
             | px(pixels, w, h, x - 1, y - 1) << 8
             | px(pixels, w, h, x - 2, y - 1) << 9
             | px(pixels, w, h, x - 3, y - 1) << 10
             | px(pixels, w, h, x + 2, y - 2) << 11
             | px(pixels, w, h, x + 1, y - 2) << 12
             | px(pixels, w, h, x, y - 2) << 13
             | px(pixels, w, h, x - 1, y - 2) << 14
             | px(pixels, w, h, x - 2, y - 2) << 15;
      encode_bit(e, cx, row[x]);
    }
    if (e->failed) break;
  }
  flush(e);
  if (e->failed) { free(e->buf); free(e); return -2; }
  const size_t code_len = e->bp; /* bytes buf[1..bp] */

  /* segments */
  const size_t page_seg = 11 + 19;
  const size_t gen_data = 17 + 1 + 8 + code_len;
  const size_t total = page_seg + 11 + gen_data;
  uint8_t *o = (uint8_t *)malloc(total);
  if (!o) { free(e->buf); free(e); return -2; }
  uint8_t *p = o;
  /* page information segment (type 48) */
  put32(p, 0); p[4] = 48; p[5] = 0; p[6] = 1; put32(p + 7, 19); p += 11;
  put32(p, (uint32_t)w); put32(p + 4, (uint32_t)h); put32(p + 8, 0); put32(p + 12, 0);
  p[16] = 0x01; /* eventually lossless */
  p[17] = 0; p[18] = 0; /* no striping */
  p += 19;
  /* immediate generic region segment (type 38) */
  put32(p, 1); p[4] = 38; p[5] = 0; p[6] = 1; put32(p + 7, (uint32_t)gen_data); p += 11;
  put32(p, (uint32_t)w); put32(p + 4, (uint32_t)h); put32(p + 8, 0); put32(p + 12, 0);
  p[16] = 0; /* combination operator OR */
  p += 17;
  *p++ = 0x08; /* MMR 0, template 0, TPGDON 1 */
  const int8_t at[8] = {3, -1, -3, -1, 2, -2, -2, -2};
  memcpy(p, at, 8); p += 8;
  memcpy(p, e->buf + 1, code_len); p += code_len;
  free(e->buf);
  free(e);
  *out = o;
  *out_len = total;
  return 0;
}
