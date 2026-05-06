#include "logger.h"
#include <stdio.h>
#include <stdarg.h>
#include <time.h>
#include <syslog.h>
#include <string.h>

static FILE *log_fp = NULL;

static const char *level_str[] = { "DEBUG", "INFO", "WARN", "ERROR" };
static int syslog_prio[] = { LOG_DEBUG, LOG_INFO, LOG_WARNING, LOG_ERR };

int vsg_log_init(const char *log_file)
{
    openlog("vmstate-guardian", LOG_PID | LOG_NDELAY, LOG_DAEMON);
    if (log_file && log_file[0]) {
        log_fp = fopen(log_file, "a");
        if (!log_fp) {
            syslog(LOG_ERR, "Cannot open log file: %s", log_file);
            return -1;
        }
    }
    return 0;
}

void vsg_log_close(void)
{
    if (log_fp) { fclose(log_fp); log_fp = NULL; }
    closelog();
}

void vsg_log(vsg_log_level_t level, const char *fmt, ...)
{
    char msg[2048];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(msg, sizeof(msg), fmt, ap);
    va_end(ap);

    syslog(syslog_prio[level], "%s", msg);

    time_t now = time(NULL);
    struct tm tm;
    localtime_r(&now, &tm);
    char ts[32];
    strftime(ts, sizeof(ts), "%Y-%m-%d %H:%M:%S", &tm);

    FILE *out = log_fp ? log_fp : stderr;
    fprintf(out, "[%s] [%s] %s\n", ts, level_str[level], msg);
    fflush(out);
}
