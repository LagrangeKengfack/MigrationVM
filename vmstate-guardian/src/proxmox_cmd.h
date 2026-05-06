#ifndef VSG_PROXMOX_CMD_H
#define VSG_PROXMOX_CMD_H

#define CMD_OUTPUT_SIZE 4096

/* Execute a shell command and capture stdout. Returns exit code. */
int  cmd_exec(const char *cmd, char *output, int output_size);

/* VM operations */
int  pve_vm_status(int vmid, char *status, int len);
int  pve_vm_node(int vmid, char *node, int len);
int  pve_vm_start(int vmid);
int  pve_vm_stop(int vmid);
int  pve_vm_shutdown(int vmid);

/* Snapshot operations (qm mode) */
int  pve_snapshot_create(int vmid, const char *name, int vmstate);
int  pve_snapshot_delete(int vmid, const char *name);
int  pve_snapshot_rollback(int vmid, const char *name);
int  pve_snapshot_list(int vmid, char *output, int output_size);

/* HA operations */
int  pve_ha_status(char *output, int output_size);

/* VM config manipulation */
int  pve_vm_set_args(int vmid, const char *args);
int  pve_vm_delete_args(int vmid);

/* Local hostname */
int  pve_local_node(char *node, int len);

#endif
