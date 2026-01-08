# Config

[private]
_apt_packages := replace(read(join("rootfs", "packages.txt")), "\n", " ")

# Tools

[private]
_rsync := require("rsync")
[private]
_mkbootimg := join(justfile_directory(), "tools", "mkbootimg", "mkbootimg.py")
[private]
_bazel := join(justfile_directory(), "kernel", "source", "tools", "bazel")

default:
    just --list

# Will take around 1hr
[group('kernel')]
[working-directory('kernel/source')]
clone_kernel_source android_kernel_branch="android-gs-felix-6.1-android16":
    @echo "Cloning Android kernel from branch: {{ android_kernel_branch }}"
    eatmydata repo init \
      --depth=1 \
      -u https://android.googlesource.com/kernel/manifest \
      -b {{ android_kernel_branch }}
    eatmydata repo sync -j {{ num_cpus() }}

[private]
_kernel_build_dir := join(justfile_directory(), "kernel", "out")
[private]
_kernel_version := trim(read(join("kernel", "out", "kernel_version")))

[group('kernel')]
[working-directory('kernel/source')]
clean_kernel: clone_kernel_source
    eatmydata {{ _bazel }} clean --expunge

[group('kernel')]
[working-directory('kernel/source')]
build_kernel: clone_kernel_source
    eatmydata cp -r ../custom_defconfig_mod .
    eatmydata {{ _bazel }} run \
      --config=use_source_tree_aosp \
      --config=stamp \
      --config=felix \
      --defconfig_fragment=//custom_defconfig_mod:custom_defconfig \
      //private/devices/google/felix:gs201_felix_dist
    eatmydata mv ./out/felix/dist/* ../out/
    @echo "Updating kernel version string"
    strings {{ join(_kernel_build_dir, "Image") }} \
      | grep "Linux version" \
      | head -n 1 \
      | awk '{print $3}' > ../out/kernel_version

[private]
_sysroot_img := join(justfile_directory(), "boot", "rootfs.img")
[private]
_sysroot_dir := join(justfile_directory(), "rootfs", "sysroot")
[private]
_syskern_dir := join(justfile_directory(), "kernel", "syskern")
[private]
_user := env("USER")
[private]
_rootfs_built_sentinel := join(justfile_directory(), ".rootfs_built")
[private]
_create_rootfs_sentinel := join(justfile_directory(), ".create_rootfs")

[group('rootfs')]
[working-directory('rootfs')]
clean_rootfs: 
    eatmydata rm -f {{ _rootfs_built_sentinel }} {{ _create_rootfs_sentinel }} {{ _sysroot_img }}
    sudo eatmydata rm -rf --one-file-system {{ _sysroot_dir }}

[group('rootfs')]
[working-directory('rootfs')]
_build_rootfs debootstrap_release root_password hostname size:
    # why does debian have this one package in everything BUT trixie...
    eatmydata wget -P /tmp 'http://ftp.us.debian.org/debian/pool/main/k/kmscon/kmscon_9.0.0-4_arm64.deb'
    sudo DEBIAN_FRONTEND=noninteractive eatmydata mmdebstrap \
      --variant=standard \
      --arch=arm64 {{ debootstrap_release }} \
      --include="locales apt-utils eatmydata {{ _apt_packages }}" \
      --hook-dir=/usr/share/mmdebstrap/hooks/eatmydata \
      --include="/tmp/kmscon_9.0.0-4_arm64.deb" \
      --hook-dir=/usr/share/mmdebstrap/hooks/file-mirror-automount \
      --customize-hook='tar-in {{ _kernel_tar }} /' \
      --customize-hook='echo {{ hostname }} > "$1/etc/hostname"' \
      --customize-hook='echo root:{{ root_password }} | chpasswd -R "$1"' \
      --customize-hook='useradd -R "$1" -m -s /bin/bash -G sudo kalm' \
      --customize-hook='echo kalm:0000 | chpasswd -R "$1"' \
      --customize-hook='echo "%sudo ALL=(ALL) NOPASSWD:ALL" >"$1/etc/sudoers.d/99-sudo-nopasswd"' \
      --customize-hook='cp firstboot.sh "$1/home/kalm/firstboot.sh" && chown 1000:1000 "$1/home/kalm/firstboot.sh" && chmod 755 "$1/home/kalm/firstboot.sh" && echo "~/firstboot.sh" >> "$1/home/kalm/.profile"' \
      --customize-hook='echo "/dev/disk/by-partlabel/super / btrfs defaults,ssd 0 0" > "$1/etc/fstab"' \
      --customize-hook="sed -i -e 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' \"\$1/etc/locale.gen\" && chroot \"\$1\" eatmydata dpkg-reconfigure locales && chroot \"\$1\" eatmydata update-locale en_US.UTF-8" \
      --customize-hook="sed -i \
        -e 's/^#HandleLidSwitch=.*/HandleLidSwitch=ignore/' \
        -e 's/^#HandleLidSwitchExternalPower=.*/HandleLidSwitchExternalPower=ignore/' \
        -e 's/^#HandleLidSwitchDocked=.*/HandleLidSwitchDocked=ignore/' \
        \"\$1/etc/systemd/logind.conf\"" \
      --customize-hook='mkdir -p "$1/etc/systemd/system/kmsconvt@.service.d" && printf "[Service]\nExecStart=\nExecStart=/usr/bin/kmscon \"--vt=%%I\" --seats=seat0 --no-switchvt --login -- /sbin/agetty -a kalm - xterm-256color\n" > "$1/etc/systemd/system/kmsconvt@.service.d/override.conf"' \
      --customize-hook='mkdir -p "$1/etc/systemd/system/adbd.service.d" && printf "[Unit]\nWants=sys-kernel-config.mount\nAfter=\n\n[Service]\nSocketBindDeny=tcp:5555\n" > "$1/etc/systemd/system/adbd.service.d/override.conf"' \
      --customize-hook='ln -s /dev/null "$1/etc/systemd/system/systemd-backlight@.service"' \
      --customize-hook='chroot "$1" dracut --kver {{ _kernel_version }} --show-modules --force' \
      {{ _sysroot_dir }}

    touch {{ _rootfs_built_sentinel }}

[group('rootfs')]
[working-directory('rootfs')]
build_rootfs debootstrap_release="stable" root_password="0000" hostname="fold" size="4GiB": (create_rootfs_image size) 
    # First stage
    @if [ ! -f {{ _rootfs_built_sentinel }} ]; then \
      just _build_rootfs {{ debootstrap_release }} {{ root_password }} {{ hostname }} {{ size }}; \
    fi

[private]
_module_order_path := join(justfile_directory(), "kernel", "module_order.txt")
[private]
_kernel_tar := join(justfile_directory(), "kernel", "kernel.tar")

# TODO: Download factory image and copy firmware
[group('kernel')]
[working-directory('kernel')]
update_kernel_modules_and_source: 
    eatmydata mkdir -p {{ _syskern_dir }}/usr/lib/modules/{{ _kernel_version }}
    eatmydata ln -s {{ _syskern_dir }}/usr/lib {{ _syskern_dir }}/lib
    eatmydata cp {{ _kernel_build_dir }}/modules.builtin {{ _syskern_dir }}/usr/lib/modules/{{ _kernel_version }}/
    eatmydata cp {{ _kernel_build_dir }}/modules.builtin.modinfo {{ _syskern_dir }}/usr/lib/modules/{{ _kernel_version }}/

    eatmydata rm -f {{ _syskern_dir }}/usr/lib/modules/{{ _kernel_version }}/modules.order
    eatmydata touch {{ _syskern_dir }}/usr/lib/modules/{{ _kernel_version }}/modules.order

    @echo "Copying modules"
    for staging in vendor_dlkm system_dlkm; \
    do \
      eatmydata mkdir -p unpack/"$staging" && \
      eatmydata tar \
        -xvzf {{ _kernel_build_dir }}/"$staging"_staging_archive.tar.gz \
        -C unpack/"$staging"; \
      eatmydata {{ _rsync }} -avK --ignore-existing  --include='*/' --include='*.ko' --exclude='*' unpack/"$staging"/ {{ _syskern_dir }}/usr/; \
      eatmydata sh -c "cat unpack/\"$staging\"/lib/modules/{{ _kernel_version }}/modules.order \
        >> {{ _syskern_dir }}/usr/lib/modules/{{ _kernel_version }}/modules.order"; \
    done

    @echo "Updating System.map"
    eatmydata mkdir -p {{ _syskern_dir }}/boot
    eatmydata cp {{ _kernel_build_dir }}/System.map {{ _syskern_dir }}/boot/System.map-{{ _kernel_version }}

    @echo "Updating module dependencies"
    eatmydata depmod -b {{ _syskern_dir }} \
      --errsyms \
      --all \
      --filesyms {{ _syskern_dir }}/boot/System.map-{{ _kernel_version }} \
      {{ _kernel_version }}

    @echo "Copying kernel headers"
    eatmydata mkdir -p {{ _syskern_dir }}/usr/src/linux-headers-{{ _kernel_version }}
    eatmydata mkdir -p unpack/kernel_headers
    eatmydata tar \
      -xvzf {{ _kernel_build_dir }}/kernel-headers.tar.gz \
      -C unpack/kernel_headers
    eatmydata cp -r unpack/kernel_headers {{ _syskern_dir }}/usr/src/linux-headers-{{ _kernel_version }}
    eatmydata ln -rsf {{ _syskern_dir }}/usr/src/linux-headers-{{ _kernel_version }} {{ _syskern_dir }}/usr/lib/modules/{{ _kernel_version }}/build
    eatmydata cp {{ _kernel_build_dir }}/kernel_aarch64_Module.symvers {{ _syskern_dir }}/usr/src/linux-headers-{{ _kernel_version }}/
    eatmydata cp {{ _kernel_build_dir }}/vmlinux.symvers {{ _syskern_dir }}/usr/src/linux-headers-{{ _kernel_version }}/

    @echo "Setting systemd module load order"
    rm -f {{ _module_order_path }}

    cat {{ _kernel_build_dir }}/vendor_kernel_boot.modules.load | xargs -I {} \
      modinfo -b {{ _syskern_dir }} -k {{ _kernel_version }} -F name "{{ _syskern_dir }}/usr/lib/modules/{{ _kernel_version }}/{}" \
      > {{ _module_order_path }}
    cat {{ _kernel_build_dir }}/vendor_dlkm.modules.load | xargs -I {} \
      modinfo -b {{ _syskern_dir }} -k {{ _kernel_version }} -F name "{{ _syskern_dir }}/usr/lib/modules/{{ _kernel_version }}/{}" \
      >> {{ _module_order_path }}
    cat {{ _kernel_build_dir }}/system_dlkm.modules.load | xargs -I {} \
      modinfo -b {{ _syskern_dir }} -k {{ _kernel_version }} -F name "{{ _syskern_dir }}/usr/lib/modules/{{ _kernel_version }}/{}" \
      >> {{ _module_order_path }}
    eatmydata mkdir -p {{ _syskern_dir }}/usr/lib/dracut/dracut.conf.d
    eatmydata cp {{ _kernel_build_dir }}/Image.lz4 {{ _syskern_dir }}/boot/vmlinuz-{{ _kernel_version }}
    eatmydata cp {{ _kernel_build_dir }}/dtb.img {{ _syskern_dir }}/boot/{{ _kernel_version }}.dtb
    echo force_drivers+=\" $(cat {{ _module_order_path }}) \" > {{ _syskern_dir }}/usr/lib/dracut/dracut.conf.d/kernel.conf
    echo compress=\"lz4\" >> {{ _syskern_dir }}/usr/lib/dracut/dracut.conf.d/kernel.conf
    rm -f {{ _syskern_dir }}/lib
    rmdir {{ _syskern_dir }}/usr/etc
    tar --owner=root --group=root -cvf {{ _kernel_tar }} -C {{ _syskern_dir }} .

[private]
_initramfs_path := join(_sysroot_dir, "boot", "initrd.img-" + _kernel_version)

# TODO: Fix for proper root password (/etc/shadow) maybe with some post service
# Add other user (kalm)
# Add sudo and add user to sudo...
# sudo adduser <username> sudo.
# cat /sys/class/power_supply/battery/capacity
# ADD AOC.bin thing...
# userdata fstab? mkfs if it doesn't have an image...

[group('rootfs')]
[working-directory('boot')]
create_rootfs_image size="4GiB": 
    @if [ ! -f {{ _create_rootfs_sentinel }} ]; then \
      just _create_rootfs_image {{ size }}; \
    fi

[group('rootfs')]
[working-directory('boot')]
_create_rootfs_image size="4GiB":
    sudo eatmydata rm -f {{ _sysroot_img }}
    sudo eatmydata fallocate -l {{ size }} {{ _sysroot_img }}
    sudo eatmydata rm -rf --one-file-system {{ _sysroot_dir }}
    eatmydata mkdir {{ _sysroot_dir }}
    touch {{ _create_rootfs_sentinel }}

[group('boot')]
[working-directory('boot')]
build_boot_images: 
    sudo eatmydata {{ _mkbootimg }} \
      --kernel {{ _sysroot_dir }}/boot/vmlinuz-{{ _kernel_version }} \
      --cmdline "root=/dev/disk/by-partlabel/super" \
      --header_version 4 \
      -o boot.img \
      --pagesize 2048 \
      --os_version 15.0.0 \
      --os_patch_level 2025-02

    sudo eatmydata {{ _mkbootimg }} \
      --ramdisk_name "" \
      --vendor_ramdisk_fragment {{ _initramfs_path }} \
      --dtb {{ _sysroot_dir }}/boot/{{ _kernel_version }}.dtb \
      --header_version 4 \
      --vendor_boot vendor_boot.img \
      --pagesize 2048 \
      --os_version 15.0.0 \
      --os_patch_level 2025-02

    sudo eatmydata mkfs.btrfs --rootdir {{ _sysroot_dir }} {{ _sysroot_img }}