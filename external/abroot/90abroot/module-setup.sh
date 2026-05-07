#!/bin/bash

check() {
    return 0
}

depends() {
    echo "rootfs-block btrfs dracut-systemd"
    return 0
}

install() {
    inst_hook cmdline 99 "$moddir/parse-abroot.sh" # 99 priority to run after cmdline hooks from other modules
    inst_hook pre-mount 90 "$moddir/patch-sysroot-mount.sh" # 90 priority to run before sysroot-mount runs
}

