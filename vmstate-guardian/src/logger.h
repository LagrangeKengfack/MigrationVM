#ifndef VSG_LOGGER_H
#define VSG_LOGGER_H

typedef enum {
    VSG_LOG_DEBUG,
    VSG_LOG_INFO,
    VSG_LOG_WARN,
    VSG_LOG_ERROR
} vsg_log_level_t;

int  vsg_log_init(const char *log_file);
void vsg_log_close(void);
void vsg_log(vsg_log_level_t level, const char *fmt, ...);

#endif
