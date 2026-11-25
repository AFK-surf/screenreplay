#include "moonbit.h"
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>

void pion_rp_stdout(const uint8_t *s, int64_t sl) {
  if (s && sl > 0) fwrite(s, 1, (size_t)sl, stdout);
  fputc('\n', stdout);
  fflush(stdout);
}

extern moonbit_bytes_t pion_mb_bytes_from_raw(const uint8_t *ptr, int64_t len);

static inline moonbit_bytes_t mb_from(const uint8_t *p, int64_t n) {
  return pion_mb_bytes_from_raw(p, n);
}

extern int32_t rp_copy_text(moonbit_bytes_t text);
extern moonbit_bytes_t rp_list(moonbit_bytes_t dir);
extern double rp_size(moonbit_bytes_t path);
extern moonbit_bytes_t rp_read(moonbit_bytes_t path, double offset, int32_t length);
extern int32_t rp_write(moonbit_bytes_t path, moonbit_bytes_t data);
extern int32_t rp_mkdirs(moonbit_bytes_t path);
extern void rp_reveal(moonbit_bytes_t path);
extern moonbit_bytes_t rp_gif_info(moonbit_bytes_t path);
extern moonbit_bytes_t rp_gif_frame(moonbit_bytes_t path, int32_t k, int32_t max_w);
extern void rp_gif_drop(moonbit_bytes_t path);
extern void rp_idx_dir(moonbit_bytes_t dir);
extern void rp_idx_add(moonbit_bytes_t path, double dur);
extern void rp_idx_add_clip(moonbit_bytes_t path, double dur);
extern void rp_idx_drop(moonbit_bytes_t path);
extern void rp_idx_prefer(moonbit_bytes_t path);
extern double rp_idx_at(moonbit_bytes_t path, double ms);
extern moonbit_bytes_t rp_idx_jpeg(moonbit_bytes_t path, double ms);
extern int32_t rp_launch(moonbit_bytes_t path);
extern int32_t rp_recycle(moonbit_bytes_t path);
extern moonbit_bytes_t rp_list_clips(moonbit_bytes_t dir);
extern int32_t rp_take_request(moonbit_bytes_t path);
extern moonbit_bytes_t rp_clip_thumb(moonbit_bytes_t path, moonbit_bytes_t identity, double ms);
extern double rp_modified(moonbit_bytes_t path);
extern double rp_duration(moonbit_bytes_t path);
extern moonbit_bytes_t rp_play_read(moonbit_bytes_t path, double offset, int32_t length);
extern void rp_play_warm(moonbit_bytes_t path);
extern int32_t rp_aac_open(moonbit_bytes_t asc, int32_t rate, int32_t channels);
extern moonbit_bytes_t rp_aac_decode(int32_t h, moonbit_bytes_t data);
extern moonbit_bytes_t rp_ts_feed(int32_t h, moonbit_bytes_t data, int32_t from, int32_t flush);
extern int32_t rp_frame_copy(moonbit_bytes_t path, double ms);
extern int32_t rp_export_start(moonbit_bytes_t plan, moonbit_bytes_t output, int32_t width, int32_t height, int32_t fps, int32_t bitrate, int32_t codec, moonbit_bytes_t crops, double scale);
extern void rp_gif_estimate_start(moonbit_bytes_t plan, int32_t width, int32_t height, int32_t fps, moonbit_bytes_t crops, double scale);
extern int32_t rp_concat_start(moonbit_bytes_t plan, moonbit_bytes_t output);
extern int32_t rp_copy_file(moonbit_bytes_t path);
extern int32_t rp_rename(moonbit_bytes_t from, moonbit_bytes_t to);
extern void rp_delete(moonbit_bytes_t path);
extern moonbit_bytes_t rp_crop_thumb(moonbit_bytes_t path, moonbit_bytes_t identity, double ms, int32_t x, int32_t y, int32_t w, int32_t h);
extern double rp_dir_size(moonbit_bytes_t path);
extern int32_t rp_can_write(moonbit_bytes_t dir);
extern double rp_disk_free(moonbit_bytes_t dir);
extern int32_t rp_append(moonbit_bytes_t path, moonbit_bytes_t data);

int32_t pion_rp_copy_text(const uint8_t *text, int64_t text_len) {
  moonbit_bytes_t b_text = mb_from(text, text_len);
  int32_t out = rp_copy_text(b_text);
  moonbit_decref(b_text);
  return out;
}

void * pion_rp_list(const uint8_t *dir, int64_t dir_len) {
  moonbit_bytes_t b_dir = mb_from(dir, dir_len);
  moonbit_bytes_t out = rp_list(b_dir);
  moonbit_decref(b_dir);
  return out;
}

double pion_rp_size(const uint8_t *path, int64_t path_len) {
  moonbit_bytes_t b_path = mb_from(path, path_len);
  double out = rp_size(b_path);
  moonbit_decref(b_path);
  return out;
}

void * pion_rp_read(const uint8_t *path, int64_t path_len, double offset, int32_t length) {
  moonbit_bytes_t b_path = mb_from(path, path_len);
  moonbit_bytes_t out = rp_read(b_path, offset, length);
  moonbit_decref(b_path);
  return out;
}

int32_t pion_rp_write(const uint8_t *path, int64_t path_len, const uint8_t *data, int64_t data_len) {
  moonbit_bytes_t b_path = mb_from(path, path_len);
  moonbit_bytes_t b_data = mb_from(data, data_len);
  int32_t out = rp_write(b_path, b_data);
  moonbit_decref(b_path);
  moonbit_decref(b_data);
  return out;
}

int32_t pion_rp_mkdirs(const uint8_t *path, int64_t path_len) {
  moonbit_bytes_t b_path = mb_from(path, path_len);
  int32_t out = rp_mkdirs(b_path);
  moonbit_decref(b_path);
  return out;
}

void pion_rp_reveal(const uint8_t *path, int64_t path_len) {
  moonbit_bytes_t b_path = mb_from(path, path_len);
  rp_reveal(b_path);
  moonbit_decref(b_path);
}

void * pion_rp_gif_info(const uint8_t *path, int64_t path_len) {
  moonbit_bytes_t b_path = mb_from(path, path_len);
  moonbit_bytes_t out = rp_gif_info(b_path);
  moonbit_decref(b_path);
  return out;
}

void * pion_rp_gif_frame(const uint8_t *path, int64_t path_len, int32_t k, int32_t max_w) {
  moonbit_bytes_t b_path = mb_from(path, path_len);
  moonbit_bytes_t out = rp_gif_frame(b_path, k, max_w);
  moonbit_decref(b_path);
  return out;
}

void pion_rp_gif_drop(const uint8_t *path, int64_t path_len) {
  moonbit_bytes_t b_path = mb_from(path, path_len);
  rp_gif_drop(b_path);
  moonbit_decref(b_path);
}

void pion_rp_idx_dir(const uint8_t *dir, int64_t dir_len) {
  moonbit_bytes_t b_dir = mb_from(dir, dir_len);
  rp_idx_dir(b_dir);
  moonbit_decref(b_dir);
}

void pion_rp_idx_add(const uint8_t *path, int64_t path_len, double dur) {
  moonbit_bytes_t b_path = mb_from(path, path_len);
  rp_idx_add(b_path, dur);
  moonbit_decref(b_path);
}

void pion_rp_idx_add_clip(const uint8_t *path, int64_t path_len, double dur) {
  moonbit_bytes_t b_path = mb_from(path, path_len);
  rp_idx_add_clip(b_path, dur);
  moonbit_decref(b_path);
}

void pion_rp_idx_drop(const uint8_t *path, int64_t path_len) {
  moonbit_bytes_t b_path = mb_from(path, path_len);
  rp_idx_drop(b_path);
  moonbit_decref(b_path);
}

void pion_rp_idx_prefer(const uint8_t *path, int64_t path_len) {
  moonbit_bytes_t b_path = mb_from(path, path_len);
  rp_idx_prefer(b_path);
  moonbit_decref(b_path);
}

double pion_rp_idx_at(const uint8_t *path, int64_t path_len, double ms) {
  moonbit_bytes_t b_path = mb_from(path, path_len);
  double out = rp_idx_at(b_path, ms);
  moonbit_decref(b_path);
  return out;
}

void * pion_rp_idx_jpeg(const uint8_t *path, int64_t path_len, double ms) {
  moonbit_bytes_t b_path = mb_from(path, path_len);
  moonbit_bytes_t out = rp_idx_jpeg(b_path, ms);
  moonbit_decref(b_path);
  return out;
}

int32_t pion_rp_launch(const uint8_t *path, int64_t path_len) {
  moonbit_bytes_t b_path = mb_from(path, path_len);
  int32_t out = rp_launch(b_path);
  moonbit_decref(b_path);
  return out;
}

int32_t pion_rp_recycle(const uint8_t *path, int64_t path_len) {
  moonbit_bytes_t b_path = mb_from(path, path_len);
  int32_t out = rp_recycle(b_path);
  moonbit_decref(b_path);
  return out;
}

void * pion_rp_list_clips(const uint8_t *dir, int64_t dir_len) {
  moonbit_bytes_t b_dir = mb_from(dir, dir_len);
  moonbit_bytes_t out = rp_list_clips(b_dir);
  moonbit_decref(b_dir);
  return out;
}

int32_t pion_rp_take_request(const uint8_t *path, int64_t path_len) {
  moonbit_bytes_t b_path = mb_from(path, path_len);
  int32_t out = rp_take_request(b_path);
  moonbit_decref(b_path);
  return out;
}

void * pion_rp_clip_thumb(const uint8_t *path, int64_t path_len, const uint8_t *identity, int64_t identity_len, double ms) {
  moonbit_bytes_t b_path = mb_from(path, path_len);
  moonbit_bytes_t b_identity = mb_from(identity, identity_len);
  moonbit_bytes_t out = rp_clip_thumb(b_path, b_identity, ms);
  moonbit_decref(b_path);
  moonbit_decref(b_identity);
  return out;
}

double pion_rp_modified(const uint8_t *path, int64_t path_len) {
  moonbit_bytes_t b_path = mb_from(path, path_len);
  double out = rp_modified(b_path);
  moonbit_decref(b_path);
  return out;
}

double pion_rp_duration(const uint8_t *path, int64_t path_len) {
  moonbit_bytes_t b_path = mb_from(path, path_len);
  double out = rp_duration(b_path);
  moonbit_decref(b_path);
  return out;
}

void * pion_rp_play_read(const uint8_t *path, int64_t path_len, double offset, int32_t length) {
  moonbit_bytes_t b_path = mb_from(path, path_len);
  moonbit_bytes_t out = rp_play_read(b_path, offset, length);
  moonbit_decref(b_path);
  return out;
}

void pion_rp_play_warm(const uint8_t *path, int64_t path_len) {
  moonbit_bytes_t b_path = mb_from(path, path_len);
  rp_play_warm(b_path);
  moonbit_decref(b_path);
}

int32_t pion_rp_aac_open(const uint8_t *asc, int64_t asc_len, int32_t rate, int32_t channels) {
  moonbit_bytes_t b_asc = mb_from(asc, asc_len);
  int32_t out = rp_aac_open(b_asc, rate, channels);
  moonbit_decref(b_asc);
  return out;
}

void * pion_rp_aac_decode(int32_t h, const uint8_t *data, int64_t data_len) {
  moonbit_bytes_t b_data = mb_from(data, data_len);
  moonbit_bytes_t out = rp_aac_decode(h, b_data);
  moonbit_decref(b_data);
  return out;
}

void * pion_rp_ts_feed(int32_t h, const uint8_t *data, int64_t data_len, int32_t from, int32_t flush) {
  moonbit_bytes_t b_data = mb_from(data, data_len);
  moonbit_bytes_t out = rp_ts_feed(h, b_data, from, flush);
  moonbit_decref(b_data);
  return out;
}

int32_t pion_rp_frame_copy(const uint8_t *path, int64_t path_len, double ms) {
  moonbit_bytes_t b_path = mb_from(path, path_len);
  int32_t out = rp_frame_copy(b_path, ms);
  moonbit_decref(b_path);
  return out;
}

int32_t pion_rp_export_start(const uint8_t *plan, int64_t plan_len, const uint8_t *output, int64_t output_len, int32_t width, int32_t height, int32_t fps, int32_t bitrate, int32_t codec, const uint8_t *crops, int64_t crops_len, double scale) {
  moonbit_bytes_t b_plan = mb_from(plan, plan_len);
  moonbit_bytes_t b_output = mb_from(output, output_len);
  moonbit_bytes_t b_crops = mb_from(crops, crops_len);
  int32_t out = rp_export_start(b_plan, b_output, width, height, fps, bitrate, codec, b_crops, scale);
  moonbit_decref(b_plan);
  moonbit_decref(b_output);
  moonbit_decref(b_crops);
  return out;
}

void pion_rp_gif_estimate_start(const uint8_t *plan, int64_t plan_len, int32_t width, int32_t height, int32_t fps, const uint8_t *crops, int64_t crops_len, double scale) {
  moonbit_bytes_t b_plan = mb_from(plan, plan_len);
  moonbit_bytes_t b_crops = mb_from(crops, crops_len);
  rp_gif_estimate_start(b_plan, width, height, fps, b_crops, scale);
  moonbit_decref(b_plan);
  moonbit_decref(b_crops);
}

int32_t pion_rp_concat_start(const uint8_t *plan, int64_t plan_len, const uint8_t *output, int64_t output_len) {
  moonbit_bytes_t b_plan = mb_from(plan, plan_len);
  moonbit_bytes_t b_output = mb_from(output, output_len);
  int32_t out = rp_concat_start(b_plan, b_output);
  moonbit_decref(b_plan);
  moonbit_decref(b_output);
  return out;
}

int32_t pion_rp_copy_file(const uint8_t *path, int64_t path_len) {
  moonbit_bytes_t b_path = mb_from(path, path_len);
  int32_t out = rp_copy_file(b_path);
  moonbit_decref(b_path);
  return out;
}

int32_t pion_rp_rename(const uint8_t *from, int64_t from_len, const uint8_t *to, int64_t to_len) {
  moonbit_bytes_t b_from = mb_from(from, from_len);
  moonbit_bytes_t b_to = mb_from(to, to_len);
  int32_t out = rp_rename(b_from, b_to);
  moonbit_decref(b_from);
  moonbit_decref(b_to);
  return out;
}

void pion_rp_delete(const uint8_t *path, int64_t path_len) {
  moonbit_bytes_t b_path = mb_from(path, path_len);
  rp_delete(b_path);
  moonbit_decref(b_path);
}

void * pion_rp_crop_thumb(const uint8_t *path, int64_t path_len, const uint8_t *identity, int64_t identity_len, double ms, int32_t x, int32_t y, int32_t w, int32_t h) {
  moonbit_bytes_t b_path = mb_from(path, path_len);
  moonbit_bytes_t b_identity = mb_from(identity, identity_len);
  moonbit_bytes_t out = rp_crop_thumb(b_path, b_identity, ms, x, y, w, h);
  moonbit_decref(b_path);
  moonbit_decref(b_identity);
  return out;
}

double pion_rp_dir_size(const uint8_t *path, int64_t path_len) {
  moonbit_bytes_t b_path = mb_from(path, path_len);
  double out = rp_dir_size(b_path);
  moonbit_decref(b_path);
  return out;
}

int32_t pion_rp_can_write(const uint8_t *dir, int64_t dir_len) {
  moonbit_bytes_t b_dir = mb_from(dir, dir_len);
  int32_t out = rp_can_write(b_dir);
  moonbit_decref(b_dir);
  return out;
}

double pion_rp_disk_free(const uint8_t *dir, int64_t dir_len) {
  moonbit_bytes_t b_dir = mb_from(dir, dir_len);
  double out = rp_disk_free(b_dir);
  moonbit_decref(b_dir);
  return out;
}

int32_t pion_rp_append(const uint8_t *path, int64_t path_len, const uint8_t *data, int64_t data_len) {
  moonbit_bytes_t b_path = mb_from(path, path_len);
  moonbit_bytes_t b_data = mb_from(data, data_len);
  int32_t out = rp_append(b_path, b_data);
  moonbit_decref(b_path);
  moonbit_decref(b_data);
  return out;
}
