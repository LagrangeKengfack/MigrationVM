#include "snapshot_mgr.h"
#include "proxmox_cmd.h"
#include "qmp.h"
#include "logger.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/stat.h>

static int snap_cycle_qm(const vsg_config_t *cfg)
{
    char old_snap[128] = {0};
    snap_find_latest(cfg->vmid, old_snap, sizeof(old_snap));

    /* Create new snapshot with timestamp */
    char new_snap[128];
    snprintf(new_snap, sizeof(new_snap), "%s%ld", VSG_SNAP_PREFIX, (long)time(NULL));

    vsg_log(VSG_LOG_INFO, "Creating snapshot %s (qm mode, vmstate=1)", new_snap);
    if (pve_snapshot_create(cfg->vmid, new_snap, 1) != 0) {
        vsg_log(VSG_LOG_ERROR, "Failed to create snapshot %s", new_snap);
        return -1;
    }
    vsg_log(VSG_LOG_INFO, "Snapshot %s created", new_snap);

    /* Delete old snapshot if it exists */
    if (old_snap[0] && strcmp(old_snap, new_snap) != 0) {
        vsg_log(VSG_LOG_INFO, "Deleting old snapshot %s", old_snap);
        pve_snapshot_delete(cfg->vmid, old_snap);
    }

    return 0;
}

static int snap_cycle_qmp(const vsg_config_t *cfg)
{
    char state_file[VSG_MAX_PATH + 64];
    char state_file_new[VSG_MAX_PATH + 64];

    snprintf(state_file, sizeof(state_file), "%s/latest.state", cfg->vmstate_path);
    snprintf(state_file_new, sizeof(state_file_new), "%s/new.state", cfg->vmstate_path);

    /* Ensure directory exists */
    char mkdir_cmd[VSG_MAX_PATH + 16];
    snprintf(mkdir_cmd, sizeof(mkdir_cmd), "mkdir -p %s", cfg->vmstate_path);
    cmd_exec(mkdir_cmd, NULL, 0);

    /* Connect to QMP */
    qmp_conn_t conn;
    if (qmp_connect(&conn, cfg->qmp_socket) < 0) {
        vsg_log(VSG_LOG_ERROR, "Cannot connect to QMP socket %s", cfg->qmp_socket);
        return -1;
    }

    /* Migrate VM state to file (pre-copy: minimal pause) */
    vsg_log(VSG_LOG_INFO, "Starting pre-copy state capture to %s", state_file_new);
    int ret = qmp_migrate_to_file(&conn, state_file_new, cfg->migration_timeout);
    qmp_disconnect(&conn);

    if (ret < 0) {
        vsg_log(VSG_LOG_ERROR, "Pre-copy migration failed");
        unlink(state_file_new);
        return -1;
    }

    /* Atomic rename: new.state -> latest.state */
    if (rename(state_file_new, state_file) != 0) {
        vsg_log(VSG_LOG_ERROR, "Failed to rename %s -> %s", state_file_new, state_file);
        return -1;
    }

    /* Write timestamp marker */
    char ts_file[VSG_MAX_PATH + 64];
    snprintf(ts_file, sizeof(ts_file), "%s/timestamp", cfg->vmstate_path);
    FILE *fp = fopen(ts_file, "w");
    if (fp) {
        fprintf(fp, "%ld\n", (long)time(NULL));
        fclose(fp);
    }

    vsg_log(VSG_LOG_INFO, "State capture completed: %s", state_file);
    return 0;
}

int snap_cycle(const vsg_config_t *cfg)
{
    if (cfg->snap_mode == VSG_MODE_QMP)
        return snap_cycle_qmp(cfg);
    else
        return snap_cycle_qm(cfg);
}

int snap_find_latest(int vmid, char *name, int name_len)
{
    char output[CMD_OUTPUT_SIZE];
    if (pve_snapshot_list(vmid, output, sizeof(output)) != 0)
        return -1;

    /* Parse qm listsnapshot output, find latest vsg-* entry */
    char *latest = NULL;
    long latest_ts = 0;

    char *line = strtok(output, "\n");
    while (line) {
        char *p = strstr(line, VSG_SNAP_PREFIX);
        if (p) {
            /* Extract snapshot name (ends at space or newline) */
            char sname[128];
            int i = 0;
            while (p[i] && p[i] != ' ' && p[i] != '\n' && i < 127) {
                sname[i] = p[i];
                i++;
            }
            sname[i] = '\0';

            /* Extract timestamp from name */
            long ts = atol(sname + strlen(VSG_SNAP_PREFIX));
            if (ts > latest_ts) {
                latest_ts = ts;
                snprintf(name, name_len, "%s", sname);
                latest = name;
            }
        }
        line = strtok(NULL, "\n");
    }

    return latest ? 0 : -1;
}
