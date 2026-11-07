#include "utils.h"

#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <sys/utsname.h>
#include <unistd.h>

static poc_log_handler_t g_log_handler;
static FILE* g_log_file;
static bool g_log_file_opened;

static void open_log_file(void) {
    if (g_log_file_opened) return;
    g_log_file_opened = true;

    char directory[PATH_MAX] = {};
    if (confstr(_CS_DARWIN_USER_TEMP_DIR, directory, sizeof(directory)) == 0) return;
    char path[PATH_MAX] = {};
    if (snprintf(path, sizeof(path), "%s/clearsword.log", directory) >= (int)sizeof(path)) return;
    g_log_file = fopen(path, "w");
    if (g_log_file) setvbuf(g_log_file, NULL, _IOLBF, 0);
}

void poc_set_log_handler(poc_log_handler_t handler) {
    g_log_handler = handler;
}

void poc_log(const char* prefix, const char* format, ...) {
    char message[1024];
    va_list args;
    va_start(args, format);
    vsnprintf(message, sizeof(message), format, args);
    va_end(args);

    open_log_file();
    fprintf(stderr, "%s%s\n", prefix, message);
    fflush(stderr);
    if (g_log_file) fprintf(g_log_file, "%s%s\n", prefix, message);
    if (g_log_handler) {
        char line[1100];
        snprintf(line, sizeof(line), "%s%s", prefix, message);
        g_log_handler(line);
    }
}

void* reverse_memmem(const void* haystack, size_t haystack_len, const void* needle, size_t needle_len) {
    if (needle_len == 0) return (void*)haystack;

    if (haystack_len < needle_len) return NULL;

    const char* h = (const char*)haystack;
    const char* n = (const char*)needle;

    for (size_t i = haystack_len - needle_len + 1; i-- > 0;) {
        if (memcmp(h + i, n, needle_len) == 0) {
            return (void*)(h + i);
        }
    }

    return NULL;
}

int offsets_init(void) {
    char version[32] = {};
    char build[32] = {};
    size_t version_len = sizeof(version);
    size_t build_len = sizeof(build);
    if (sysctlbyname("kern.osproductversion", version, &version_len, NULL, 0) != 0 || sysctlbyname("kern.osversion", build, &build_len, NULL, 0) != 0) {
        LOG_ERR("failed to read OS version");
        return -1;
    }

    const char* machine = get_device_machine();
    LOG("target: %s, iOS %s (%s)", machine, version, build);
    if (strcmp(machine, TARGET_DEVICE) != 0 || strcmp(version, TARGET_VERSION) != 0 || strcmp(build, TARGET_BUILD) != 0) {
        LOG_ERR("supported target is %s on iOS %s (%s)", TARGET_DEVICE, TARGET_VERSION, TARGET_BUILD);
        return -1;
    }

    // Fixed offsets for iPhone17,2 on 18.6.2 (22G100).
    g_offsets.inpcb_inp_list_le_next = 0x20;
    g_offsets.inpcb_inp_pcbinfo = 0x38;
    g_offsets.inpcb_inp_socket = 0x40;
    g_offsets.inpcb_icmp6filt = 0x148;
    g_offsets.socket_so_count = 0x254;
    g_offsets.socket_so_background_thread = 0x2b0;
    g_offsets.thread_t_ro = 0x3f0;
    g_offsets.thread_ro_proc = 0x18;
    g_offsets.proc_p_ro = 0x18;
    g_offsets.proc_ro_task = 0x8;
    g_offsets.task_map = 0x28;
    g_offsets.map_pmap = 0x40;
    return 0;
}

char* get_device_machine(void) {
    // identify device
    if (g_ctx.device_machine[0] != '\0') {
        return g_ctx.device_machine;
    }

    struct utsname uts = {};
    uname(&uts);
    snprintf(g_ctx.device_machine, sizeof(g_ctx.device_machine), "%s", uts.machine);
    LOG("Running on %s", g_ctx.device_machine);
    return g_ctx.device_machine;
}

static bool create_target_file(char* path) {
    FILE* fp = fopen(path, "wb");
    if (fp == NULL) return false;
    // default_file_content is set to random marker
    bool ok = fwrite(g_ctx.default_file_content, 1, g_ctx.target_file_size, fp) == g_ctx.target_file_size;
    fclose(fp);
    return ok;
}

void init_target_file(void) {
    // original does calloc, we've already allocated it in the global context, so set both to 0
    memset(g_ctx.read_file_path, 0, sizeof(g_ctx.read_file_path));
    memset(g_ctx.write_file_path, 0, sizeof(g_ctx.write_file_path));
    confstr(_CS_DARWIN_USER_TEMP_DIR, g_ctx.read_file_path, sizeof(g_ctx.read_file_path));
    confstr(_CS_DARWIN_USER_TEMP_DIR, g_ctx.write_file_path, sizeof(g_ctx.write_file_path));
    snprintf(g_ctx.read_file_path + strlen(g_ctx.read_file_path), sizeof(g_ctx.read_file_path) - strlen(g_ctx.read_file_path), "/%08x", arc4random());
    snprintf(g_ctx.write_file_path + strlen(g_ctx.write_file_path), sizeof(g_ctx.write_file_path) - strlen(g_ctx.write_file_path), "/%08x", arc4random());

    // creates file at temp
    if (!create_target_file(g_ctx.read_file_path) || !create_target_file(g_ctx.write_file_path)) {
        g_ctx.read_fd = -1;
        g_ctx.write_fd = -1;
        return;
    }

    g_ctx.read_fd = open(g_ctx.read_file_path, O_RDWR);
    g_ctx.write_fd = open(g_ctx.write_file_path, O_RDWR);

    LOG("read_fd: %x", g_ctx.read_fd);
    LOG("write_fd: %x", g_ctx.write_fd);

    // files will be deleted when fd is closed
    remove(g_ctx.read_file_path);
    remove(g_ctx.write_file_path);

    // no cache
    fcntl(g_ctx.read_fd, F_NOCACHE, 1);
    fcntl(g_ctx.write_fd, F_NOCACHE, 1);
}
