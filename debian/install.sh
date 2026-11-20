#!/bin/bash
# install.sh - install the r9700_tune_v2 port on the Debian 13 node.
#
#   ./install.sh            build + install module, scripts, units, config.
#                           Enables nothing and loads nothing: run
#                           `r9700-tune-apply --dry-run` (Stage A) yourself.
#   ./install.sh --enable   after Stage D: install the Wants= drop-ins on the
#                           two existing units and enable the unit + timer, so
#                           the profile is applied at boot.
set -euo pipefail

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
HERE=$(dirname "$(readlink -f "$0")")

if [ "${1:-}" = --enable ]; then
    # The drop-ins make the existing units pull in amd-sclk-cap.service, which
    # loads the module - so they are only installed once the stages are done.
    for u in amd-power-tune amd-fan-tune; do
        install -d "/etc/systemd/system/$u.service.d"
        install -m 0644 "$HERE/dropins/r9700-sclk-cap.conf" "/etc/systemd/system/$u.service.d/"
    done
    systemctl daemon-reload
    systemctl enable amd-sclk-cap.service amd-sclk-cap.timer
    echo "Enabled. Start now with: systemctl start amd-sclk-cap.service amd-sclk-cap.timer"
    exit 0
fi
VER=$(sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' "$HERE/dkms.conf")
NAME=r9700_tune_v2
LIB=/usr/local/lib/r9700-tune

# ---- module via DKMS ----
if dkms status -m "$NAME" -v "$VER" | grep -q .; then
    dkms remove -m "$NAME" -v "$VER" --all
fi
rm -rf "/usr/src/$NAME-$VER"
install -d "/usr/src/$NAME-$VER"
install -m 0644 "$HERE/r9700_tune_v2.c" "$HERE/Makefile" "$HERE/dkms.conf" "/usr/src/$NAME-$VER/"
dkms install -m "$NAME" -v "$VER"
modinfo "$NAME" | grep -E '^(filename|version|vermagic)'

# ---- scripts ----
install -d "$LIB"
install -m 0755 "$HERE/apply-debian.sh" "$HERE/gen-offsets.sh" "$LIB/"
[ -f "$HERE/../docs/PORT-PLAN-debian13-k8s.md" ] && install -m 0644 "$HERE/../docs/PORT-PLAN-debian13-k8s.md" "$LIB/"
ln -sf "$LIB/apply-debian.sh" /usr/local/sbin/r9700-tune-apply

# ---- config (never overwritten) ----
[ -e /etc/default/r9700-tune ] || install -m 0644 "$HERE/r9700-tune.default" /etc/default/r9700-tune

# ---- systemd ----
install -m 0644 "$HERE/amd-sclk-cap.service" "$HERE/amd-sclk-cap-check.service" \
    "$HERE/amd-sclk-cap.timer" /etc/systemd/system/
systemctl daemon-reload

cat <<MSG
Installed. Nothing is enabled or loaded. Next (plan §7.3, in a maintenance window):
  1. edit /etc/default/r9700-tune for the stage
  2. r9700-tune-apply --dry-run      # Stage A gate, check dmesg
  3. r9700-tune-apply --apply
  4. when Stage D is done: $HERE/install.sh --enable
MSG
