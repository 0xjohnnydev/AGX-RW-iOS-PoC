#ifndef agx_h
#define agx_h

#include <stdbool.h>
#include <stdint.h>

typedef enum {
    AGX_TEST_SHADOW,
    AGX_TEST_ACQUIRE_ONLY,
    AGX_TEST_READ_CONTROL,
    AGX_TEST_READ,
    AGX_TEST_WRITE_CONTROL,
    AGX_TEST_WRITE_PANIC,
} agx_test_mode_t;

bool agx_test_mode_from_argument(const char* argument, agx_test_mode_t* mode);
const char* agx_test_mode_name(agx_test_mode_t mode);
bool agx_test_argument_valid(agx_test_mode_t mode, uint64_t argument);
bool agx_buffer_rw_self_test(void);
bool agx_shadow_test(uint64_t self_pmap);
bool agx_run_test(agx_test_mode_t mode, uint64_t argument);

#endif /* agx_h */
