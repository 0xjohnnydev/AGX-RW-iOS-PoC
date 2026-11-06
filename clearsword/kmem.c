#include "kmem.h"

#include "krw.h"

static bool read_pointer(uint64_t address, uint64_t* value) {
    return early_kread64_checked(address, value) && krw_is_kernel_address(*value);
}

uint64_t find_self_proc(void) {
    uint64_t socket = 0;
    uint64_t thread = 0;
    uint64_t thread_ro = 0;
    uint64_t proc = 0;
    if (!read_pointer(g_ctx.control_socket_pcb + g_ctx.offsets.inpcb_inp_socket, &socket) || !read_pointer(socket + g_ctx.offsets.socket_so_background_thread, &thread) ||
        !read_pointer(thread + g_ctx.offsets.thread_t_ro, &thread_ro) || !read_pointer(thread_ro + g_ctx.offsets.thread_ro_proc, &proc)) {
        return 0;
    }
    return proc;
}

uint64_t task_from_proc(uint64_t proc) {
    uint64_t proc_ro = 0;
    uint64_t task = 0;
    if (!krw_is_kernel_address(proc) || !read_pointer(proc + g_ctx.offsets.proc_p_ro, &proc_ro) || !read_pointer(proc_ro + g_ctx.offsets.proc_ro_task, &task)) {
        return 0;
    }
    return task;
}

uint64_t pmap_from_task(uint64_t task) {
    uint64_t task_map = 0;
    uint64_t pmap = 0;
    if (!krw_is_kernel_address(task) || !read_pointer(task + g_ctx.offsets.task_map, &task_map) || !read_pointer(task_map + g_ctx.offsets.map_pmap, &pmap)) {
        return 0;
    }
    return pmap;
}
