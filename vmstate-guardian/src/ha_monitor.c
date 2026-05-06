#include "ha_monitor.h"
#include "proxmox_cmd.h"
#include "logger.h"
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int ha_save_state(const vsg_config_t *cfg, const char *node)
{
    char path[VSG_MAX_PATH + 64];
    snprintf(path, sizeof(path), "%s/last_node", cfg->state_dir);

    FILE *fp = fopen(path, "w");
    if (!fp) {
        vsg_log(VSG_LOG_ERROR, "Cannot write state file %s", path);
        return -1;
    }
    fprintf(fp, "%s\n", node);
    fclose(fp);
    vsg_log(VSG_LOG_DEBUG, "Saved last node: %s", node);
    return 0;
}

int ha_load_state(const vsg_config_t *cfg, char *node, int len)
{
    char path[VSG_MAX_PATH + 64];
    snprintf(path, sizeof(path), "%s/last_node", cfg->state_dir);

    FILE *fp = fopen(path, "r");
    if (!fp) return -1;

    if (!fgets(node, len, fp)) {
        fclose(fp);
        return -1;
    }
    fclose(fp);

    /* Trim newline */
    char *nl = strchr(node, '\n');
    if (nl) *nl = '\0';
    return 0;
}

bool ha_vm_is_local(const vsg_config_t *cfg)
{
    char vm_node[128], local_node[128];

    if (pve_local_node(local_node, sizeof(local_node)) != 0) return false;
    if (pve_vm_node(cfg->vmid, vm_node, sizeof(vm_node)) != 0) return false;

    return (strcmp(vm_node, local_node) == 0);
}

bool ha_detect_failover(const vsg_config_t *cfg)
{
    char local_node[128], vm_node[128], last_node[128];

    if (pve_local_node(local_node, sizeof(local_node)) != 0) {
        vsg_log(VSG_LOG_ERROR, "Cannot determine local node name");
        return false;
    }

    if (pve_vm_node(cfg->vmid, vm_node, sizeof(vm_node)) != 0) {
        vsg_log(VSG_LOG_DEBUG, "Cannot determine VM %d node (VM may be stopped)", cfg->vmid);
        return false;
    }

    /* VM is not on this node */
    if (strcmp(vm_node, local_node) != 0) return false;

    /* VM is on this node — check if the node changed */
    if (ha_load_state(cfg, last_node, sizeof(last_node)) != 0) {
        /* No previous state: first run, save current and continue */
        vsg_log(VSG_LOG_INFO, "First run on node %s, saving state", local_node);
        ha_save_state(cfg, local_node);
        return false;
    }

    if (strcmp(last_node, local_node) == 0) {
        /* Same node as before: no failover */
        return false;
    }

    /* Node changed! This is a failover event. */
    vsg_log(VSG_LOG_WARN, "FAILOVER DETECTED: VM %d moved from %s to %s",
            cfg->vmid, last_node, local_node);
    return true;
}
