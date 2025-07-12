#!/bin/bash
# [*] Author: LynxSaiko
set -e

LIVE_NAME="lfs-live"
WORKDIR="$HOME/livecd"
ISO_NAME="$HOME/${LIVE_NAME}.iso"

echo "[+] Membuat struktur direktori ISO..."
mkdir -pv "$WORKDIR"/{iso/boot/grub,rootfs,initrd}

# ==========================
# COPY ROOTFS
# ==========================
echo "[+] Menyalin root filesystem (minimal)..."
rsync -aAX /* "$WORKDIR/rootfs" \
  --exclude={"/proc","/sys","/dev","/run","/mnt","/media","/tmp","/home","/boot","/lost+found"}

# ==========================
# INITRAMFS
# ==========================
echo "[+] Menyiapkan initramfs..."
cd "$WORKDIR/initrd"
mkdir -pv {bin,sbin,etc,proc,sys,dev,tmp,newroot}

# ⚠️ Asumsi: busybox sudah kamu salin dan siap pakai
# Misal kamu punya di /usr/bin/busybox atau /bin/busybox
cp -v /bin/busybox bin/
chmod +x bin/busybox
cd bin && ln -sf busybox sh && cd ..

# Buat skrip init
cat > init << "EOF"
#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t devtmpfs dev /dev

echo "Switching to rootfs..."
mkdir /newroot
mount -o ro /dev/sr0 /newroot || mount -o ro /dev/cdrom /newroot

exec switch_root /newroot /bin/sh
EOF

chmod +x init

# Buat initramfs
cd "$WORKDIR/initrd"
find . -print0 | cpio --null -ov --format=newc | gzip -9 > "$WORKDIR/iso/boot/initrd.img"

# ==========================
# COPY KERNEL
# ==========================
echo "[+] Menyalin kernel..."
cp -v /boot/vmlinuz-* "$WORKDIR/iso/boot/vmlinuz"

# ==========================
# GRUB CONFIG
# ==========================
cat > "$WORKDIR/iso/boot/grub/grub.cfg" << "EOF"
set timeout=5
set default=0

menuentry "LFS Live ISO" {
    linux /boot/vmlinuz root=/dev/ram0 rw
    initrd /boot/initrd.img
}
EOF

# ==========================
# BUILD ISO
# ==========================
echo "[+] Membuat file ISO bootable..."
grub-mkrescue -o "$ISO_NAME" "$WORKDIR/iso"

echo "[✓] ISO selesai dibuat: $ISO_NAME"
