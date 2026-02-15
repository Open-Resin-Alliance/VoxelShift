/**
 * @file thread_priority.c
 * @brief Platform-specific thread priority hinting.
 */
#include "voxelshift_native.h"

#ifdef _WIN32
#include <windows.h>
#endif

/**
 * @brief Hint the OS to reduce or restore priority for the current thread.
 * @param background Non-zero to lower priority, zero to restore normal.
 */
int set_current_thread_background_priority(int32_t background) {
#ifdef _WIN32
  const int prio = background ? THREAD_PRIORITY_BELOW_NORMAL : THREAD_PRIORITY_NORMAL;
  return SetThreadPriority(GetCurrentThread(), prio) ? 1 : 0;
#else
  (void)background;
  return 0;
#endif
}
