#!/bin/sh

mkdir -p /run/abroot/userdata
trap 'umount /run/abroot/userdata 2>/dev/null' EXIT
mount -t btrfs -o rw,subvol=userdata /dev/sda31 /run/abroot/userdata

subvol=$(jq -r '.active_root' /run/abroot/userdata/.abroot/boot-state.json)

if [ "$subvol" = "null" ]; then
    warn "abroot: no active_root found in boot-state.json, defaulting to root subvolume"
    subvol="A"
fi

unbootable=$(jq -r ".rootfs$subvol.unbootable" /run/abroot/userdata/.abroot/boot-state.json)
if [ "$unbootable" = "true" ]; then
    warn "abroot: selected btrfs subvolume $subvol is marked unbootable, switching to the other subvolume"
    if [ "$subvol" != "A" ]; then
        subvol="A"
    else
        subvol="B"
    fi
fi

unbootable=$(jq -r ".rootfs$subvol.unbootable" /run/abroot/userdata/.abroot/boot-state.json)
if [ "$unbootable" = "true" ]; then
    warn "abroot: selected btrfs subvolume $subvol is also marked unbootable, switching back to the other subvolume"
    if [ "$subvol" != "A" ]; then
        subvol="A"
    else
        subvol="B"
    fi
fi

recently_loaded=$(jq -r ".rootfs$subvol.recently_loaded" /run/abroot/userdata/.abroot/boot-state.json)
if [ "$recently_loaded" = "true" ]; then
    echo "abroot: selected btrfs subvolume $subvol was recently loaded, attempting boot"
    boot_attempts=$(jq -r ".rootfs$subvol.boot_attempts" /run/abroot/userdata/.abroot/boot-state.json)
    if [ "$boot_attempts" -gt 0 ]; then
        warn "abroot: selected btrfs subvolume $subvol has $boot_attempts boot attempts, marking unbootable and switching back to the other subvolume"
        
        jq ".rootfs$subvol.unbootable = true" /run/abroot/userdata/.abroot/boot-state.json \
            > /run/abroot/userdata/.abroot/tmp.json && mv /run/abroot/userdata/.abroot/tmp.json \
            /run/abroot/userdata/.abroot/boot-state.json

        if [ "$subvol" != "A" ]; then
            subvol="A"
        else
            subvol="B"
        fi
    fi
fi

recently_loaded=$(jq -r ".rootfs$subvol.recently_loaded" /run/abroot/userdata/.abroot/boot-state.json)
if [ "$recently_loaded" = "true" ]; then
    echo "abroot: selected btrfs subvolume $subvol was also recently loaded, attempting boot"
    boot_attempts=$(jq -r ".rootfs$subvol.boot_attempts" /run/abroot/userdata/.abroot/boot-state.json)
    if [ "$boot_attempts" -gt 0 ]; then
        warn "abroot: selected btrfs subvolume $subvol has $boot_attempts boot attempts, marking unbootable and switching back to the other subvolume"
        
        jq ".rootfs$subvol.unbootable = true" /run/abroot/userdata/.abroot/boot-state.json \
            > /run/abroot/userdata/.abroot/tmp.json && mv /run/abroot/userdata/.abroot/tmp.json \
            /run/abroot/userdata/.abroot/boot-state.json

        if [ "$subvol" != "A" ]; then
            subvol="A"
        else
            subvol="B"
        fi
        recently_loaded=$(jq -r ".rootfs$subvol.recently_loaded" /run/abroot/userdata/.abroot/boot-state.json)
    fi
fi

if [ "$recently_loaded" = "true" ]; then
    echo "abroot: incrementing boot attempts for btrfs subvolume $subvol"
    
    jq ".rootfs$subvol.boot_attempts += 1" /run/abroot/userdata/.abroot/boot-state.json \
        > /run/abroot/userdata/.abroot/tmp.json && mv /run/abroot/userdata/.abroot/tmp.json \
        /run/abroot/userdata/.abroot/boot-state.json

fi

jq ".active_root = \"$subvol\"" /run/abroot/userdata/.abroot/boot-state.json \
    > /run/abroot/userdata/.abroot/tmp.json && mv /run/abroot/userdata/.abroot/tmp.json \
    /run/abroot/userdata/.abroot/boot-state.json
    
sync
echo "rootfs$subvol" > /run/abroot.subvol

info "abroot: selected btrfs subvolume $subvol"