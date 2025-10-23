#!/bin/bash
# [*] Author: LynxSaiko
# [*] Simplified for /dev/sdb1 only, with fixed directory name

set -e

# --- KONFIGURASI ---
LIVE_NAME="leakos"
LIVE_BUILD_DIR="/mnt/liveiso/${LIVE_NAME}-build" # Nama direktori tetap
WORKDIR="${LIVE_BUILD_DIR}"
ISO_NAME="/mnt/liveiso/${LIVE_NAME}.iso"
SQUASHFS_FILE="rootfs.squashfs"
LIVE_PARTITION_DEV="/dev/sdb1"
LIVE_MOUNT_POINT="/mnt/liveiso"
LFS_SOURCE_ROOT="/"
KERNEL_VERSION=$(uname -r)
MBR_BOOT_IMG="/usr/lib/grub/i386-pc/boot_hybrid.img"

for bin in $COREUTILS_BINS; do
    if [ -f "$bin" ]; then
        cp -v "$bin" "$INITRD_ROOT/${bin#/}"
        collect_dependencies "$bin" "$INITRD_ROOT"
    fi
done
chmod +x "$INITRD_ROOT"/bin/* "$INITRD_ROOT"/sbin/*

# Salin modul kernel yang diperlukan ke Initrd (minimal)
echo "[+] Menyalin modul kernel dasar..."
MODULES_TO_COPY="kernel/fs kernel/lib kernel/drivers/block kernel/drivers/ata kernel/drivers/scsi kernel/drivers/usb kernel/drivers/gpu/drm"
mkdir -p "$INITRD_ROOT/lib/modules/$KERNEL_VERSION"
for mod_path in $MODULES_TO_COPY; do
    cp -Rv /lib/modules/$KERNEL_VERSION/$mod_path "$INITRD_ROOT/lib/modules/$KERNEL_VERSION/"
done
depmod -b "$INITRD_ROOT" "$KERNEL_VERSION" # Update dependency modules di initrd

GRAPHICS_MODULES="i915 amdgpu nouveau"

# ==========================
# 3. BUAT SCRIPT INIT SEDERHANA
# ==========================
echo "[+] Membuat skrip init..."
cat > "$INITRD_ROOT/init" << EOF
#!/bin/sh
# Skrip init LiveCD - Hanya untuk /dev/sdb1

export PATH=/bin:/sbin:/usr/bin:/usr/local/bin
SQUASHFS_FILE="$SQUASHFS_FILE"


echo "=== Booting LFS LiveCD ==="
echo "Target device: $LIVE_PARTITION_DEV"

# Mount filesystems dasar
mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t devtmpfs dev /dev

# Initialize udev/mdev untuk device node
/sbin/udevadm trigger
/sbin/udevadm settle

# Muat modul kernel yang diperlukan (termasuk potensi driver grafis)
for mod in $GRAPHICS_MODULES; do
    echo "Memuat \$mod..."
    /sbin/modprobe \$mod 2>/dev/null
done

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
cp -v "/boot/vmlinuz" "$WORKDIR/iso/boot/vmlinuz"

# ==========================
# 5. GRUB CONFIG
# ==========================
echo "[+] Menyiapkan GRUB..."

# Konfigurasi GRUB untuk MBR
cat > "$WORKDIR/iso/boot/grub/grub.cfg" << EOF
set timeout=5
set default=0
menuentry "LeakOS LiveCD" {
    linux /boot/vmlinuz
    initrd /boot/initrd.img
}
EOF

# ==========================
# 6. MEMBUAT ISO HYBRID (HANYA MBR)
# ==========================
echo "[+] Membuat ISO: $ISO_NAME..."


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
echo "==================
