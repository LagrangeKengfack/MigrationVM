CC      = gcc
CFLAGS  = -Wall -Wextra -O2 -std=c11 -D_GNU_SOURCE
LDFLAGS =

SRCDIR  = src
SRCS    = $(SRCDIR)/main.c \
          $(SRCDIR)/config.c \
          $(SRCDIR)/logger.c \
          $(SRCDIR)/qmp.c \
          $(SRCDIR)/proxmox_cmd.c \
          $(SRCDIR)/snapshot_mgr.c \
          $(SRCDIR)/ha_monitor.c \
          $(SRCDIR)/restore_engine.c

OBJS    = $(SRCS:.c=.o)
TARGET  = vmstate-guardian

.PHONY: all clean install

all: $(TARGET)

$(TARGET): $(OBJS)
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)

$(SRCDIR)/%.o: $(SRCDIR)/%.c
	$(CC) $(CFLAGS) -c -o $@ $<

clean:
	rm -f $(OBJS) $(TARGET)

install: $(TARGET)
	install -m 755 $(TARGET) /usr/local/sbin/
	install -d /etc/vmstate-guardian
	install -m 644 conf/vmstate-guardian.conf /etc/vmstate-guardian/
	install -d /var/lib/vmstate-guardian
	install -m 644 systemd/vmstate-guardian.service /etc/systemd/system/
	systemctl daemon-reload
