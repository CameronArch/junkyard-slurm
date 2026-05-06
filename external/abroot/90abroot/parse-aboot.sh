#!/bin/sh

command -v getarg >/dev/null 2>&1 || . /lib/dracut-lib.sh

case "$(getarg abroot)" in
    A|a)
        subvol="rootfsA"
        ;;
    B|b)
        subvol="rootfsB"
        ;;
    "")
        subvol="rootfsA"
        ;;
    *)
        warn "abroot: invalid value '$abroot',defaulting to 'rootfsA'"
        ;;
esac

echo "$subvol" > /run/abroot.subvol

info "abroot: selected btrfs subvolume $subvol"