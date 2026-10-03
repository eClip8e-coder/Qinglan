#ifndef SYSTEM_PROBE_H
#define SYSTEM_PROBE_H
#include <stdint.h>
#include <stdbool.h>

typedef struct {
    uint64_t total, app, wired, compressed, cached, swap;
    uint64_t pageins, pageouts, swapins, swapouts, page_size;
    int pressure;
} QLMemory;
bool ql_memory(QLMemory *out);

typedef struct {
    int32_t pid;
    uint64_t start_us, cpu_ns, resident;
    char name[256];
} QLProcess;
// Returns number of readable processes; -1 means enumeration failed.
int ql_processes(QLProcess *out, int capacity, int *total);

typedef struct QLSMC QLSMC;
QLSMC *ql_smc_open(void);
void ql_smc_close(QLSMC *smc);
bool ql_smc_read(QLSMC *smc, const char *key, double *out);
int ql_smc_keys(QLSMC *smc, char *out, int capacity);
bool ql_smc_decode(uint32_t type, const uint8_t *bytes, uint32_t size, double *out);
// Positive discharge watts only; charging is deliberately not system power.
bool ql_battery_discharge(double *watts);
#endif
