#!/bin/zsh

set -euo pipefail

helper_target="/Library/PrivilegedHelperTools/dev.herdr.AgentAwakeHelper"

if [[ -x "$helper_target" ]]; then
    sudo "$helper_target" stop
fi

if /usr/bin/pmset -g | /usr/bin/grep -Eq 'SleepDisabled[[:space:]]+1'; then
    echo "Normal sleep is still disabled. The helper was not removed so you can recover safely."
    exit 1
fi

sudo launchctl bootout system/dev.herdr.AgentAwakeHelper 2>/dev/null || true
sudo rm -f \
    /Library/LaunchDaemons/dev.herdr.AgentAwakeHelper.plist \
    /Library/PrivilegedHelperTools/dev.herdr.AgentAwakeHelper \
    /etc/sudoers.d/agent-awake \
    /var/db/agent-awake/keep-display-on
sudo rmdir /var/db/agent-awake 2>/dev/null || true
echo "Removed Awake and restored normal sleep."
