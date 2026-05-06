#include "proxmox_cmd.h"
#include "logger.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int cmd_exec(const char *cmd, char *output, int output_size)
{
    if (output) memset(output, 0, output_size);

    FILE *fp = popen(cmd, "r");
    if (!fp) {
        vsg_log(VSG_LOG_ERROR, "popen failed: %s", cmd);
        return -1;
    }

    if (output) {
        int pos = 0;
        char line[512];
        while (fgets(line, sizeof(line), fp) && pos < output_size - 1) {
            int n = snprintf(output + pos, output_size - pos, "%s", line);
            pos += n;
        }
    }

    int ret = pclose(fp);
    return WIFEXITED(ret) ? WEXITSTATUS(ret) : -1;
}

int pve_vm_status(int vmid, char *status, int len)
{
    char cmd[256], out[CMD_OUTPUT_SIZE];
    snprintf(cmd, sizeof(cmd), "qm status %d 2>/dev/null", vmid);
    int ret = cmd_exec(cmd, out, sizeof(out));
    if (ret != 0) return -1;

    /* Output: "status: running" or "status: stopped" */
    char *p = strstr(out, "status: ");
    if (!p) return -1;
    p += 8;
    char *nl = strchr(p, '\n');
    if (nl) *nl = '\0';
    snprintf(status, len, "%s", p);
    return 0;
}

int pve_vm_node(int vmid, char *node, int len)
{
    char cmd[512], out[CMD_OUTPUT_SIZE];
    snprintf(cmd, sizeof(cmd),
        "pvesh get /cluster/resources --type vm --output-format json 2>/dev/null"
        " | grep -o '\"node\":\"[^\"]*\"' | head -1");

    /* More reliable: parse specific vmid */
    snprintf(cmd, sizeof(cmd),
        "pvesh get /cluster/resources --type vm --output-format json 2>/dev/null");
    int ret = cmd_exec(cmd, out, sizeof(out));
    if (ret != 0) return -1;

    /* Find vmid in JSON and extract its node */
    char vmid_str[32];
    snprintf(vmid_str, sizeof(vmid_str), "\"vmid\":%d", vmid);
    char *vmpos = strstr(out, vmid_str);
    if (!vmpos) {
        snprintf(vmid_str, sizeof(vmid_str), "\"vmid\": %d", vmid);
        vmpos = strstr(out, vmid_str);
    }
    if (!vmpos) return -1;

    /* Search backwards and forwards for "node":"xxx" near this vmid */
    char *search_start = vmpos - 200;
    if (search_start < out) search_start = out;
    char *search_end = vmpos + 200;

    char *npos = NULL;
    char *p = search_start;
    while (p < search_end && (p = strstr(p, "\"node\"")) != NULL) {
        npos = p;
        p++;
    }
    if (!npos) {
        npos = strstr(search_start, "\"node\"");
    }
    if (!npos) return -1;

    /* Extract value: "node":"xxx" or "node": "xxx" */
    char *colon = strchr(npos + 5, ':');
    if (!colon) return -1;
    char *quote1 = strchr(colon, '"');
    if (!quote1) return -1;
    quote1++;
    char *quote2 = strchr(quote1, '"');
    if (!quote2) return -1;

    int nlen = (int)(quote2 - quote1);
    if (nlen >= len) nlen = len - 1;
    strncpy(node, quote1, nlen);
    node[nlen] = '\0';
    return 0;
}

int pve_vm_start(int vmid)
{
    char cmd[256];
    snprintf(cmd, sizeof(cmd), "qm start %d 2>&1", vmid);
    vsg_log(VSG_LOG_INFO, "Executing: %s", cmd);
    return cmd_exec(cmd, NULL, 0);
}

int pve_vm_stop(int vmid)
{
    char cmd[256];
    snprintf(cmd, sizeof(cmd), "qm stop %d 2>&1", vmid);
    vsg_log(VSG_LOG_INFO, "Executing: %s", cmd);
    return cmd_exec(cmd, NULL, 0);
}

int pve_vm_shutdown(int vmid)
{
    char cmd[256];
    snprintf(cmd, sizeof(cmd), "qm shutdown %d --timeout 30 2>&1", vmid);
    vsg_log(VSG_LOG_INFO, "Executing: %s", cmd);
    return cmd_exec(cmd, NULL, 0);
}

int pve_snapshot_create(int vmid, const char *name, int vmstate)
{
    char cmd[512];
    snprintf(cmd, sizeof(cmd), "qm snapshot %d %s%s 2>&1",
             vmid, name, vmstate ? " --vmstate 1" : "");
    vsg_log(VSG_LOG_INFO, "Executing: %s", cmd);
    return cmd_exec(cmd, NULL, 0);
}

int pve_snapshot_delete(int vmid, const char *name)
{
    char cmd[512];
    snprintf(cmd, sizeof(cmd), "qm delsnapshot %d %s 2>&1", vmid, name);
    vsg_log(VSG_LOG_INFO, "Executing: %s", cmd);
    return cmd_exec(cmd, NULL, 0);
}

int pve_snapshot_rollback(int vmid, const char *name)
{
    char cmd[512];
    snprintf(cmd, sizeof(cmd), "qm rollback %d %s 2>&1", vmid, name);
    vsg_log(VSG_LOG_INFO, "Executing: %s", cmd);
    return cmd_exec(cmd, NULL, 0);
}

int pve_snapshot_list(int vmid, char *output, int output_size)
{
    char cmd[256];
    snprintf(cmd, sizeof(cmd), "qm listsnapshot %d 2>/dev/null", vmid);
    return cmd_exec(cmd, output, output_size);
}

int pve_ha_status(char *output, int output_size)
{
    return cmd_exec("ha-manager status 2>/dev/null", output, output_size);
}

int pve_vm_set_args(int vmid, const char *args)
{
    char cmd[1024];
    snprintf(cmd, sizeof(cmd), "qm set %d --args '%s' 2>&1", vmid, args);
    vsg_log(VSG_LOG_INFO, "Executing: %s", cmd);
    return cmd_exec(cmd, NULL, 0);
}

int pve_vm_delete_args(int vmid)
{
    char cmd[256];
    snprintf(cmd, sizeof(cmd), "qm set %d --delete args 2>&1", vmid);
    vsg_log(VSG_LOG_INFO, "Executing: %s", cmd);
    return cmd_exec(cmd, NULL, 0);
}

int pve_local_node(char *node, int len)
{
    char hostname[256];
    if (gethostname(hostname, sizeof(hostname)) != 0) return -1;
    snprintf(node, len, "%s", hostname);
    return 0;
}
