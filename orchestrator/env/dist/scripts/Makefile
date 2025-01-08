DEVTANK_DIR = "/opt/devtank"
SYSTEMD_DIR = "/etc/systemd/system"
FILES = sql_backup.bash

default: all

run:
	@/usr/bin/env bash /opt/devtank/sql_backup.bash

all: $(FILES)

install-file-%: %
	@echo install $* /tmp/

install-file-sql_backup.bash: sql_backup.bash
	install -d -m 755 $(DEVTANK_DIR)
	install -m 755 $< -t $(DEVTANK_DIR)

setup-cron:
	( crontab -l | \
	  sed -n '/\/opt\/devtank\/sql_backup.bashxxx/{q1}' \
	  && echo "0 2 * * * /usr/bin/env bash /opt/devtank/sql_backup.bash" \
	) | crontab -

install: $(foreach f, $(FILES), install-file-$(f) ) setup-cron
