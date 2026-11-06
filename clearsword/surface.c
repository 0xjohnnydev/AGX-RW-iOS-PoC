#include "surface.h"

#include <stdlib.h>
#include <string.h>

CFNumberRef CFNUM(uint64_t value) {
    return CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &value);
}

IOSurfaceRef create_surface_with_address(mach_vm_address_t address, mach_vm_size_t size) {
    CFMutableDictionaryRef properties = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFNumberRef address_number = CFNUM(address);
    CFNumberRef size_number = CFNUM(size);
    CFDictionarySetValue(properties, CFSTR("IOSurfaceAddress"), address_number);
    CFDictionarySetValue(properties, CFSTR("IOSurfaceAllocSize"), size_number);
    CFRelease(address_number);
    CFRelease(size_number);

    IOSurfaceRef surface = IOSurfaceCreate(properties);
    if (surface != NULL) IOSurfacePrefetchPages(surface);
    CFRelease(properties);

    return surface;  // caller owns
}

kern_return_t create_physically_contiguous_mapping(mach_port_t* port_out, mach_vm_address_t* address_out, mach_vm_size_t size) {
    kern_return_t kr = KERN_SUCCESS;

    CFMutableDictionaryRef dict = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFNumberRef size_number = CFNUM(size);
    CFDictionarySetValue(dict, CFSTR("IOSurfaceAllocSize"), size_number);
    CFRelease(size_number);
    CFDictionarySetValue(dict, CFSTR("IOSurfaceMemoryRegion"), CFSTR("PurpleGfxMem"));

    // create surface in PurpleGfxMem, which is contiguous by nature
    IOSurfaceRef surface = IOSurfaceCreate(dict);
    CFRelease(dict);

    if (surface == NULL) {
        return KERN_FAILURE;
    }

    // get its uaddr
    mach_vm_address_t physical_mapping_address = (mach_vm_address_t)IOSurfaceGetBaseAddress(surface);
    LOG("physical_mapping_address: %#llx", physical_mapping_address);

    // create a memory entry in PurpleGfxMem
    mach_port_t memory_object = MACH_PORT_NULL;
    kr = mach_make_memory_entry_64(mach_task_self(), &size, physical_mapping_address, VM_PROT_DEFAULT, &memory_object, MACH_PORT_NULL);
    if (kr != KERN_SUCCESS) {
        CFRelease(surface);
        return kr;
    }

    // map in PurpleGfxMem
    mach_vm_address_t new_mapping_address = 0;
    kr = mach_vm_map(mach_task_self(), &new_mapping_address, size, 0, VM_FLAGS_ANYWHERE | VM_FLAGS_RANDOM_ADDR, memory_object, 0, false, VM_PROT_DEFAULT, VM_PROT_DEFAULT, VM_INHERIT_NONE);
    CFRelease(surface);
    if (kr != KERN_SUCCESS) {
        mach_port_deallocate(mach_task_self(), memory_object);
        return kr;
    }

    *port_out = memory_object;
    *address_out = new_mapping_address;
    return KERN_SUCCESS;
}

static kern_return_t reserve_surfaces(void) {
    if (g_ctx.mlock_surfaces_count < g_ctx.mlock_surfaces_capacity) {
        return KERN_SUCCESS;
    }

    size_t capacity = g_ctx.mlock_surfaces_capacity == 0 ? 1024 : g_ctx.mlock_surfaces_capacity * 2;
    mlock_surfaces_t* surfaces = realloc(g_ctx.mlock_surfaces, capacity * sizeof(*surfaces));
    if (surfaces == NULL) return KERN_RESOURCE_SHORTAGE;

    g_ctx.mlock_surfaces = surfaces;
    g_ctx.mlock_surfaces_capacity = capacity;
    return KERN_SUCCESS;
}

kern_return_t surface_mlock(mach_vm_address_t address, mach_vm_size_t size) {
    IOSurfaceRef surface = create_surface_with_address(address, size);
    if (surface == NULL) return KERN_FAILURE;
    kern_return_t kr = reserve_surfaces();
    if (kr != KERN_SUCCESS) {
        CFRelease(surface);
        return kr;
    }

    size_t idx = g_ctx.mlock_surfaces_count++;
    g_ctx.mlock_surfaces[idx].address = address;
    g_ctx.mlock_surfaces[idx].surface = surface;
    return KERN_SUCCESS;
}

void surface_munlock(mach_vm_address_t address) {
    for (size_t idx = 0; idx < g_ctx.mlock_surfaces_count; idx++) {
        if (g_ctx.mlock_surfaces[idx].address == address && g_ctx.mlock_surfaces[idx].surface != NULL) {
            CFRelease(g_ctx.mlock_surfaces[idx].surface);
            g_ctx.mlock_surfaces[idx] = g_ctx.mlock_surfaces[--g_ctx.mlock_surfaces_count];
            break;
        }
    }
}

size_t surface_release_oldest(size_t count) {
    if (count > g_ctx.mlock_surfaces_count) count = g_ctx.mlock_surfaces_count;
    for (size_t idx = 0; idx < count; idx++) {
        CFRelease(g_ctx.mlock_surfaces[idx].surface);
    }
    memmove(g_ctx.mlock_surfaces, g_ctx.mlock_surfaces + count, (g_ctx.mlock_surfaces_count - count) * sizeof(*g_ctx.mlock_surfaces));
    g_ctx.mlock_surfaces_count -= count;
    return count;
}

void surface_munlock_all(void) {
    while (g_ctx.mlock_surfaces_count != 0) {
        CFRelease(g_ctx.mlock_surfaces[--g_ctx.mlock_surfaces_count].surface);
    }
    free(g_ctx.mlock_surfaces);
    g_ctx.mlock_surfaces = NULL;
    g_ctx.mlock_surfaces_capacity = 0;
}
