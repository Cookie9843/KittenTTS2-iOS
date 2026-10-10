/* Host stand-in for iOS's <os/proc.h> (only the bridge's os_proc_available_memory call is needed). */
#include <stddef.h>
static inline size_t os_proc_available_memory(void) { return 1234u << 20; }
