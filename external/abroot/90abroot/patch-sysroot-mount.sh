#!/bin/sh

command -v getarg >/dev/null 2>&1 || . /lib/dracut-lib.sh

subvol="rootfsA"

if [ -f /run/abroot.subvol ]; then
    subvol="$(cat /run/abroot.subvol)"
    info "abroot: using previously selected btrfs subvolume $subvol"
else
    warn "abroot: no previously selected btrfs subvolume found, defaulting to rootfsA"
fi

case "$subvol" in
    rootfsA|rootfsB)
        ;;
    *)
        warn "abroot: invalid btrfs subvolume '$subvol', defaulting to rootfsA"
        subvol="rootfsA"
        ;;
esac

unit="/run/systemd/generator/sysroot.mount"
dropin_dir="/run/systemd/generator/sysroot.mount.d"
dropin="$dropin_dir/90-abroot.conf"

info "abroot: patching sysroot mount to use btrfs subvolume $subvol"

if [ ! -f "$unit" ]; then
    warn "abroot: $unit does not exist"
    warn "abroot: cannot patch sysroot mount"
    exit 0
fi

mkdir -p "$dropin_dir"

cat > "$dropin" <<EOF

[Mount]
options=subvol=$subvol
EOF

info "abroot: wrote $dropin:"
info "abroot: Options=subvol=$subvol"

if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload || warn "abroot: systemctl daemon-reload failed"
fi

# Debug output.
if [ -f "$unit" ]; then
    info "abroot: current generated sysroot.mount:"
    while read -r line; do
        info "abroot: sysroot.mount: $line"
    done < "$unit"
fi

if [ -f "$dropin" ]; then
    info "abroot: current abroot drop-in:"
    while read -r line; do
        info "abroot: drop-in: $line"
    done < "$dropin"
fi
