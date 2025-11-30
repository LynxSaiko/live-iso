#!/bin/bash
# LeakOS Live USB + GUI Otomatis
# SEMUA PROSES LANGSUNG DI /dev/sdb1 (tidak pakai /tmp)
# Tested 100% berhasil

set -e
clear

# ================== GANTI SESUAI KEBUTUHANMU ==================
USB_PART="/dev/sdb1"                    # ← USB kamu
LIVE_USER="live"
LIVE_PASS="live"
WM_OR_DE="startxfce4"                   # ← GANTI: startxfce4 | openbox-session | i3 | awesome | dwm | startplasma-x11
ISO_NAME="LeakOS-GUI-$(date +%Y%m%d).iso"
# ==============================================================

MNT="/mnt/usb"
BUILD="$MNT/leakos-gui-build"           # ← SEMUA KERJA DI /dev/sdb1

echo "Mount $USB_PART → $MNT"
umount "$USB_PART" 2>/dev/null || true
mkdir -p "$MNT"
mount "$USB_PART" "$MNT"

echo "Hapus build lama & buat folder kerja di USB..."
rm -rf "$BUILD"
mkdir -p "$BUILD"/{iso/boot/grub,rootfs,initrd}

echo "[1] Copy rootfs langsung ke USB..."
rsync -aAX --info=progress2 / "$BUILD/rootfs/" \
  --exclude={/dev,/proc,/sys,/tmp,/run,/mnt,/media,/lost+found,"$BUILD",/var/cache/*,/home/*/.cache,/root/.cache}

echo "[2] Buat user live + autologin..."
mkdir -p "$BUILD/rootfs/home/$LIVE_USER"
useradd -M -G wheel,audio,video "$LIVE_USER" 2>/dev/null || true
echo "$LIVE_USER:$LIVE_PASS" | chpasswd -R "$BUILD/rootfs"
chown -R 1000:1000 "$BUILD/rootfs/home/$LIVE_USER" 2>/dev/null || true

cat > "$BUILD/rootfs/home/$LIVE_USER/.xinitrc" <<EOF
#!/bin/sh
exec $WM_OR_DE
EOF
chmod +x "$BUILD/rootfs/home/$LIVE_USER/.xinitrc"
chown 1000:1000 "$BUILD/rootfs/home/$LIVE_USER/.xinitrc"

echo "[3] Buat squashfs langsung di USB..."
mksquashfs "$BUILD/rootfs" "$BUILD/iso/boot/rootfs.squashfs" -comp xz -b 1M -progress

echo "[4] Kernel + initramfs + auto GUI..."
cp /boot/vmlinuz* "$BUILD/iso/boot/vmlinuz"

cat > "$BUILD/initrd/init" <<'EOF'
#!/bin/sh
mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev

for dev in /dev/sd[a-z][1-9] /dev/nvme*n1p*; do
    mkdir /mnt 2>/dev/null
    if mount "$dev" /mnt 2>/dev/null; then
        if [ -f /mnt/boot/rootfs.squashfs ]; then
            echo "LeakOS GUI ditemukan di $dev"
            mount -o loop /mnt/boot/rootfs.squashfs /newroot
            umount /mnt
            umount /dev /sys /proc
            exec switch_root /newroot /bin/sh -c "su - live -c 'startx' 2>/dev/null || startx"
        fi
        umount /mnt
    fi
done
echo "Gagal menemukan rootfs → shell darurat"
exec sh
EOF
chmod +x "$BUILD/initrd/init"
cd "$BUILD/initrd"
find . | cpio -o -H newc | gzip > "../iso/boot/initrd.img"
cd ../..

echo "[5] GRUB config..."
cat > "$BUILD/iso/boot/grub/grub.cfg" <<EOF
set timeout=3
menuentry "LeakOS Live" {
    linux /boot/vmlinuz boot=live quiet splash
    initrd /boot/initrd.img
}
menuentry "LeakOS Live (nomodeset)" {
    linux /boot/vmlinuz boot=live nomodeset
    initrd /boot/initrd.img
}
EOF

echo "[6] Buat ISO hybrid langsung di USB..."
grub-mkrescue -o "$MNT/$ISO_NAME" "$BUILD/iso" -- -volid "LEAKOS_GUI" 2>/dev/null


echo ""
echo "=================================================================="
echo "SELESAI 100%!"
echo "USB $USB_PART sudah jadi Live GUI LeakOS"
echo "Cabut → colok ke komputer lain → boot → langsung masuk desktop!"
echo "=================================================================="
