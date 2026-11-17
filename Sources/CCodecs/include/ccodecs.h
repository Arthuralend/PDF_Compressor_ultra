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

/* Encodes 8-bit interleaved pixels with jpegli (components: 1 gray, 3 RGB,
   4 CMYK). For CMYK, adobe_marker selects whether an Adobe APP14 marker is
   written (keep it the same as in the source JPEG so readers interpret the
   samples identically). quality: 1..100. Returns 0 on success; *out must be
   freed with ccodecs_free. */
int ccodecs_jpegli_encode(const uint8_t *pixels, int width, int height,
                          int components, int quality, int adobe_marker,
                          uint8_t **out, size_t *out_len);

/* Decodes a JPEG into 8-bit interleaved samples exactly as stored (no CMYK
   inversion). color_transform: -1 = auto, 0/1 = PDF /ColorTransform value.
   Returns 0 on success; *out must be freed with ccodecs_free. */
int ccodecs_jpegli_decode(const uint8_t *data, size_t len, int color_transform,
                          uint8_t **out, int *width, int *height,
                          int *components, int *adobe_marker);

/* ---- CCITT Group 4 ------------------------------------------------------ */

/* Encodes a bilevel image (one byte per pixel, 1 = black, 0 = white) with
   CCITT G4 (T.6), EOFB terminated. PDF: /CCITTFaxDecode with /K -1
   /Columns width /Rows height (BlackIs1 false). */
int ccodecs_ccitt_g4_encode(const uint8_t *pixels, int width, int height,
                            uint8_t **out, size_t *out_len);

void ccodecs_free(void *p);

#ifdef __cplusplus
}
#endif

#endif
