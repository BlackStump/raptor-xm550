/*
 * gpiowatch -- record every change in the XM530/XM550 GPIO registers.
 *
 * Each GPIO has its own 32-bit register at 0x10020000 + 4 * pin. This maps
 * pins 0..NPIN-1, prints them once, then samples them every 10 ms for the
 * given number of seconds (default 120) and prints each change with the
 * time since the start, so a pulse on the IR-cut pins and a light-sensor
 * input changing can be told apart by when they happen and how long they
 * last. Read-only.
 *
 * usage: gpiowatch [seconds] [npins]
 */
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define GPIO_BASE 0x10020000u
#define MAXPIN 128

static double now_s(void)
{
    struct timespec ts;

    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

int main(int argc, char **argv)
{
    int secs = argc > 1 ? atoi(argv[1]) : 120;
    int npin = argc > 2 ? atoi(argv[2]) : 64;
    uint32_t prev[MAXPIN];
    volatile uint32_t *g;
    double t0, t;
    int fd, i;

    if (npin < 1 || npin > MAXPIN)
        npin = 64;
    fd = open("/dev/mem", O_RDONLY | O_SYNC);
    if (fd < 0) {
        perror("/dev/mem");
        return 1;
    }
    g = mmap(NULL, 4096, PROT_READ, MAP_SHARED, fd, GPIO_BASE);
    if (g == MAP_FAILED) {
        perror("mmap");
        return 1;
    }
    printf("start: pin=value (non-zero only)\n");
    for (i = 0; i < npin; i++) {
        prev[i] = g[i];
        if (prev[i])
            printf("  %2d=%08x", i, prev[i]);
        if (i % 6 == 5)
            printf("\n");
    }
    printf("\nwatching %d pins for %d s\n", npin, secs);
    fflush(stdout);

    t0 = now_s();
    while ((t = now_s() - t0) < secs) {
        for (i = 0; i < npin; i++) {
            uint32_t v = g[i];

            if (v != prev[i]) {
                printf("%8.3f  pin %2d  %08x -> %08x  (changed bits %08x)\n", t, i, prev[i], v,
                       prev[i] ^ v);
                fflush(stdout);
                prev[i] = v;
            }
        }
        usleep(10000);
    }
    printf("done\n");
    return 0;
}
