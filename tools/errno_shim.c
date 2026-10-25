/* Darwin has no glibc-style __errno_location(); the RGC standard library
 * (net, event) calls it directly, so provide the alias when linking rack. */
#if defined(__APPLE__)
#include <errno.h>

int *__errno_location(void) {
    return __error();
}
#endif
