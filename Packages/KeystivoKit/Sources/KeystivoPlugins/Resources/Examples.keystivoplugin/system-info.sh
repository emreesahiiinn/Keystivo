#!/bin/zsh
# "text" mode: whatever is printed to stdout is shown in Keystivo.
echo "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
echo "$(uname -m) · $(sysctl -n hw.ncpu) cores · $(( $(sysctl -n hw.memsize) / 1073741824 )) GB RAM"
echo "Uptime: $(uptime | sed -E 's/.*up ([^,]*),.*/\1/')"
df -h / | awk 'NR==2 { print "Disk: " $3 " used of " $2 " (" $5 ")" }'
