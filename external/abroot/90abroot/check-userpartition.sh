#!/bin/sh

DEVICE_SRC="/dev/sda30"
DEVICE_DST="/dev/sda31"
LABEL="rootpool"
MNT_SRC="/run/abroot/setup/src"
MNT_DST="/run/abroot/setup/dst"
SNAP_NAME=".snap_for_send"
STATE_FILE="userdata/.abroot/boot-state.json"

# Defined functions

# Checks if $DEVICE_DST is properly set up with the required btrfs structure and state file, 
# returns 0 if setup is valid and 1 if setup is needed
check_setup() {
    if ! blkid "$DEVICE_DST" 2>/dev/null | grep -q 'TYPE="btrfs"' || \
            ! blkid "$DEVICE_DST" 2>/dev/null | grep -q "LABEL=\"$LABEL\""; then
        echo "abroot: $DEVICE_DST is not formatted as btrfs with label $LABEL, needs setup"
        return 1
    fi
    
    mkdir -p "$MNT_DST"
    if ! mount -t btrfs -o subvolid=5 "$DEVICE_DST" "$MNT_DST" 2>/dev/null; then
        echo "abroot: failed to mount $DEVICE_DST, needs setup"
        return 1
    fi

    for subvol in rootfsA rootfsB userdata; do
        if ! btrfs subvolume show "$MNT_DST/$subvol" > /dev/null 2>&1; then
            echo "abroot: $DEVICE_DST is missing required subvolume $subvol, needs setup"
            umount "$MNT_DST"
            return 1
        fi
    done

    if [ ! -f "$MNT_DST/$STATE_FILE" ]; then
        echo "abroot: $DEVICE_DST is missing required state file $STATE_FILE, needs setup"
        umount "$MNT_DST"
        return 1
    fi

    umount "$MNT_DST"
    echo "abroot: $DEVICE_DST is properly set up"
    return 0
}

# Performs the full setup of $DEVICE_DST with the required btrfs structure and state file, 
# returns 0 on success and 1 on failure
run_setup() {
    echo "abroot: running setup to initialize $DEVICE_DST"
    
    mkdir -p "$MNT_SRC" "$MNT_DST"
    
    if ! mount -t btrfs "$DEVICE_SRC" "$MNT_SRC"; then
        echo "abroot: failed to mount $DEVICE_SRC for setup"
        return 1
    fi

    if
     btrfs filesystem show "$DEVICE_SRC" 2>/dev/null | grep -q "$DEVICE_DST"; then
        echo "$DEVICE_DST is in the pool, removing..."
        btrfs device remove "$DEVICE_DST" "$MNT_SRC" || {
            echo "abroot: failed to remove $DEVICE_DST from pool, cannot continue setup"
            umount "$MNT_SRC"
            return 1
        }
        echo "Removed."
    else
        echo "$DEVICE_DST is not in the pool, skipping removal"
    fi

    echo "==> Formatting $DEVICE_DST as independent btrfs (label: $LABEL)"
    if ! mkfs.btrfs -L "$LABEL" "$DEVICE_DST"; then
        echo "abroot: failed to format $DEVICE_DST, cannot continue setup"
        umount "$MNT_SRC"
        return 1
    fi

    echo "==> Mounting $DEVICE_DST at $MNT_DST"
    mkdir -p "$MNT_DST"
    if ! mount "$DEVICE_DST" "$MNT_DST"; then
        echo "abroot: failed to mount $DEVICE_DST at $MNT_DST, cannot continue setup"
        umount "$MNT_SRC"
        return 1
    fi

    echo "==> Creating rootfsA, rootfsB, and userdata subvolumes"
    for subvol in rootfsA rootfsB userdata; do
        if btrfs subvolume list "$MNT_DST" | grep -q "$subvol"; then
            echo "$subvol already exists"
        else
            btrfs subvolume create "$MNT_DST/$subvol"
        fi
    done

    echo "==> Creating state file $STATE_FILE"
    mkdir -p "$(dirname "$MNT_DST/$STATE_FILE")"
    cat > "$MNT_DST/$STATE_FILE" << 'EOF'
{
    "active_root": "A",
    "rootfsA": {
        "recently_loaded": true,
        "boot_attempts": 0,
        "boot_successful": false,
        "unbootable": false
    },
    "rootfsB": {
        "recently_loaded": true,
        "boot_attempts": 0,
        "boot_successful": false,
        "unbootable": false
    }
}
EOF
    echo "boot-state.json created"

    echo "==> Creating read-only snapshot of live root for send"
    if ! btrfs subvolume snapshot -r "$MNT_SRC" "$MNT_SRC/$SNAP_NAME"; then
        echo "abroot: failed to create snapshot $SNAP_NAME, cannot continue setup"
        umount "$MNT_DST"
        umount "$MNT_SRC"
        return 1
    fi

    echo "==> Streaming snapshot into rootfsA (this may take a few minutes)"
    if ! btrfs send "$MNT_SRC/$SNAP_NAME" | btrfs receive "$MNT_DST/rootfsA"; then
        echo "abroot: failed to stream snapshot to rootfsA, cannot continue setup"
        umount "$MNT_DST"
        umount "$MNT_SRC"
        return 1
    fi

    echo "==> Promoting snapshot to top-level rootfsA"
    if ! btrfs subvolume snapshot "$MNT_DST/rootfsA/$SNAP_NAME" "$MNT_DST/rootfsA_new"; then
        echo "abroot: failed to promote snapshot to rootfsA, cannot continue setup"
        umount "$MNT_DST"
        umount "$MNT_SRC"
        return 1
    fi
    if ! btrfs subvolume delete "$MNT_DST/rootfsA/$SNAP_NAME"; then
        echo "abroot: failed to delete intermediate snapshot in rootfsA, cannot continue setup"
        umount "$MNT_DST"
        umount "$MNT_SRC"
        return 1
    fi
    if ! btrfs subvolume delete "$MNT_DST/rootfsA"; then
        echo "abroot: failed to delete old rootfsA, cannot continue setup"
        umount "$MNT_DST"
        umount "$MNT_SRC"
        return 1
    fi
    if ! mv "$MNT_DST/rootfsA_new" "$MNT_DST/rootfsA"; then
        echo "abroot: failed to rename new rootfsA, cannot continue setup"
        umount "$MNT_DST"
        umount "$MNT_SRC"
        return 1
    fi

    echo "==> Cleaning up source snapshot"
    if ! btrfs subvolume delete "$MNT_SRC/$SNAP_NAME"; then
        echo "abroot: failed to delete source snapshot $SNAP_NAME, manual cleanup may be needed"
    fi

    echo "==> Updating fstab inside rootfsA"
    FSTAB_A="$MNT_DST/rootfsA/etc/fstab"
    if ! sed -i 's|^[^#]*\s/\s.*btrfs.*|/dev/sda31   /   btrfs   defaults,ssd,subvol=rootfsA   0 0|' "$FSTAB_A"; then
        echo "abroot: failed to update fstab in rootfsA, cannot continue setup"
        umount "$MNT_DST"
        umount "$MNT_SRC"
        return 1
    fi

    echo "==> Snapshotting rootfsA into rootfsB"
    if ! btrfs subvolume delete "$MNT_DST/rootfsB"; then
        echo "abroot: failed to delete existing rootfsB, cannot continue setup"
        umount "$MNT_DST"
        umount "$MNT_SRC"
        return 1
    fi
    if ! btrfs subvolume snapshot "$MNT_DST/rootfsA" "$MNT_DST/rootfsB"; then
        echo "abroot: failed to create snapshot of rootfsA in rootfsB, cannot continue setup"
        umount "$MNT_DST"
        umount "$MNT_SRC"
        return 1
    fi

    echo "==> Updating fstab inside rootfsB"
    FSTAB_B="$MNT_DST/rootfsB/etc/fstab"
    if ! sed -i 's|^[^#]*\s/\s.*btrfs.*|/dev/sda31   /   btrfs   defaults,ssd,subvol=rootfsB   0 0|' "$FSTAB_B"; then
        echo "abroot: failed to update fstab in rootfsB, cannot continue setup"
        umount "$MNT_DST"
        umount "$MNT_SRC"
        return 1
    fi

    echo "==> Creating rootfsA/B userdata directory"
    mkdir -p "$MNT_DST/rootfsA/userdata"
    mkdir -p "$MNT_DST/rootfsB/userdata"

    grep -q "subvol=userdata" "$FSTAB_A" || echo "/dev/sda31   /userdata   btrfs   defaults,ssd,subvol=userdata   0 0" >> "$FSTAB_A"

    grep -q "subvol=userdata" "$FSTAB_B" || echo "/dev/sda31   /userdata   btrfs   defaults,ssd,subvol=userdata   0 0" >> "$FSTAB_B"

    sync

    umount "$MNT_DST"
    umount "$MNT_SRC"
    
    echo "abroot: setup completed successfully"

    return 0
}


# Main logic

if ! check_setup; then
    echo "abroot: setup is required for $DEVICE_DST, starting setup process"
    if ! run_setup; then
        die "abroot: setup failed"
    fi
fi
