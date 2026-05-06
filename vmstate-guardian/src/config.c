#include "config.h"
#include "logger.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

void vsg_config_set_defaults(vsg_config_t *cfg)
{
    memset(cfg, 0, sizeof(*cfg));
    cfg->vmid               = 101;
    cfg->snapshot_interval   = 60;
    cfg->monitor_interval    = 5;
    cfg->max_restore_attempts = 3;
    cfg->restore_cooldown    = 120;
    cfg->migration_timeout   = 300;
    cfg->snap_mode           = VSG_MODE_QMP;
    cfg->foreground          = false;
    snprintf(cfg->state_dir,   VSG_MAX_PATH, "/var/lib/vmstate-guardian");
    snprintf(cfg->log_file,    VSG_MAX_PATH, "/var/log/vmstate-guardian.log");
    snprintf(cfg->vmstate_path,VSG_MAX_PATH, "/var/lib/vmstate-guardian/vmstate");
    snprintf(cfg->qmp_socket,  VSG_MAX_PATH, "/var/run/qemu-server/%d.qmp", cfg->vmid);
}

static char *trim(char *s)
{
    while (isspace((unsigned char)*s)) s++;
    char *end = s + strlen(s) - 1;
    while (end > s && isspace((unsigned char)*end)) *end-- = '\0';
    return s;
}

static void apply_kv(vsg_config_t *cfg, const char *key, const char *val)
{
    if (strcmp(key, "vmid") == 0) {
        cfg->vmid = atoi(val);
        snprintf(cfg->qmp_socket, VSG_MAX_PATH, "/var/run/qemu-server/%d.qmp", cfg->vmid);
    } else if (strcmp(key, "snapshot_interval") == 0) {
        cfg->snapshot_interval = atoi(val);
    } else if (strcmp(key, "monitor_interval") == 0) {
        cfg->monitor_interval = atoi(val);
    } else if (strcmp(key, "max_restore_attempts") == 0) {
        cfg->max_restore_attempts = atoi(val);
    } else if (strcmp(key, "restore_cooldown") == 0) {
        cfg->restore_cooldown = atoi(val);
    } else if (strcmp(key, "migration_timeout") == 0) {
        cfg->migration_timeout = atoi(val);
    } else if (strcmp(key, "mode") == 0) {
        if (strcmp(val, "qmp") == 0)
            cfg->snap_mode = VSG_MODE_QMP;
        else if (strcmp(val, "qm") == 0)
            cfg->snap_mode = VSG_MODE_QM;
    } else if (strcmp(key, "state_dir") == 0) {
        snprintf(cfg->state_dir, VSG_MAX_PATH, "%s", val);
    } else if (strcmp(key, "log_file") == 0) {
        snprintf(cfg->log_file, VSG_MAX_PATH, "%s", val);
    } else if (strcmp(key, "vmstate_path") == 0) {
        snprintf(cfg->vmstate_path, VSG_MAX_PATH, "%s", val);
    } else if (strcmp(key, "qmp_socket") == 0) {
        snprintf(cfg->qmp_socket, VSG_MAX_PATH, "%s", val);
    } else if (strcmp(key, "foreground") == 0) {
        cfg->foreground = (strcmp(val, "true") == 0 || strcmp(val, "1") == 0);
    }
}

int vsg_config_load(vsg_config_t *cfg, const char *path)
{
    FILE *fp = fopen(path, "r");
    if (!fp) return -1;

    char line[VSG_MAX_LINE];
    while (fgets(line, sizeof(line), fp)) {
        char *l = trim(line);
        if (*l == '#' || *l == '\0' || *l == '[') continue;

        char *eq = strchr(l, '=');
        if (!eq) continue;

        *eq = '\0';
        char *key = trim(l);
        char *val = trim(eq + 1);
        apply_kv(cfg, key, val);
    }

    fclose(fp);
    return 0;
}

void vsg_config_dump(const vsg_config_t *cfg)
{
    vsg_log(VSG_LOG_INFO, "Config: vmid=%d interval=%ds mode=%s",
            cfg->vmid, cfg->snapshot_interval,
            cfg->snap_mode == VSG_MODE_QMP ? "qmp" : "qm");
    vsg_log(VSG_LOG_INFO, "Config: state_dir=%s vmstate_path=%s",
            cfg->state_dir, cfg->vmstate_path);
    vsg_log(VSG_LOG_INFO, "Config: monitor_interval=%ds max_restore=%d cooldown=%ds",
            cfg->monitor_interval, cfg->max_restore_attempts, cfg->restore_cooldown);
}
