#include "config.h"
#include "logger.h"
#include "ha_monitor.h"
#include "snapshot_mgr.h"
#include "restore_engine.h"
#include "proxmox_cmd.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <unistd.h>
#include <sys/stat.h>
#include <getopt.h>
#include <time.h>

static volatile int running = 1;

static void signal_handler(int sig)
{
    (void)sig;
    running = 0;
}

static void daemonize(void)
{
    pid_t pid = fork();
    if (pid < 0) exit(EXIT_FAILURE);
    if (pid > 0) exit(EXIT_SUCCESS);
    setsid();
    pid = fork();
    if (pid < 0) exit(EXIT_FAILURE);
    if (pid > 0) exit(EXIT_SUCCESS);
    umask(0);
    if (chdir("/") < 0) { /* ignore */ }
    close(STDIN_FILENO);
}

static void usage(const char *prog)
{
    fprintf(stderr,
        "Usage: %s [options]\n"
        "  -c, --config PATH   Config file (default: %s)\n"
        "  -f, --foreground    Run in foreground\n"
        "  -h, --help          Show this help\n",
        prog, VSG_CONF_DEFAULT);
}

int main(int argc, char *argv[])
{
    const char *conf_path = VSG_CONF_DEFAULT;
    int foreground = 0;

    static struct option long_opts[] = {
        {"config",     required_argument, 0, 'c'},
        {"foreground", no_argument,       0, 'f'},
        {"help",       no_argument,       0, 'h'},
        {0, 0, 0, 0}
    };

    int opt;
    while ((opt = getopt_long(argc, argv, "c:fh", long_opts, NULL)) != -1) {
        switch (opt) {
        case 'c': conf_path = optarg; break;
        case 'f': foreground = 1; break;
        case 'h': usage(argv[0]); return 0;
        default:  usage(argv[0]); return 1;
        }
    }

    /* Load config */
    vsg_config_t cfg;
    vsg_config_set_defaults(&cfg);
    if (vsg_config_load(&cfg, conf_path) < 0) {
        fprintf(stderr, "Warning: cannot load config %s, using defaults\n", conf_path);
    }
    if (foreground) cfg.foreground = true;

    /* Create state directory */
    char mkdir_cmd[VSG_MAX_PATH + 16];
    snprintf(mkdir_cmd, sizeof(mkdir_cmd), "mkdir -p %s", cfg.state_dir);
    (void)!system(mkdir_cmd);

    /* Init logging */
    if (vsg_log_init(cfg.log_file) < 0) {
        fprintf(stderr, "Cannot init logging\n");
        return 1;
    }

    vsg_log(VSG_LOG_INFO, "=== vmstate-guardian starting ===");
    vsg_config_dump(&cfg);

    /* Daemonize */
    if (!cfg.foreground) {
        vsg_log(VSG_LOG_INFO, "Daemonizing...");
        daemonize();
    }

    /* Signal handling */
    signal(SIGTERM, signal_handler);
    signal(SIGINT, signal_handler);

    /* Write PID file */
    FILE *pidf = fopen("/var/run/vmstate-guardian.pid", "w");
    if (pidf) {
        fprintf(pidf, "%d\n", getpid());
        fclose(pidf);
    }

    vsg_log(VSG_LOG_INFO, "Daemon running (PID %d)", getpid());

    time_t last_snapshot = 0;

    /* Main loop */
    while (running) {
        /* Check if VM is managed by HA and running on this node */
        if (!ha_vm_is_local(&cfg)) {
            vsg_log(VSG_LOG_DEBUG, "VM %d is not on this node, sleeping %ds",
                    cfg.vmid, cfg.monitor_interval);
            sleep(cfg.monitor_interval);
            continue;
        }

        /* Check for HA failover */
        if (ha_detect_failover(&cfg)) {
            vsg_log(VSG_LOG_WARN, "HA failover detected — initiating restore");
            if (restore_vm_state(&cfg) == 0) {
                vsg_log(VSG_LOG_INFO, "Restore successful, resuming normal operation");
            } else {
                vsg_log(VSG_LOG_ERROR, "Restore failed, VM running in fresh state");
                /* Save current node to avoid triggering again */
                char node[128];
                pve_local_node(node, sizeof(node));
                ha_save_state(&cfg, node);
            }
            last_snapshot = 0; /* Reset snapshot timer */
            continue;
        }

        /* Periodic snapshot */
        time_t now = time(NULL);
        if (now - last_snapshot >= cfg.snapshot_interval) {
            char vm_status[64];
            if (pve_vm_status(cfg.vmid, vm_status, sizeof(vm_status)) == 0 &&
                strcmp(vm_status, "running") == 0) {
                vsg_log(VSG_LOG_INFO, "Starting snapshot cycle for VM %d", cfg.vmid);
                if (snap_cycle(&cfg) == 0) {
                    last_snapshot = time(NULL);
                    vsg_log(VSG_LOG_INFO, "Snapshot cycle completed");
                } else {
                    vsg_log(VSG_LOG_ERROR, "Snapshot cycle failed");
                }
            }
        }

        sleep(cfg.monitor_interval);
    }

    vsg_log(VSG_LOG_INFO, "=== vmstate-guardian stopping ===");
    unlink("/var/run/vmstate-guardian.pid");
    vsg_log_close();
    return 0;
}
