#ifndef VSG_CONFIG_H
#define VSG_CONFIG_H

#include <stdbool.h>

#define VSG_MAX_PATH       512
#define VSG_MAX_NODES      16
#define VSG_MAX_LINE       1024
#define VSG_CONF_DEFAULT   "/etc/vmstate-guardian/vmstate-guardian.conf"

typedef enum {
    VSG_MODE_QMP,       /* QMP pre-copy (minimal pause) */
    VSG_MODE_QM         /* qm snapshot fallback (full pause) */
} vsg_snap_mode_t;

typedef struct {
    int              vmid;
    int              snapshot_interval;    /* seconds between snapshots */
    int              monitor_interval;     /* seconds between HA checks */
    int              max_restore_attempts; /* anti-loop guard */
    int              restore_cooldown;     /* seconds between restore attempts */
    int              migration_timeout;    /* seconds to wait for QMP migration */
    vsg_snap_mode_t  snap_mode;
    char             state_dir[VSG_MAX_PATH];     /* /var/lib/vmstate-guardian */
    char             log_file[VSG_MAX_PATH];      /* /var/log/vmstate-guardian.log */
    char             vmstate_path[VSG_MAX_PATH];  /* /ceph/vmstate/<vmid> */
    char             qmp_socket[VSG_MAX_PATH];    /* auto: /var/run/qemu-server/<vmid>.qmp */
    bool             foreground;                  /* don't daemonize */
} vsg_config_t;

/* Parse config file, returns 0 on success */
int  vsg_config_load(vsg_config_t *cfg, const char *path);
void vsg_config_set_defaults(vsg_config_t *cfg);
void vsg_config_dump(const vsg_config_t *cfg);

#endif
