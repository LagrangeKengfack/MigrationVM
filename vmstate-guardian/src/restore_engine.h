#ifndef VSG_RESTORE_ENGINE_H
#define VSG_RESTORE_ENGINE_H

#include "config.h"

/* Attempt to restore VM state after HA failover.
   Returns 0 on success, -1 on failure. */
int restore_vm_state(const vsg_config_t *cfg);

#endif
