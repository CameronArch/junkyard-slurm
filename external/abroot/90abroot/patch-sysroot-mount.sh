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
dropin_dir="/run/systemd/system/sysroot.mount.d"
dropin="$dropin_dir/90-abroot.conf"

info "abroot: creating runtime systemd override for sysroot.mount"
info "abroot: selected btrfs subvolume $subvol"

if [ ! -f "$unit" ]; then
    warn "abroot: generated sysroot.mount does not exist yet"
    warn "abroot: writing runtime drop-in anyway"
else
    info "abroot: generated sysroot.mount exists"
fi

mkdir -p "$dropin_dir"

cat > "$dropin" <<EOF
[Mount]
Options=subvol=$subvol
EOF

info "abroot: wrote runtime drop-in $dropin"
info "abroot: drop-in contents:"
while read -r line; do
    info "abroot: drop-in: $line"
done < "$dropin"

if [ -f "$unit" ]; then
    info "abroot: generated sysroot.mount before daemon-reload:"
    while read -r line; do
        info "abroot: sysroot.mount: $line"
    done < "$unit"
fi

if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload || warn "abroot: systemctl daemon-reload failed"
else
    warn "abroot: systemctl not found, cannot daemon-reload"
fi

info "abroot: finished runtime override setup"
