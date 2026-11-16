#include "ccodecs.h"
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

void ccodecs_free(void *p) { free(p); }

int ccodecs_deflate(const uint8_t *in, size_t in_len, int level,
                    uint8_t **out, size_t *out_len) {
  z_stream s;
  memset(&s, 0, sizeof(s));
  if (level < 0 || level > 9) level = 9;
  /* windowBits 15, memLevel 9 -> best ratio */
  if (deflateInit2(&s, level, Z_DEFLATED, 15, 9, Z_DEFAULT_STRATEGY) != Z_OK)
    return -1;
  size_t cap = deflateBound(&s, (uLong)in_len) + 64;
  uint8_t *buf = (uint8_t *)malloc(cap);
  if (!buf) { deflateEnd(&s); return -2; }
  s.next_in = (Bytef *)in;
  s.avail_in = (uInt)in_len;
  s.next_out = buf;
  s.avail_out = (uInt)cap;
  int rc = deflate(&s, Z_FINISH);
  if (rc != Z_STREAM_END) { free(buf); deflateEnd(&s); return -3; }
  *out_len = s.total_out;
  *out = buf;
  deflateEnd(&s);
  return 0;
}

static int inflate_with(const uint8_t *in, size_t in_len, int window_bits,
                        uint8_t **out, size_t *out_len) {
  z_stream s;
  memset(&s, 0, sizeof(s));
  if (inflateInit2(&s, window_bits) != Z_OK) return -1;
  size_t cap = in_len * 4 + 1024;
  uint8_t *buf = (uint8_t *)malloc(cap);
  if (!buf) { inflateEnd(&s); return -2; }
  s.next_in = (Bytef *)in;
  s.avail_in = (uInt)in_len;
  int rc = Z_OK;
  for (;;) {
    if (s.total_out >= cap) {
      size_t ncap = cap * 2;
      uint8_t *nb = (uint8_t *)realloc(buf, ncap);
      if (!nb) { free(buf); inflateEnd(&s); return -2; }
      buf = nb; cap = ncap;
    }
    s.next_out = buf + s.total_out;
    s.avail_out = (uInt)(cap - s.total_out);
    rc = inflate(&s, Z_NO_FLUSH);
    if (rc == Z_STREAM_END) break;
    if (rc == Z_BUF_ERROR && s.avail_in == 0) break; /* truncated */
    if (rc != Z_OK && rc != Z_BUF_ERROR) break;     /* corrupt */
  }
  *out_len = s.total_out;
  *out = buf;
  inflateEnd(&s);
  if (rc == Z_STREAM_END) return 0;
  return s.total_out > 0 ? 1 : -3;
}

int ccodecs_inflate(const uint8_t *in, size_t in_len,
                    uint8_t **out, size_t *out_len) {
  int rc = inflate_with(in, in_len, 15, out, out_len);
  if (rc >= 0) return rc;
  /* Some broken producers write raw deflate without the zlib header. */
  rc = inflate_with(in, in_len, -15, out, out_len);
  return rc;
}
