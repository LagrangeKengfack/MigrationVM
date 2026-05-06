#ifndef VSG_HA_MONITOR_H
#define VSG_HA_MONITOR_H

#include "config.h"
#include <stdbool.h>

/* Check if VM was restarted by HA on a different node.
   Returns true if a node change was detected. */
bool ha_detect_failover(const vsg_config_t *cfg);

/* Save the current node as "last known" in state file */
int  ha_save_state(const vsg_config_t *cfg, const char *node);

/* Load the last known node from state file */
int  ha_load_state(const vsg_config_t *cfg, char *node, int len);

/* Check if VM is running on this local node */
bool ha_vm_is_local(const vsg_config_t *cfg);

#endif
