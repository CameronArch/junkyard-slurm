#!/bin/sh

MOUNT_SRC="/run/abroot/superroot"
MOUNT_DST="/run/abroot/newroot"

DEVICE_SRC="/dev/sda30"
DEVICE_DST="/dev/sda31"
SNAP_NAME=".snap_for_send"

STATE=$MOUNT_DST/userdata/.abroot/boot-state.json
TMP=$MOUNT_DST/userdata/.abroot/tmp.json

# Write to json file at given parameter, using $STATE and $TMP as the source and destination
json_write() {
    jq "$1" "$STATE" > "$TMP" && mv "$TMP" "$STATE"
}

needs_update() {
    deployed_version=$(jq -r '.version' "$STATE")

    [ "$image_version" != "$deployed_version" ]
}

get_inactive_subvol() {
    recently_loaded_a=$(jq -r '.rootfsA.recently_loaded' "$STATE")
    recently_loaded_b=$(jq -r '.rootfsB.recently_loaded' "$STATE")

    # If a recently_loaded flag is true, that means an update was pending
    # and it wasn't able to boot into userspace. To prevent overwriting
    # the good rootfs, keep trying to update that bad rootfs.
    if [ "$recently_loaded_a" = "true" ]; then
        echo "A"
    elif [ "$recently_loaded_b" = "true" ]; then
        echo "B"

    # Otherwise use inactive root
    else
        active=$(jq -r '.active_root' "$STATE")

        if [ "$active" = "A" ]; then
            echo "B"
        else
            echo "A"
        fi
    fi
}

execute_update() {
    image_version="$1"
    subvol=$(get_inactive_subvol)
    TARGET_SUBVOL=rootfs$subvol

    echo "abroot: updating inactive slot $TARGET_SUBVOL"

    json_write ".$TARGET_SUBVOL.recently_loaded = true"
    json_write ".$TARGET_SUBVOL.boot_attempts = 0"
    json_write ".$TARGET_SUBVOL.boot_successful = false"
    json_write ".$TARGET_SUBVOL.unbootable = false"

    echo "abroot: removing old $TARGET_SUBVOL if exists"
    if btrfs subvolume show "$MOUNT_DST/$TARGET_SUBVOL" >/dev/null 2>&1; then
        btrfs subvolume delete "$MOUNT_DST/$TARGET_SUBVOL"
    fi

    btrfs subvolume delete "$MOUNT_SRC/$SNAP_NAME" 2>/dev/null || true
    btrfs subvolume delete "$MOUNT_DST/$SNAP_NAME" 2>/dev/null || true

    echo "abroot: creating snapshot"
    btrfs subvolume snapshot -r \
        "$MOUNT_SRC/." \
        "$MOUNT_SRC/$SNAP_NAME"

    echo "abroot: sending rootfs"
    btrfs send "$MOUNT_SRC/$SNAP_NAME" | btrfs receive "$MOUNT_DST"

    echo "abroot: creating $TARGET_SUBVOL"
    btrfs subvolume snapshot \
        "$MOUNT_DST/$SNAP_NAME" \
        "$MOUNT_DST/$TARGET_SUBVOL"

    sync
    btrfs filesystem sync "$MOUNT_DST"

    echo "abroot: cleaning temporary snapshots"
    btrfs subvolume delete "$MOUNT_SRC/$SNAP_NAME"
    btrfs subvolume delete "$MOUNT_DST/$SNAP_NAME"

    echo "abroot: updating fstab"

    # sda31
    FSTAB="$MOUNT_DST/$TARGET_SUBVOL/etc/fstab"
    sed -i "s|^[^#]*\s/\s.*btrfs.*|/dev/sda31   /   btrfs   defaults,ssd,subvol=${TARGET_SUBVOL}   0 0|" "$FSTAB"

    # userdata
    grep -q "subvol=userdata" "$FSTAB" || \
    echo "/dev/sda31   /userdata   btrfs   defaults,ssd,subvol=userdata   0 0" >> "$FSTAB"

    echo "    fstab updated:"
    grep " / " "$FSTAB"
    grep "userdata" "$FSTAB"

    echo "abroot: final subvolume layout:"
    btrfs subvolume list "$MOUNT_DST"

    # Update version flag and switch to new root
    json_write ".version = \"$image_version\""
    json_write ".active_root = \"$subvol\""

    echo "abroot: update complete -> $TARGET_SUBVOL now at $image_version"
}

# MOUNT 1: super partition
mkdir -p "$MOUNT_SRC"
echo "abroot: mounting super partition"
mount "$DEVICE_SRC" "$MOUNT_SRC"

# MOUNT 2: user partition
mkdir -p "$MOUNT_DST"
echo "abroot: mounting user partition"
mount "$DEVICE_DST" "$MOUNT_DST"

image_version=$(cat "$MOUNT_SRC/etc/rootfs-version")

if needs_update; then
    execute_update "$image_version"
else
    echo "abroot: no update required"
fi