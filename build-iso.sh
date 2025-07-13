#!/bin/bash
# [*] Author: LynxSaiko
set -e

LIVE_NAME="lfs-live"
WORKDIR="/mnt/sdb/livecd"  # Menggunakan /mnt/sdb untuk menyimpan file sementara
ISO_NAME="/mnt/sdb/${LIVE_NAME}.iso"
TARGET_DIR="/mnt/sdb"  # Direktori target untuk menyalin file ke /dev/sdb

# Membuat struktur direktori ISO di /mnt/sdb
echo "[+] Membuat struktur direktori ISO..."
mkdir -pv "$WORKDIR"/{iso/boot/grub,rootfs,initrd}

# ==========================
# COPY ROOTFS
# ==========================
echo "[+] Menyalin root filesystem (minimal)..."
rsync -aAXv /* "$WORKDIR/rootfs" \
  --exclude={"/proc","/sys","/dev","/run","/mnt","/media","/tmp","/home","/boot","/lost+found"}

# ==========================
# MENYIAPKAN COREUTILS
# ==========================
echo "[+] Menyiapkan Coreutils di initramfs..."
cd "$WORKDIR/initrd"
mkdir -pv {bin,sbin,etc,proc,sys,dev,tmp,newroot}

# Salin perintah-perintah dari Coreutils yang dibutuhkan (sesuaikan dengan perintah yang dibutuhkan di initramfs)
cp -v /usr/bin/{ls,cp,mv,rm,cat,echo} "$WORKDIR/initrd/bin/"
chmod +x "$WORKDIR/initrd/bin"/*

# Salin pustaka yang diperlukan (pastikan untuk menyalin pustaka yang dibutuhkan perintah Coreutils)
cp -v /lib/x86_64-linux-gnu/{libc.so.6,ld-linux-x86-64.so.2} "$WORKDIR/initrd/lib/x86_64-linux-gnu/"
chmod +x "$WORKDIR/initrd/lib/x86_64-linux-gnu/"*

# ==========================
# BUAT SCRIPT INIT
# ==========================
echo "[+] Membuat skrip init..."
cat > "$WORKDIR/initrd/init" << "EOF"
#!/bin/sh
# Mount filesystems
mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t devtmpfs dev /dev

# Menyambung ke root filesystem
echo "Switching to rootfs..."
mkdir /newroot
mount -o ro /dev/sdb1 /newroot || mount -o ro /dev/cdrom /newroot

# Menampilkan isi root filesystem untuk verifikasi
ls -l /newroot

# Menyelesaikan proses booting
exec switch_root /newroot /bin/sh
EOF

chmod +x "$WORKDIR/initrd/init"

# ==========================
# BUAT INITRAMFS
# ==========================
echo "[+] Membuat initramfs..."
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
    linux /boot/vmlinuz root=/dev/sdb1 rw
    initrd /boot/initrd.img
}
EOF

# ==========================
# MENYALIN KE /dev/sdb1
# ==========================
echo "[+] Menyalin ISO dan sistem ke /dev/sdb..."
cp -r "$WORKDIR/iso" "$TARGET_DIR/"

# ==========================
# BUILD ISO
# ==========================
echo "[+] Membuat file ISO bootable..."
grub-mkrescue -o "$ISO_NAME" "$WORKDIR/iso"

echo "[✓] ISO selesai dibuat: $ISO_NAME"
