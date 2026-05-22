#!/bin/sh

WATCHDOG="/dev/watchdog1"
DEBUG_LOG="/run/abroot/userdata/.abroot/watchdog-debug.log"

klog() {
    echo "abroot-watchdog-test: $*" > /dev/kmsg

    if [ -d /run/abroot/userdata/.abroot ]; then
        echo "abroot-watchdog-test: $*" >> "$DEBUG_LOG"
        sync
    fi
}

klog "pre-pivot hook reached"

if [ ! -e "$WATCHDOG" ]; then
    klog "$WATCHDOG not found, skipping watchdog test"
    exit 0
fi

klog "found $WATCHDOG"
klog "arming watchdog once without feeding"

if printf '\0' > "$WATCHDOG"; then
    klog "watchdog armed; no feeder started"
else
    klog "failed to arm watchdog"
    exit 0
fi

klog "continuing boot; expected reboot in about 30 seconds"
exit 0