#ifndef krw_h
#define krw_h

#include "common.h"

#define EARLY_KRW_LENGTH 0x20  // 32

bool krw_is_kernel_address(uint64_t address);
bool early_kread_checked(uint64_t where, void* read_buf, size_t size);
bool early_kread64_checked(uint64_t where, uint64_t* value);
bool early_kwrite64_checked(uint64_t where, uint64_t what);
bool krw_park_transport(void);

#endif /* krw_h */
