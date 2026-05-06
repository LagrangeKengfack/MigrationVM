#ifndef VSG_QMP_H
#define VSG_QMP_H

#include <stdbool.h>

#define QMP_BUF_SIZE 8192

typedef struct {
    int  fd;
    char buf[QMP_BUF_SIZE];
} qmp_conn_t;

/* Connect to QMP socket, negotiate capabilities. Returns 0 on success. */
int  qmp_connect(qmp_conn_t *conn, const char *socket_path);
void qmp_disconnect(qmp_conn_t *conn);

/* Send a QMP command and receive the response into conn->buf. Returns 0 on success. */
int  qmp_execute(qmp_conn_t *conn, const char *cmd_json);

/* High-level helpers */
int  qmp_migrate_to_file(qmp_conn_t *conn, const char *dest_path, int timeout_sec);
int  qmp_query_migrate_status(qmp_conn_t *conn, char *status, int status_len);
int  qmp_cont(qmp_conn_t *conn);
int  qmp_stop(qmp_conn_t *conn);

#endif
