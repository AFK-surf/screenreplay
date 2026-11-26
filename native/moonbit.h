#pragma once
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef uint16_t *moonbit_string_t;
typedef uint8_t *moonbit_bytes_t;

// 8-byte header placed immediately before the returned payload pointer:
//   ((uint32_t *)ptr)[-2] == element count (len)
//   ((uint32_t *)ptr)[-1] == reference count (rc)
#define Moonbit_array_length(p) ((int32_t)(((const uint32_t *)(p))[-2]))

#ifdef __cplusplus
extern "C" {
#endif

moonbit_string_t moonbit_make_string_raw(int32_t len);
moonbit_string_t moonbit_make_string(int32_t len, uint16_t fill);
moonbit_bytes_t moonbit_make_bytes(int32_t len, int fill);
double *pion_mb_make_double_array(int32_t len);
void moonbit_incref(void *p);
void moonbit_decref(void *p);

moonbit_string_t pion_mb_str_from_utf8(const char *utf8, int64_t byte_len);
moonbit_bytes_t pion_mb_bytes_from_raw(const uint8_t *data, int64_t len);

#ifdef __cplusplus
}
#endif
