
OVMF_VARS_ORIG="/usr/share/OVMF/OVMF_VARS_4M.fd"

if [ -z "$OSMHOST" ]; then OSMHOST=osmhostv; fi
if [ -z "$DEBDISK" ]; then DEBDISK=$OSMHOST.qcow; fi
if [ -z "$DEBBIOSMEM" ]; then DEBBIOSMEM=$OSMHOST.ovmf_vars.fd; fi
if [ -z "$PRESEED" ]; then PRESEED=preseed.cfg; fi
