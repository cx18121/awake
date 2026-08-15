#!/bin/zsh

set -euo pipefail

project_dir="${0:A:h:h}"
helper_source="$project_dir/.build/release/AgentAwakeHelper"
helper_target="/Library/PrivilegedHelperTools/dev.herdr.AgentAwakeHelper"
daemon_target="/Library/LaunchDaemons/dev.herdr.AgentAwakeHelper.plist"
sudoers_target="/etc/sudoers.d/agent-awake"
account_name="$(id -un)"
local_stage="$(mktemp -d)"
helper_stage="$local_stage/AgentAwakeHelper"
daemon_stage="$local_stage/dev.herdr.AgentAwakeHelper.plist"
sudoers_stage="$local_stage/agent-awake"
helper_new="$helper_target.agent-awake-new"
daemon_new="$daemon_target.agent-awake-new"
sudoers_new="$sudoers_target.agent-awake-new"
helper_backup="$helper_target.agent-awake-backup"
daemon_backup="$daemon_target.agent-awake-backup"
sudoers_backup="$sudoers_target.agent-awake-backup"
system_stage_created=false

cleanup() {
    rm -rf "$local_stage"
    if $system_stage_created; then
        sudo rm -f "$helper_new" "$daemon_new" "$sudoers_new" 2>/dev/null || true
    fi
}

trap cleanup EXIT

if [[ ! -x "$helper_source" ]]; then
    echo "Build Awake before installing its helper."
    exit 1
fi

if [[ ! "$account_name" =~ '^[a-zA-Z0-9._-]+$' ]]; then
    echo "The current account name cannot be written safely to sudoers."
    exit 1
fi

sudoers_line="$account_name ALL=(root) NOPASSWD: $helper_target start *, $helper_target display *, $helper_target stop, $helper_target status"
cp "$helper_source" "$helper_stage"
cp "$project_dir/Resources/dev.herdr.AgentAwakeHelper.plist" "$daemon_stage"
printf '%s\n' "$sudoers_line" > "$sudoers_stage"
chmod 755 "$helper_stage"
chmod 644 "$daemon_stage"
chmod 440 "$sudoers_stage"

codesign --verify --strict "$helper_stage"
plutil -lint "$daemon_stage"
sudo -v
sudo visudo -cf "$sudoers_stage"
system_stage_created=true
sudo install -o root -g wheel -m 755 "$helper_stage" "$helper_new"
sudo install -o root -g wheel -m 644 "$daemon_stage" "$daemon_new"
sudo install -o root -g wheel -m 440 "$sudoers_stage" "$sudoers_new"
sudo visudo -cf "$sudoers_new"

helper_replaced=false
daemon_replaced=false
sudoers_replaced=false

rollback() {
    exit_code=$?
    trap - ERR
    set +e
    sudo launchctl bootout system/dev.herdr.AgentAwakeHelper 2>/dev/null
    if $helper_replaced; then sudo rm -f "$helper_target"; fi
    if $daemon_replaced; then sudo rm -f "$daemon_target"; fi
    if $sudoers_replaced; then sudo rm -f "$sudoers_target"; fi
    if sudo test -e "$helper_backup"; then sudo mv "$helper_backup" "$helper_target"; fi
    if sudo test -e "$daemon_backup"; then sudo mv "$daemon_backup" "$daemon_target"; fi
    if sudo test -e "$sudoers_backup"; then sudo mv "$sudoers_backup" "$sudoers_target"; fi
    if sudo test -e "$daemon_target"; then
        sudo launchctl bootstrap system "$daemon_target" 2>/dev/null
    fi
    echo "Awake helper installation failed and the previous installation was restored."
    exit "$exit_code"
}

trap rollback ERR

sudo launchctl bootout system/dev.herdr.AgentAwakeHelper 2>/dev/null || true
sudo rm -f "$helper_backup" "$daemon_backup" "$sudoers_backup"
if sudo test -e "$helper_target"; then sudo mv "$helper_target" "$helper_backup"; fi
if sudo test -e "$daemon_target"; then sudo mv "$daemon_target" "$daemon_backup"; fi
if sudo test -e "$sudoers_target"; then sudo mv "$sudoers_target" "$sudoers_backup"; fi

sudo mv "$helper_new" "$helper_target"
helper_replaced=true
sudo mv "$daemon_new" "$daemon_target"
daemon_replaced=true
sudo mv "$sudoers_new" "$sudoers_target"
sudoers_replaced=true
sudo launchctl bootstrap system "$daemon_target"

trap - ERR
sudo rm -f "$helper_backup" "$daemon_backup" "$sudoers_backup"

echo "Installed and started the Awake helper."
