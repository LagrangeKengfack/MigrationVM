#include "restore_engine.h"
#include "proxmox_cmd.h"
#include "snapshot_mgr.h"
#include "qmp.h"
#include "ha_monitor.h"
#include "logger.h"
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <sys/stat.h>

static int check_restore_lock(const vsg_config_t *cfg)
{
    char lock_path[VSG_MAX_PATH + 64];
    snprintf(lock_path, sizeof(lock_path), "%s/restore.lock", cfg->state_dir);

    struct stat st;
    if (stat(lock_path, &st) == 0) {
        time_t age = time(NULL) - st.st_mtime;
        if (age < cfg->restore_cooldown) {
            vsg_log(VSG_LOG_WARN, "Restore lock active (age=%lds, cooldown=%ds). Skipping.",
                    (long)age, cfg->restore_cooldown);
            return -1;
        }
        vsg_log(VSG_LOG_INFO, "Restore lock expired (age=%lds), proceeding", (long)age);
    }
    return 0;
}

static void set_restore_lock(const vsg_config_t *cfg)
{
    char lock_path[VSG_MAX_PATH + 64];
    snprintf(lock_path, sizeof(lock_path), "%s/restore.lock", cfg->state_dir);
    FILE *fp = fopen(lock_path, "w");
    if (fp) {
        fprintf(fp, "%ld\n", (long)time(NULL));
        fclose(fp);
    }
}

static int count_restore_attempts(const vsg_config_t *cfg)
{
    char path[VSG_MAX_PATH + 64];
    snprintf(path, sizeof(path), "%s/restore_count", cfg->state_dir);

    FILE *fp = fopen(path, "r");
    if (!fp) return 0;
    int count = 0;
    if (fscanf(fp, "%d", &count) != 1) count = 0;
    fclose(fp);
    return count;
}

static void increment_restore_count(const vsg_config_t *cfg)
{
    int count = count_restore_attempts(cfg) + 1;
    char path[VSG_MAX_PATH + 64];
    snprintf(path, sizeof(path), "%s/restore_count", cfg->state_dir);
    FILE *fp = fopen(path, "w");
    if (fp) { fprintf(fp, "%d\n", count); fclose(fp); }
}

static void reset_restore_count(const vsg_config_t *cfg)
{
    char path[VSG_MAX_PATH + 64];
    snprintf(path, sizeof(path), "%s/restore_count", cfg->state_dir);
    unlink(path);
}

static int restore_qm_mode(const vsg_config_t *cfg)
{
    char snap_name[128];
    if (snap_find_latest(cfg->vmid, snap_name, sizeof(snap_name)) != 0) {
        vsg_log(VSG_LOG_ERROR, "No vsg-* snapshot found for VM %d", cfg->vmid);
        return -1;
    }

    vsg_log(VSG_LOG_INFO, "Restoring VM %d to snapshot %s (qm mode)", cfg->vmid, snap_name);

    /* Stop the VM first */
    vsg_log(VSG_LOG_INFO, "Stopping VM %d", cfg->vmid);
    if (pve_vm_stop(cfg->vmid) != 0) {
        vsg_log(VSG_LOG_ERROR, "Failed to stop VM %d", cfg->vmid);
        return -1;
    }
    sleep(5);

    /* Rollback to the snapshot */
    vsg_log(VSG_LOG_INFO, "Rolling back to %s", snap_name);
    if (pve_snapshot_rollback(cfg->vmid, snap_name) != 0) {
        vsg_log(VSG_LOG_ERROR, "Rollback failed for snapshot %s", snap_name);
        return -1;
    }

    /* Start VM — it resumes from the snapshot state */
    vsg_log(VSG_LOG_INFO, "Starting VM %d from restored state", cfg->vmid);
    if (pve_vm_start(cfg->vmid) != 0) {
        vsg_log(VSG_LOG_ERROR, "Failed to start VM %d after rollback", cfg->vmid);
        return -1;
    }

    return 0;
}

static int restore_qmp_mode(const vsg_config_t *cfg)
{
    char state_file[VSG_MAX_PATH + 64];
    snprintf(state_file, sizeof(state_file), "%s/latest.state", cfg->vmstate_path);

    /* Check that state file exists and is non-empty */
    struct stat st;
    if (stat(state_file, &st) != 0 || st.st_size == 0) {
        vsg_log(VSG_LOG_ERROR, "No valid state file at %s", state_file);
        return -1;
    }

    vsg_log(VSG_LOG_INFO, "Restoring VM %d from %s (%ld bytes, QMP mode)",
            cfg->vmid, state_file, (long)st.st_size);

    /* Stop the HA-started VM */
    vsg_log(VSG_LOG_INFO, "Stopping VM %d for state restore", cfg->vmid);
    if (pve_vm_stop(cfg->vmid) != 0) {
        vsg_log(VSG_LOG_ERROR, "Failed to stop VM %d", cfg->vmid);
        return -1;
    }
    sleep(5);

    /* Inject -incoming args into VM config */
    char incoming_args[VSG_MAX_PATH * 2];
    snprintf(incoming_args, sizeof(incoming_args),
             "-incoming \"exec:cat %s\"", state_file);

    vsg_log(VSG_LOG_INFO, "Setting VM args: %s", incoming_args);
    if (pve_vm_set_args(cfg->vmid, incoming_args) != 0) {
        vsg_log(VSG_LOG_ERROR, "Failed to set VM args");
        return -1;
    }

    /* Start VM with -incoming (loads state from file, starts paused) */
    vsg_log(VSG_LOG_INFO, "Starting VM %d with incoming state", cfg->vmid);
    if (pve_vm_start(cfg->vmid) != 0) {
        vsg_log(VSG_LOG_ERROR, "Failed to start VM %d with incoming args", cfg->vmid);
        pve_vm_delete_args(cfg->vmid);
        return -1;
    }

    /* Wait for VM to load state, then send 'cont' via QMP */
    sleep(10);
    qmp_conn_t conn;
    int retries = 5;
    while (retries-- > 0) {
        if (qmp_connect(&conn, cfg->qmp_socket) == 0) {
            vsg_log(VSG_LOG_INFO, "Sending 'cont' to resume VM");
            qmp_cont(&conn);
            qmp_disconnect(&conn);
            break;
        }
        vsg_log(VSG_LOG_WARN, "QMP not ready, retrying in 5s...");
        sleep(5);
    }

    /* Clean up: remove -incoming args from config */
    pve_vm_delete_args(cfg->vmid);

    /* Verify VM is running */
    sleep(3);
    char status[64];
    if (pve_vm_status(cfg->vmid, status, sizeof(status)) == 0 &&
        strcmp(status, "running") == 0) {
        vsg_log(VSG_LOG_INFO, "VM %d is running with restored state", cfg->vmid);
        return 0;
    }

    vsg_log(VSG_LOG_ERROR, "VM %d is not running after restore (status: %s)",
            cfg->vmid, status);
    return -1;
}

int restore_vm_state(const vsg_config_t *cfg)
{
    /* Anti-loop: check cooldown lock */
    if (check_restore_lock(cfg) < 0) return -1;

    /* Anti-loop: check attempt counter */
    int attempts = count_restore_attempts(cfg);
    if (attempts >= cfg->max_restore_attempts) {
        vsg_log(VSG_LOG_ERROR,
            "Max restore attempts (%d) reached. Manual intervention required.",
            cfg->max_restore_attempts);
        return -1;
    }

    set_restore_lock(cfg);
    increment_restore_count(cfg);

    int ret;
    if (cfg->snap_mode == VSG_MODE_QMP)
        ret = restore_qmp_mode(cfg);
    else
        ret = restore_qm_mode(cfg);

    if (ret == 0) {
        /* Success: update state and reset counter */
        char local_node[128];
        pve_local_node(local_node, sizeof(local_node));
        ha_save_state(cfg, local_node);
        reset_restore_count(cfg);
        vsg_log(VSG_LOG_INFO, "Restore completed successfully");
    } else {
        vsg_log(VSG_LOG_ERROR, "Restore failed (attempt %d/%d)",
                attempts + 1, cfg->max_restore_attempts);
    }

    return ret;
}
