#!/bin/sh

STATE=/run/abroot/userdata/.abroot/boot-state.json
TMP=/run/abroot/userdata/.abroot/tmp.json
MAX_BOOT_ATTEMPTS=1

# Defined functions

# Reads $subvol, sets $subvol to the other slot
switch_slot() {
    if [ "$subvol" != "A" ]; then
        subvol="A"
    else
        subvol="B"
    fi
}

# Write to json file at given parameter, using $STATE and $TMP as the source and destination
json_write() {
    jq "$1" "$STATE" > "$TMP" && mv "$TMP" "$STATE"
}

# Checks if the currently selected $subvol is marked unbootable in $STATE, and if so switches to the other slot
check_unbootable() {
    unbootable=$(jq -r ".rootfs$subvol.unbootable" "$STATE")
    if [ "$unbootable" = "true" ]; then
        warn "abroot: selected btrfs subvolume $subvol is marked unbootable, switching to the other subvolume"
        switch_slot
        return 1
    fi
    return 0
}

# Checks if the currently selected $subvol is marked recently_loaded in $STATE, and if so checks boot_attempts and marks unbootable and switches if boot_attempts > MAX_BOOT_ATTEMPTS
check_recently_loaded() {
    recently_loaded=$(jq -r ".rootfs$subvol.recently_loaded" "$STATE")
    if [ "$recently_loaded" = "true" ]; then
        echo "abroot: selected btrfs subvolume $subvol was recently loaded, checking boot attempts"
        boot_attempts=$(jq -r ".rootfs$subvol.boot_attempts" "$STATE")
        if [ "$boot_attempts" -ge "$MAX_BOOT_ATTEMPTS" ]; then
            warn "abroot: selected btrfs subvolume $subvol has $boot_attempts boot attempts, marking unbootable and switching back to the other subvolume"

            json_write ".rootfs$subvol.unbootable = true"

            switch_slot
            return 1
        fi
    fi
    return 0
}


mkdir -p /run/abroot/userdata
trap 'umount /run/abroot/userdata 2>/dev/null' EXIT
mount -t btrfs -o rw,subvol=userdata /dev/sda31 /run/abroot/userdata

subvol="null"
unbootable="null"
recently_loaded="null"
boot_attempts="null"


subvol=$(jq -r '.active_root' "$STATE")

if [ "$subvol" = "null" ]; then
    warn "abroot: no active_root found in boot-state.json, defaulting to root subvolume"
    subvol="A"
fi

if ! check_unbootable; then
    ! check_unbootable && warn "abroot: both btrfs subvolumes are marked unbootable, attempting boot with originally selected subvolume $subvol"
fi

if ! check_recently_loaded; then
    ! check_recently_loaded && warn "abroot: both btrfs subvolumes have been recently loaded with too many boot attempts, attempting boot with originally selected subvolume $subvol"
fi

if [ "$recently_loaded" = "true" ]; then
    echo "abroot: incrementing boot attempts for btrfs subvolume $subvol"
    json_write ".rootfs$subvol.boot_attempts += 1"
fi

json_write ".active_root = \"$subvol\""

sync
echo "rootfs$subvol" > /run/abroot.subvol

info "abroot: selected btrfs subvolume $subvol"
