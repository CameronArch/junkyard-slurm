#!/bin/bash

check() {
    require_binaries jq || return 1
    return 0
}

depends() {
    echo "rootfs-block btrfs dracut-systemd"
    return 0
}

install() {
    inst_binary jq
    inst_hook pre-mount 85 "$moddir/select-abroot.sh" # 85 priority to run before 90-abroot-mount runs
    inst_hook pre-mount 90 "$moddir/patch-sysroot-mount.sh" # 90 priority to run before sysroot-mount runs
}

