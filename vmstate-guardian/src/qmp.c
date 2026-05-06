#include "qmp.h"
#include "logger.h"
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <errno.h>
#include <time.h>
#include <poll.h>

static int qmp_read_response(qmp_conn_t *conn, int timeout_ms)
{
    struct pollfd pfd = { .fd = conn->fd, .events = POLLIN };
    int ret = poll(&pfd, 1, timeout_ms);
    if (ret <= 0) return -1;

    memset(conn->buf, 0, QMP_BUF_SIZE);
    ssize_t n = read(conn->fd, conn->buf, QMP_BUF_SIZE - 1);
    if (n <= 0) return -1;
    conn->buf[n] = '\0';
    return 0;
}

static int qmp_send(qmp_conn_t *conn, const char *data)
{
    size_t len = strlen(data);
    ssize_t w = write(conn->fd, data, len);
    return (w == (ssize_t)len) ? 0 : -1;
}

int qmp_connect(qmp_conn_t *conn, const char *socket_path)
{
    conn->fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (conn->fd < 0) {
        vsg_log(VSG_LOG_ERROR, "QMP: socket() failed: %s", strerror(errno));
        return -1;
    }

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    snprintf(addr.sun_path, sizeof(addr.sun_path), "%s", socket_path);

    if (connect(conn->fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        vsg_log(VSG_LOG_ERROR, "QMP: connect(%s) failed: %s", socket_path, strerror(errno));
        close(conn->fd);
        conn->fd = -1;
        return -1;
    }

    /* Read the QMP greeting */
    if (qmp_read_response(conn, 5000) < 0) {
        vsg_log(VSG_LOG_ERROR, "QMP: no greeting received");
        close(conn->fd);
        conn->fd = -1;
        return -1;
    }
    vsg_log(VSG_LOG_DEBUG, "QMP greeting: %s", conn->buf);

    /* Negotiate capabilities */
    if (qmp_send(conn, "{\"execute\":\"qmp_capabilities\"}\n") < 0) {
        vsg_log(VSG_LOG_ERROR, "QMP: failed to send qmp_capabilities");
        close(conn->fd);
        conn->fd = -1;
        return -1;
    }

    if (qmp_read_response(conn, 5000) < 0 || strstr(conn->buf, "\"return\"") == NULL) {
        vsg_log(VSG_LOG_ERROR, "QMP: qmp_capabilities failed: %s", conn->buf);
        close(conn->fd);
        conn->fd = -1;
        return -1;
    }

    vsg_log(VSG_LOG_INFO, "QMP: connected to %s", socket_path);
    return 0;
}

void qmp_disconnect(qmp_conn_t *conn)
{
    if (conn->fd >= 0) {
        close(conn->fd);
        conn->fd = -1;
    }
}

int qmp_execute(qmp_conn_t *conn, const char *cmd_json)
{
    char cmd[QMP_BUF_SIZE];
    snprintf(cmd, sizeof(cmd), "%s\n", cmd_json);

    if (qmp_send(conn, cmd) < 0) {
        vsg_log(VSG_LOG_ERROR, "QMP: send failed");
        return -1;
    }

    if (qmp_read_response(conn, 10000) < 0) {
        vsg_log(VSG_LOG_ERROR, "QMP: no response");
        return -1;
    }

    if (strstr(conn->buf, "\"error\"")) {
        vsg_log(VSG_LOG_ERROR, "QMP error: %s", conn->buf);
        return -1;
    }

    return 0;
}

int qmp_cont(qmp_conn_t *conn)
{
    return qmp_execute(conn, "{\"execute\":\"cont\"}");
}

int qmp_stop(qmp_conn_t *conn)
{
    return qmp_execute(conn, "{\"execute\":\"stop\"}");
}

int qmp_query_migrate_status(qmp_conn_t *conn, char *status, int status_len)
{
    if (qmp_execute(conn, "{\"execute\":\"query-migrate\"}") < 0)
        return -1;

    /* Extract "status":"..." from response */
    const char *p = strstr(conn->buf, "\"status\"");
    if (!p) {
        snprintf(status, status_len, "unknown");
        return -1;
    }
    p = strchr(p + 8, '"');
    if (!p) return -1;
    p++; /* skip opening quote */
    const char *end = strchr(p, '"');
    if (!end) return -1;

    int len = (int)(end - p);
    if (len >= status_len) len = status_len - 1;
    strncpy(status, p, len);
    status[len] = '\0';
    return 0;
}

int qmp_migrate_to_file(qmp_conn_t *conn, const char *dest_path, int timeout_sec)
{
    char cmd[QMP_BUF_SIZE];
    snprintf(cmd, sizeof(cmd),
        "{\"execute\":\"migrate\",\"arguments\":"
        "{\"uri\":\"exec:cat > %s\"}}",
        dest_path);

    vsg_log(VSG_LOG_INFO, "QMP: starting pre-copy migration to %s", dest_path);

    if (qmp_execute(conn, cmd) < 0) {
        vsg_log(VSG_LOG_ERROR, "QMP: migrate command failed");
        return -1;
    }

    /* Poll migration status until completed or failed */
    time_t start = time(NULL);
    char status[64];

    while (1) {
        sleep(1);

        if (time(NULL) - start > timeout_sec) {
            vsg_log(VSG_LOG_ERROR, "QMP: migration timeout after %ds", timeout_sec);
            qmp_execute(conn, "{\"execute\":\"migrate_cancel\"}");
            return -1;
        }

        if (qmp_query_migrate_status(conn, status, sizeof(status)) < 0) {
            vsg_log(VSG_LOG_WARN, "QMP: cannot query migration status");
            continue;
        }

        vsg_log(VSG_LOG_DEBUG, "QMP: migration status: %s", status);

        if (strcmp(status, "completed") == 0) {
            vsg_log(VSG_LOG_INFO, "QMP: migration completed, resuming VM");
            qmp_cont(conn);
            return 0;
        }
        if (strcmp(status, "failed") == 0 || strcmp(status, "cancelled") == 0) {
            vsg_log(VSG_LOG_ERROR, "QMP: migration %s", status);
            qmp_cont(conn); /* resume VM even on failure */
            return -1;
        }
    }
}
