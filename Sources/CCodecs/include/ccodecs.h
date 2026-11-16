#ifndef CCODECS_H
#define CCODECS_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- zlib ---------------------------------------------------------------- */

/* Compresses `in` with zlib (FlateDecode-compatible) at maximum level.
   On success returns 0 and *out (malloc'd, caller frees with ccodecs_free). */
int ccodecs_deflate(const uint8_t *in, size_t in_len, int level,
                    uint8_t **out, size_t *out_len);

/* Inflates zlib (or raw deflate as a fallback) data. Corrupted or truncated
   input yields whatever could be decoded; returns 0 on full success,
   1 on partial success, negative on hard failure. */
int ccodecs_inflate(const uint8_t *in, size_t in_len,
                    uint8_t **out, size_t *out_len);

/* ---- JPEGli -------------------------------------------------------------- */

/* 1 when the library was built with the jpegli encoder linked in. */
int ccodecs_jpegli_available(void);

/* Encodes 8-bit interleaved pixels (components = 1 gray or 3 RGB) with jpegli.
   quality: 1..100. Returns 0 on success; *out must be freed with ccodecs_free. */
int ccodecs_jpegli_encode(const uint8_t *pixels, int width, int height,
                          int components, int quality,
                          uint8_t **out, size_t *out_len);

void ccodecs_free(void *p);

#ifdef __cplusplus
}
#endif

#endif
