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

info "abroot: patching sysroot mount to use btrfs subvolume $subvol"

if [ ! -f "$unit" ]; then
    warn "abroot: $unit does not exist"
    warn "abroot: cannot patch sysroot mount"
    exit 0
fi

tmp="${unit}.tmp"

awk -v subvol="$subvol" '
BEGIN {
    done = 0
}

/^Options=/ {
    opts = $0
    sub(/^Options=/, "", opts)

    # Remove any existing subvol=... option from the comma-separated list.
    n = split(opts, parts, ",")
    newopts = ""

    for (i = 1; i <= n; i++) {
        if (parts[i] !~ /^subvol=/ && parts[i] != "") {
            if (newopts != "") {
                newopts = newopts "," parts[i]
            } else {
                newopts = parts[i]
            }
        }
    }

    if (newopts != "") {
        newopts = newopts ",subvol=" subvol
    } else {
        newopts = "subvol=" subvol
    }

    print "Options=" newopts
    done = 1
    next
}

{
    print
}

END {
    if (!done) {
        print "Options=subvol=" subvol
    }
}
' "$unit" > "$tmp" && mv "$tmp" "$unit"


# Debug output
info "abroot: final sysroot.mount after patch:"
while read -r line; do
    info "abroot: sysroot.mount: $line"
done < "$unit"