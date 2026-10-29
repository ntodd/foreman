#!/bin/sh
# Apple's hypervisor stops a VM's clock while the Mac sleeps, and NTP can
# take half an hour to notice. The control plane refuses an agent whose
# signed clock is a minute off, so the box would stay offline after every
# sleep. The emulated RTC follows the Mac's clock, so set the time from it.
set -u

rtc=$(cat /sys/class/rtc/rtc0/since_epoch 2>/dev/null) || exit 0
now=$(date +%s)
drift=$((rtc - now))
if [ "$drift" -gt 2 ] || [ "$drift" -lt -2 ]; then
  date -s "@$rtc" >/dev/null && echo "foreman-box: clock was ${drift}s off; set from the RTC"
fi
