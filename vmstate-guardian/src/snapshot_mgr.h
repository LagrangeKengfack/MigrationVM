#ifndef VSG_SNAPSHOT_MGR_H
#define VSG_SNAPSHOT_MGR_H

#include "config.h"

#define VSG_SNAP_PREFIX "vsg-"

/* Perform one snapshot cycle: create new, delete old. Returns 0 on success. */
int  snap_cycle(const vsg_config_t *cfg);

/* Find the latest vsg-* snapshot name. Returns 0 if found. */
int  snap_find_latest(int vmid, char *name, int name_len);

#endif
