#!/usr/bin/env bash
set -euo pipefail
# instance, verified binary, release SHA256, private env file, existing dedicated user.
# Existing passive services remain running.
instance="$1"
binary="$2"
expected_sha="$3"
env_file="$4"
run_user="$5"
[[ "$EUID" = 0 && "$instance" =~ ^[a-zA-Z0-9_-]{1,64}$ && "$expected_sha" =~ ^[a-f0-9]{64}$ ]]
[[ "$binary" =~ ^/[a-zA-Z0-9_./-]+$ && "$env_file" =~ ^/[a-zA-Z0-9_./-]+$ && "$run_user" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]
[[ "$binary" != *[$'\n\r\t %\\']* && "$env_file" != *[$'\n\r\t %\\']* ]]
test -f "$binary" && test -x "$binary" && test ! -L "$binary"
test -f "$env_file" && test ! -L "$env_file"
test "$(stat -c %u "$env_file")" = 0
test "$(stat -c %a "$env_file")" = 600
test "$(stat -c %u "$binary")" = 0
test "$(( 8#$(stat -c %a "$binary") & 022 ))" = 0
test "$(sha256sum "$binary" | cut -d' ' -f1)" = "$expected_sha"
test "$(id -u "$run_user")" != 0
# Root can traverse a private directory even when the systemd service user cannot.
runuser -u "$run_user" -- test -r "$binary"
runuser -u "$run_user" -- test -x "$binary"
unit="/etc/systemd/system/inoc-node-active-$instance.service"
test ! -e "$unit" || { echo 'Existing unit requires a reviewed update.' >&2; exit 1; }
if [[ "$#" -ge 6 && "$6" = --check ]]; then
    echo 'INSTALL_ACTIVE_PREFLIGHT_OK'
    exit 0
fi
cat > "$unit" <<EOF
[Unit]
Description=INOCMON outbound remote execution $instance
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=$run_user
EnvironmentFile=$env_file
ExecStart=$binary --active-execution
Restart=on-failure
RestartSec=10
TimeoutStopSec=330
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
MemoryMax=256M
TasksMax=64
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now "inoc-node-active-$instance.service"
systemctl is-active --quiet "inoc-node-active-$instance.service"
pid="$(systemctl show --property=MainPID --value "inoc-node-active-$instance.service")"
[[ "$pid" =~ ^[1-9][0-9]*$ ]]
for attempt in 1 2 3; do
    sleep 1
    systemctl is-active --quiet "inoc-node-active-$instance.service"
    test "$(systemctl show --property=MainPID --value "inoc-node-active-$instance.service")" = "$pid"
    test "$(systemctl show --property=NRestarts --value "inoc-node-active-$instance.service")" = 0
done
printf 'INSTALL_ACTIVE_LOCAL_READY pid=%s\n' "$pid"
# Central admission still requires a fresh signed heartbeat; local readiness is not end-to-end proof.
