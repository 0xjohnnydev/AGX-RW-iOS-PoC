#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "agx.h"
#include "poc.h"

int main(int argc, char** argv) {
    if (argc == 2 && strcmp(argv[1], "--agx-self-test") == 0) {
        return agx_buffer_rw_self_test() ? 0 : 1;
    }
    agx_test_mode_t mode = AGX_TEST_SHADOW;
    uint64_t argument = 0;
    if (argc >= 2 && !agx_test_mode_from_argument(argv[1], &mode)) goto usage;
    if (mode == AGX_TEST_READ) {
        char* end = NULL;
        errno = 0;
        if (argc != 3) goto usage;
        argument = strtoull(argv[2], &end, 0);
        if (errno != 0 || !end || *end != '\0') goto usage;
    } else if (argc > 2) {
        goto usage;
    }
    if (!agx_test_argument_valid(mode, argument)) goto usage;
    return clearsword_run_test(mode, argument) == 0 ? 0 : 1;

usage:
    fprintf(stderr,
            "usage: %s [--agx-self-test|--acquire-only|--gfx-read-control|"
            "--gfx-read <gfx-va>|--gfx-write-control|--gfx-write-panic|"
            "--gfx-auth-call-control|--gfx-auth-call-panic|"
            "--gfx-pac-reuse-control|--gfx-pac-reuse|"
            "--micro-ppl-ttbr1-control|--micro-ppl-ttbr1-panic]\n",
            argv[0]);
    return 2;
}
