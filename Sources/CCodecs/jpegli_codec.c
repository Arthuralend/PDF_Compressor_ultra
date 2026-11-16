#include "ccodecs.h"
#include <stdlib.h>

#ifdef CCODECS_HAS_JPEGLI
#include <setjmp.h>
#include <stdio.h>
#include "lib/jpegli/encode.h"

typedef struct {
  struct jpeg_error_mgr pub;
  jmp_buf jump;
} ccodecs_jpeg_error;

static void ccodecs_error_exit(j_common_ptr cinfo) {
  ccodecs_jpeg_error *err = (ccodecs_jpeg_error *)cinfo->err;
  longjmp(err->jump, 1);
}

static void ccodecs_output_message(j_common_ptr cinfo) { (void)cinfo; }

int ccodecs_jpegli_available(void) { return 1; }

int ccodecs_jpegli_encode(const uint8_t *pixels, int width, int height,
                          int components, int quality,
                          uint8_t **out, size_t *out_len) {
  if (components != 1 && components != 3) return -1;
  if (width <= 0 || height <= 0) return -1;
  if (quality < 1) quality = 1;
  if (quality > 100) quality = 100;

  struct jpeg_compress_struct cinfo;
  ccodecs_jpeg_error jerr;
  unsigned char *volatile buffer = NULL;
  unsigned long size = 0;

  cinfo.err = jpegli_std_error(&jerr.pub);
  jerr.pub.error_exit = ccodecs_error_exit;
  jerr.pub.output_message = ccodecs_output_message;
  if (setjmp(jerr.jump)) {
    jpegli_destroy_compress(&cinfo);
    if (buffer) free(buffer);
    return -2;
  }
  jpegli_create_compress(&cinfo);
  jpegli_mem_dest(&cinfo, (unsigned char **)&buffer, &size);
  cinfo.image_width = (JDIMENSION)width;
  cinfo.image_height = (JDIMENSION)height;
  cinfo.input_components = components;
  cinfo.in_color_space = components == 1 ? JCS_GRAYSCALE : JCS_RGB;
  jpegli_set_defaults(&cinfo);
  jpegli_set_quality(&cinfo, quality, TRUE);
  jpegli_start_compress(&cinfo, TRUE);
  const size_t stride = (size_t)width * (size_t)components;
  while (cinfo.next_scanline < cinfo.image_height) {
    JSAMPROW row = (JSAMPROW)(pixels + stride * cinfo.next_scanline);
    jpegli_write_scanlines(&cinfo, &row, 1);
  }
  jpegli_finish_compress(&cinfo);
  jpegli_destroy_compress(&cinfo);
  *out = (uint8_t *)buffer;
  *out_len = (size_t)size;
  return 0;
}

#else

int ccodecs_jpegli_available(void) { return 0; }

int ccodecs_jpegli_encode(const uint8_t *pixels, int width, int height,
                          int components, int quality,
                          uint8_t **out, size_t *out_len) {
  (void)pixels; (void)width; (void)height; (void)components; (void)quality;
  (void)out; (void)out_len;
  return -100;
}

#endif
