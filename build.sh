#!/bin/bash
# [*] Author: LynxSaiko
# [*] Simplified for /dev/sdb1 only

set -e

# --- KONFIGURASI ---
LIVE_NAME="lfs-live"
WORKDIR="/mnt/liveiso/${LIVE_NAME}-build-$$"
ISO_NAME="/mnt/liveiso/${LIVE_NAME}.iso"
SQUASHFS_FILE="rootfs.squashfs"

# HANYA gunakan /dev/sdb1
LIVE_PARTITION_DEV="/dev/sdb1"
LIVE_MOUNT_POINT="/mnt/liveiso"
LFS_SOURCE_ROOT="/"

# Cek Tools yang Diperlukan
REQUIRED_TOOLS="mksquashfs xorriso rsync cpio gzip"
for tool in $REQUIRED_TOOLS; do
    if ! command -v $tool &> /dev/null; then
        echo "[!] ERROR: '$tool' tidak ditemukan."
        exit 1
    fi
done

# ==========================
# PERSIAPAN: Mount Partisi dan Direktori
# ==========================
echo "[+] Mounting $LIVE_PARTITION_DEV ke $LIVE_MOUNT_POINT..."
mkdir -p "$LIVE_MOUNT_POINT"
mount "$LIVE_PARTITION_DEV" "$LIVE_MOUNT_POINT"

echo "[+] Membuat struktur direktori ISO di $WORKDIR..."
mkdir -pv "$WORKDIR"/{iso/boot/grub,rootfs,initrd}

# ==========================
# 1. COPY ROOTFS & BUAT SQUASHFS
# ==========================
echo "[+] Menyalin root filesystem ke $WORKDIR/rootfs..."
rsync -aAXv --progress "$LFS_SOURCE_ROOT" "$WORKDIR/rootfs" \
  --exclude={"/proc","/sys","/dev","/mnt","/media","/tmp","/boot","/lost-found","/var/log","/var/cache","/var/tmp","/.cache","/usr/share/doc","/usr/share/man"} \
  --exclude="$WORKDIR"

echo "[+] Membuat $SQUASHFS_FILE dari rootfs..."
mksquashfs "$WORKDIR/rootfs" "$WORKDIR/iso/boot/$SQUASHFS_FILE" -comp xz

# ==========================
# 2. MENYIAPKAN INITRAMFS
# ==========================
echo "[+] Menyiapkan Initramfs..."
INITRD_ROOT="$WORKDIR/initrd"
mkdir -pv "$INITRD_ROOT"/{bin,sbin,proc,sys,dev,tmp,newroot,lib,lib64,"$LIVE_MOUNT_POINT"}

collect_dependencies() {
    local BINARY_PATH=$1
    local INITRD_TARGET_DIR=$2

    mkdir -p "$INITRD_TARGET_DIR"/{lib,lib64}

    ldd "$BINARY_PATH" 2>/dev/null | awk '
        /=>/ { print $3 }
        !/=>/ && !/not a dynamic executable/ { print $1 }
    ' | while read -r lib; do
        if [[ -f "$lib" ]]; then
            if [[ "$lib" =~ ^/(lib|lib64)/ ]]; then
                cp -v "$lib" "$INITRD_TARGET_DIR${lib%/*}/"
            fi
        fi
    done
}

COREUTILS_BINS="/bin/ls /bin/cat /bin/echo /bin/mkdir /bin/mknod /bin/mount /bin/umount /sbin/switch_root"

for bin in $COREUTILS_BINS; do
    if [ -f "$bin" ]; then
        cp -v "$bin" "$INITRD_ROOT/${bin#/}"
        collect_dependencies "$bin" "$INITRD_ROOT"
    fi
done
chmod +x "$INITRD_ROOT"/bin/* "$INITRD_ROOT"/sbin/*

# ==========================
# 3. BUAT SCRIPT INIT SEDERHANA
# ==========================
echo "[+] Membuat skrip init..."
cat > "$INITRD_ROOT/init" << EOF
#!/bin/sh
# Skrip init LiveCD - Hanya untuk /dev/sdb1

export PATH=/bin:/sbin

echo "=== Booting LFS LiveCD ==="
echo "Target device: $LIVE_PARTITION_DEV"

# Mount filesystems dasar
mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t devtmpfs dev /dev

# Buat device node untuk loop
mknod /dev/loop0 b 7 0 2>/dev/null

echo "Mounting $LIVE_PARTITION_DEV ke $LIVE_MOUNT_POINT..."

if mount -o ro $LIVE_PARTITION_DEV $LIVE_MOUNT_POINT; then
    echo "✓ Device berhasil di-mount"
    
    if [ -f "$LIVE_MOUNT_POINT/boot/$SQUASHFS_FILE" ]; then
        echo "✓ SquashFS ditemukan"
        
        mkdir -p /newroot
        if mount -t squashfs -o ro,loop "$LIVE_MOUNT_POINT/boot/$SQUASHFS_FILE" /newroot; then
            echo "✓ Root filesystem berhasil di-mount"
            
            # Cleanup dan switch root
            umount $LIVE_MOUNT_POINT
            umount /sys
            umount /proc
            umount /dev
            
            echo "Beralih ke sistem LiveOS..."
            exec switch_root /newroot /sbin/init
        else
            echo "✗ Gagal mount SquashFS"
        fi
    else
        echo "✗ SquashFS tidak ditemukan di $LIVE_MOUNT_POINT/boot/$SQUASHFS_FILE"
    fi
    umount $LIVE_MOUNT_POINT
else
    echo "✗ Gagal mount $LIVE_PARTITION_DEV"
fi

# Fallback shell
echo "=== Emergency Shell ==="
exec /bin/sh
EOF

chmod +x "$INITRD_ROOT/init"

# ==========================
# 4. BUAT INITRAMFS & KERNEL
# ==========================
echo "[+] Membuat initramfs..."
cd "$WORKDIR/initrd"
find . -print0 | cpio --null -ov --format=newc | gzip -9 > "$WORKDIR/iso/boot/initrd.img"

echo "[+] Menyalin kernel..."
KERNEL_VERSION=$(uname -r)
cp -v "/boot/vmlinuz-${KERNEL_VERSION}" "$WORKDIR/iso/boot/vmlinuz"

# ==========================
# 5. GRUB CONFIG
# ==========================
echo "[+] Menyiapkan GRUB..."

# Konfigurasi GRUB untuk MBR
cat > "$WORKDIR/iso/boot/grub/grub.cfg" << EOF
set timeout=5
set default=0
menuentry "LFS LiveCD - /dev/sdb1" {
    linux /boot/vmlinuz
    initrd /boot/initrd.img
}
EOF

# ==========================
# 6. MEMBUAT ISO HYBRID (HANYA MBR)
# ==========================
echo "[+] Membuat ISO: $ISO_NAME..."

MBR_BOOT_IMG="/usr/lib/grub/i386-pc/boot_hybrid.img"
xorriso -as mkisofs \
    -iso-level 3 \
    -volid "LFS_LIVE" \
    -graft-points \
    -boot-load-size 4 \
    -boot-info-table \
    -b boot/grub/grub.cfg \
    -no-emul-boot \
    -isohybrid-mbr "$MBR_BOOT_IMG" \
    -output "$ISO_NAME" \
    "$WORKDIR/iso"

echo "=========================================================="
echo "[✓] ISO selesai: $ISO_NAME"
echo "[✓] Hanya akan boot dari: $LIVE_PARTITION_DEV (MBR)"
echo "[i] Test: qemu-system-x86_64 -cdrom '$ISO_NAME' -m 2G"
echo "=========================================================="
