#include "ccodecs.h"
#include <stdlib.h>

#ifdef CCODECS_HAS_JPEGLI
#include <setjmp.h>
#include <stdio.h>
#include "lib/jpegli/decode.h"
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
                          int components, int quality, int adobe_marker,
                          uint8_t **out, size_t *out_len) {
  if (components != 1 && components != 3 && components != 4) return -1;
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
  cinfo.in_color_space =
      components == 1 ? JCS_GRAYSCALE : (components == 3 ? JCS_RGB : JCS_CMYK);
  jpegli_set_defaults(&cinfo);
  if (components == 4) {
    jpegli_set_colorspace(&cinfo, JCS_CMYK);
    cinfo.write_Adobe_marker = adobe_marker ? TRUE : FALSE;
    cinfo.write_JFIF_header = FALSE;
  }
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

int ccodecs_jpegli_decode(const uint8_t *data, size_t len, int color_transform,
                          uint8_t **out, int *width, int *height,
                          int *components, int *adobe_marker) {
  struct jpeg_decompress_struct cinfo;
  ccodecs_jpeg_error jerr;
  uint8_t *volatile pixels = NULL;

  cinfo.err = jpegli_std_error(&jerr.pub);
  jerr.pub.error_exit = ccodecs_error_exit;
  jerr.pub.output_message = ccodecs_output_message;
  if (setjmp(jerr.jump)) {
    jpegli_destroy_decompress(&cinfo);
    if (pixels) free(pixels);
    return -2;
  }
  jpegli_create_decompress(&cinfo);
  jpegli_mem_src(&cinfo, data, (unsigned long)len);
  if (jpegli_read_header(&cinfo, TRUE) != JPEG_HEADER_OK) {
    jpegli_destroy_decompress(&cinfo);
    return -3;
  }
  int nc = cinfo.num_components;
  if (nc == 3) {
    if (color_transform == 0) cinfo.jpeg_color_space = JCS_RGB;
    if (color_transform == 1) cinfo.jpeg_color_space = JCS_YCbCr;
    cinfo.out_color_space = JCS_RGB;
  } else if (nc == 4) {
    if (color_transform == 0) cinfo.jpeg_color_space = JCS_CMYK;
    if (color_transform == 1) cinfo.jpeg_color_space = JCS_YCCK;
    cinfo.out_color_space = JCS_CMYK;
  } else if (nc == 1) {
    cinfo.out_color_space = JCS_GRAYSCALE;
  } else {
    jpegli_destroy_decompress(&cinfo);
    return -4;
  }
  jpegli_start_decompress(&cinfo);
  const int w = (int)cinfo.output_width, h = (int)cinfo.output_height;
  const int c = cinfo.output_components;
  const size_t stride = (size_t)w * (size_t)c;
  pixels = (uint8_t *)malloc(stride * (size_t)h);
  if (!pixels) {
    jpegli_destroy_decompress(&cinfo);
    return -5;
  }
  while (cinfo.output_scanline < cinfo.output_height) {
    JSAMPROW row = (JSAMPROW)(pixels + stride * cinfo.output_scanline);
    if (jpegli_read_scanlines(&cinfo, &row, 1) != 1) break;
  }
  *adobe_marker = cinfo.saw_Adobe_marker ? 1 : 0;
  jpegli_finish_decompress(&cinfo);
  jpegli_destroy_decompress(&cinfo);
  *out = pixels;
  *width = w;
  *height = h;
  *components = c;
  return 0;
}

#else

int ccodecs_jpegli_available(void) { return 0; }

int ccodecs_jpegli_encode(const uint8_t *pixels, int width, int height,
                          int components, int quality, int adobe_marker,
                          uint8_t **out, size_t *out_len) {
  (void)pixels; (void)width; (void)height; (void)components; (void)quality;
  (void)adobe_marker; (void)out; (void)out_len;
  return -100;
}

int ccodecs_jpegli_decode(const uint8_t *data, size_t len, int color_transform,
                          uint8_t **out, int *width, int *height,
                          int *components, int *adobe_marker) {
  (void)data; (void)len; (void)color_transform; (void)out; (void)width;
  (void)height; (void)components; (void)adobe_marker;
  return -100;
}

#endif
