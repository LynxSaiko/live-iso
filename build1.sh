#!/bin/bash
# [*] Author: LynxSaiko - FINAL (install mksquashfs only)
set -e

LIVE_NAME="lfs-live-full"
WORKDIR="$HOME/livecd"
ISO_NAME="$HOME/${LIVE_NAME}.iso"
SQUASHFS_VER="4.5"

echo "[+] Membuat struktur direktori ISO..."
mkdir -pv "$WORKDIR"/{iso/boot/grub,initrd,iso/live,build}

# ==============================================
# 1. CEK & INSTALL mksquashfs SAJA
# ==============================================
if ! command -v mksquashfs >/dev/null; then
    echo "[!] mksquashfs tidak ditemukan, mengunduh squashfs-tools..."
    cd "$WORKDIR/build"
    wget -nc https://downloads.sourceforge.net/project/squashfs/squashfs/squashfs-${SQUASHFS_VER}/squashfs${SQUASHFS_VER}.tar.gz
    tar -xf squashfs${SQUASHFS_VER}.tar.gz
    cd squashfs${SQUASHFS_VER}/squashfs-tools
    make -j$(nproc)
    cp mksquashfs unsquashfs /usr/local/bin/
else
    echo "[✓] mksquashfs ditemukan: $(which mksquashfs)"
fi

# ==============================================
# 2. BUAT ROOTFS DENGAN SQUASHFS
# ==============================================
echo "[+] Membuat root filesystem (SquashFS)..."
mksquashfs / "$WORKDIR/iso/live/rootfs.squashfs" \
  -wildcards \
  -e /proc /sys /dev /run /tmp /boot /home /mnt /media /lost+found \
     /usr/share/doc /usr/share/info /usr/share/man /usr/include /usr/src \
     *.a *.la *.o \
  -noappend -comp zstd -b 1M -processors $(nproc)

# ==============================================
# 3. BUAT INITRAMFS
# ==============================================
echo "[+] Menyiapkan initramfs..."
cd "$WORKDIR/initrd"
mkdir -pv {bin,sbin,etc,proc,sys,dev,tmp,newroot}

cp -v /bin/busybox bin/ || cp -v /usr/bin/busybox bin/
chmod +x bin/busybox
cd bin && ln -sf busybox sh && cd ..

cat > init << "EOF"
#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t devtmpfs dev /dev

echo "Mounting SquashFS root..."
mkdir /newroot
mount -t squashfs -o loop /live/rootfs.squashfs /newroot
exec switch_root /newroot /bin/sh
EOF

chmod +x init

cd "$WORKDIR/initrd"
find . -print0 | cpio --null -ov --format=newc | gzip -9 > "$WORKDIR/iso/boot/initrd.img"

# ==============================================
# 4. COPY KERNEL
# ==============================================
echo "[+] Menyalin kernel..."
cp -v /boot/vmlinuz-* "$WORKDIR/iso/boot/vmlinuz"

# ==============================================
# 5. GRUB CONFIG
# ==============================================
cat > "$WORKDIR/iso/boot/grub/grub.cfg" << "EOF"
set timeout=5
set default=0

menuentry "LeakOS Shadow Edition" {
    linux /boot/vmlinuz root=/dev/ram0 rw
    initrd /boot/initrd.img
}
EOF

# ==============================================
# 6. BUILD ISO
# ==============================================
echo "[+] Membuat file ISO bootable..."
grub-mkrescue -o "$ISO_NAME" "$WORKDIR/iso"

echo "[✓] ISO selesai dibuat: $ISO_NAME"
