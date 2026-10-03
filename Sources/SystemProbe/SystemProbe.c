#include "SystemProbe.h"
#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <sys/sysctl.h>
#include <libproc.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

bool ql_memory(QLMemory *out) {
    memset(out, 0, sizeof(*out));
    size_t total_size = sizeof(out->total);
    if (sysctlbyname("hw.memsize", &out->total, &total_size, NULL, 0)) return false;
    vm_statistics64_data_t vm = {0};
    mach_msg_type_number_t count = sizeof(vm) / sizeof(integer_t);
    mach_port_t host = mach_host_self();
    vm_size_t page_size = 0;
    kern_return_t page_result = host_page_size(host, &page_size);
    kern_return_t result = host_statistics64(host, HOST_VM_INFO64, (host_info64_t)&vm, &count);
    mach_port_deallocate(mach_task_self(), host);
    if (result != KERN_SUCCESS || page_result != KERN_SUCCESS) return false;
    out->page_size = page_size;
    out->app = (uint64_t)(vm.internal_page_count > vm.purgeable_count ?
        vm.internal_page_count - vm.purgeable_count : 0) * page_size;
    out->wired = (uint64_t)vm.wire_count * page_size;
    out->compressed = (uint64_t)vm.compressor_page_count * page_size;
    out->cached = ((uint64_t)vm.external_page_count + vm.purgeable_count) * page_size;
    out->pageins = vm.pageins; out->pageouts = vm.pageouts;
    out->swapins = vm.swapins; out->swapouts = vm.swapouts;
    struct xsw_usage swap = {0};
    size_t swap_size = sizeof(swap);
    if (!sysctlbyname("vm.swapusage", &swap, &swap_size, NULL, 0)) out->swap = swap.xsu_used;
    size_t pressure_size = sizeof(out->pressure);
    if (sysctlbyname("kern.memorystatus_vm_pressure_level", &out->pressure, &pressure_size, NULL, 0))
        out->pressure = 0;
    return true;
}

int ql_processes(QLProcess *out, int capacity, int *total) {
    *total = 0;
    mach_timebase_info_data_t timebase;
    if (mach_timebase_info(&timebase) != KERN_SUCCESS || !timebase.denom) return -1;
    int estimate = proc_listallpids(NULL, 0);
    if (estimate <= 0 || capacity <= 0) return -1;
    int slots = estimate + 512;
    pid_t *pids = calloc((size_t)slots, sizeof(pid_t));
    if (!pids) return -1;
    int count = proc_listallpids(pids, slots * (int)sizeof(pid_t));
    if (count <= 0) { free(pids); return -1; }
    count = count < slots ? count : slots;
    *total = count;
    int used = 0;
    for (int i = 0; i < count && used < capacity; i++) {
        if (pids[i] <= 0) continue;
        struct proc_taskallinfo info = {0};
        if (proc_pidinfo(pids[i], PROC_PIDTASKALLINFO, 0, &info, sizeof(info)) != sizeof(info)) continue;
        QLProcess *p = &out[used++];
        memset(p, 0, sizeof(*p));
        p->pid = pids[i];
        p->start_us = info.pbsd.pbi_start_tvsec * 1000000 + info.pbsd.pbi_start_tvusec;
        // proc_taskinfo uses Mach absolute ticks (not ns on Apple Silicon).
        __uint128_t ticks = (__uint128_t)info.ptinfo.pti_total_user + info.ptinfo.pti_total_system;
        p->cpu_ns = (uint64_t)(ticks * timebase.numer / timebase.denom);
        p->resident = info.ptinfo.pti_resident_size;
        if (proc_name(pids[i], p->name, sizeof(p->name)) <= 0)
            strlcpy(p->name, info.pbsd.pbi_comm, sizeof(p->name));
    }
    free(pids);
    return used;
}

// AppleSMC user-client ABI. Only read-key-info, read-bytes and enumerate are used.
typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } SMCVersion;
typedef struct { uint16_t version, length; uint32_t cpu, gpu, memory; } SMCLimits;
typedef struct { uint32_t size, type; uint8_t attributes; } SMCInfo;
typedef struct {
    uint32_t key;
    SMCVersion version;
    SMCLimits limits;
    SMCInfo info;
    uint8_t result, status, command;
    uint32_t index;
    uint8_t bytes[32];
} SMCMessage;
_Static_assert(sizeof(SMCMessage) == 80, "SMC ABI size mismatch");
struct QLSMC {
    io_connect_t connection;
    struct { uint32_t key; SMCInfo info; } cache[256];
    int cached;
};
static uint32_t fourcc(const char *s) {
    return ((uint32_t)(uint8_t)s[0] << 24) | ((uint32_t)(uint8_t)s[1] << 16) |
           ((uint32_t)(uint8_t)s[2] << 8) | (uint8_t)s[3];
}
static bool smc_call(QLSMC *smc, SMCMessage *in, SMCMessage *out) {
    size_t size = sizeof(*out);
    return smc && IOConnectCallStructMethod(smc->connection, 2, in, sizeof(*in), out, &size) == KERN_SUCCESS &&
        size == sizeof(*out) && out->result == 0;
}
QLSMC *ql_smc_open(void) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return NULL;
    QLSMC *smc = calloc(1, sizeof(*smc));
    if (!smc) { IOObjectRelease(service); return NULL; }
    kern_return_t result = IOServiceOpen(service, mach_task_self(), 0, &smc->connection);
    IOObjectRelease(service);
    if (result != KERN_SUCCESS) { free(smc); return NULL; }
    return smc;
}
void ql_smc_close(QLSMC *smc) {
    if (smc) { IOServiceClose(smc->connection); free(smc); }
}
bool ql_smc_decode(uint32_t type, const uint8_t *b, uint32_t size, double *out) {
    if (!b || !out || size == 0 || size > 32) return false;
    if (type == fourcc("flt ") && size == 4) {
        float value; memcpy(&value, b, sizeof(value)); *out = value;
    } else if (type == fourcc("ui8 ") && size == 1) *out = b[0];
    else if (type == fourcc("ui16") && size == 2) *out = ((uint16_t)b[0] << 8) | b[1];
    else if (type == fourcc("ui32") && size == 4)
        *out = ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) | ((uint32_t)b[2] << 8) | b[3];
    else if (type == fourcc("sp78") && size == 2)
        *out = (int16_t)(((uint16_t)b[0] << 8) | b[1]) / 256.0;
    else if (type == fourcc("fpe2") && size == 2)
        *out = (((uint16_t)b[0] << 8) | b[1]) / 4.0;
    else return false;
    return isfinite(*out);
}
bool ql_smc_read(QLSMC *smc, const char *key, double *out) {
    if (!smc || !key || strlen(key) != 4) return false;
    SMCMessage request = {0}, reply = {0};
    request.key = fourcc(key);
    SMCInfo info = {0};
    for (int i = 0; i < smc->cached; i++)
        if (smc->cache[i].key == request.key) { info = smc->cache[i].info; break; }
    if (!info.size) {
        request.command = 9;
        if (!smc_call(smc, &request, &reply)) return false;
        info = reply.info;
        if (!info.size || info.size > 32) return false;
        if (smc->cached < 256) {
            smc->cache[smc->cached].key = request.key;
            smc->cache[smc->cached++].info = info;
        }
    }
    request.info.size = info.size;
    request.command = 5;
    memset(&reply, 0, sizeof(reply));
    if (!smc_call(smc, &request, &reply)) return false;
    return ql_smc_decode(info.type, reply.bytes, info.size, out);
}
int ql_smc_keys(QLSMC *smc, char *out, int capacity) {
    double count = 0;
    if (!ql_smc_read(smc, "#KEY", &count) || count < 0 || count > 20000) return 0;
    int written = 0;
    for (uint32_t i = 0; i < (uint32_t)count && written < capacity; i++) {
        SMCMessage request = {0}, reply = {0};
        request.command = 8; request.index = i;
        if (!smc_call(smc, &request, &reply)) continue;
        char key[5] = {reply.key >> 24, reply.key >> 16, reply.key >> 8, reply.key, 0};
        // Bound discovery and retain temperature keys only.
        if (key[0] == 'T') memcpy(out + 5 * written++, key, 5);
    }
    return written;
}
static bool number(CFDictionaryRef dict, CFStringRef key, int64_t *out) {
    CFTypeRef value = CFDictionaryGetValue(dict, key);
    return value && CFGetTypeID(value) == CFNumberGetTypeID() &&
        CFNumberGetValue(value, kCFNumberSInt64Type, out);
}
bool ql_battery_discharge(double *watts) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"));
    if (!service) return false;
    CFMutableDictionaryRef properties = NULL;
    kern_return_t result = IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0);
    IOObjectRelease(service);
    if (result != KERN_SUCCESS || !properties) return false;
    int64_t voltage = 0, current = 0;
    CFTypeRef external = CFDictionaryGetValue(properties, CFSTR("ExternalConnected"));
    bool on_battery = external == kCFBooleanFalse;
    bool valid = number(properties, CFSTR("Voltage"), &voltage) &&
        number(properties, CFSTR("Amperage"), &current);
    CFRelease(properties);
    // Some drivers expose a signed 32-bit current in an unsigned CFNumber.
    if (current > INT32_MAX && current <= UINT32_MAX) current = (int32_t)current;
    if (!valid || !on_battery || voltage <= 0 || current >= 0) return false;
    *watts = (double)voltage * (double)-current / 1000000.0;
    return isfinite(*watts) && *watts < 500;
}
