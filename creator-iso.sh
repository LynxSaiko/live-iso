#!/bin/bash
# create-lfs-iso-mbr.sh
# Buat ISO LiveCD dari LFS (BIOS/MBR only, NO UEFI)

set -e

# Configuration
SOURCE_DIR="/"                    # Root filesystem LFS Anda
ISO_NAME="lfs-mbr-$(date +%Y%m%d)"
WORK_DIR="/mnt/leakos"
OUTPUT_DIR="$PWD/iso"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

check_prerequisites() {
    [[ $EUID -eq 0 ]] || error "Harus run sebagai root!"
    
    # Cek tools
    command -v mksquashfs >/dev/null || error "mksquashfs tidak ditemukan!"
    command -v xorriso >/dev/null || error "xorriso tidak ditemukan!"
    command -v genisoimage >/dev/null && HAS_GENISO=1 || HAS_GENISO=0
    
    # Cek kernel
    [[ -f "/boot/vmlinuz" ]] || [[ -f "/boot/bzImage" ]] || error "Kernel tidak ditemukan di /boot/"
    
    log "Source: $SOURCE_DIR"
    log "ISO: $OUTPUT_DIR/$ISO_NAME.iso"
}

prepare_workspace() {
    log "Menyiapkan workspace..."
    
    rm -rf "$WORK_DIR"
    mkdir -p "$WORK_DIR"
    mkdir -p "$OUTPUT_DIR"
    
    # Buat struktur LiveCD
    mkdir -p "$WORK_DIR"/{boot,isolinux,live}
}

get_system_info() {
    # Ambil info distro
    if [[ -f "/etc/os-release" ]]; then
        . /etc/os-release
        DISTRO_NAME="${PRETTY_NAME:-Linux From Scratch}"
    elif [[ -f "/etc/lfs-release" ]]; then
        DISTRO_NAME="Linux From Scratch $(cat /etc/lfs-release)"
    else
        DISTRO_NAME="Linux From Scratch"
    fi
    
    # Cari kernel
    if [[ -f "/boot/vmlinuz" ]]; then
        KERNEL_FILE="/boot/vmlinuz"
    elif [[ -f "/boot/bzImage" ]]; then
        KERNEL_FILE="/boot/bzImage"
    else
        KERNEL_FILE=$(find /boot -name "vmlinuz*" -o -name "bzImage*" | head -1)
    fi
    
    KERNEL_VER=$(file "$KERNEL_FILE" 2>/dev/null | grep -o "version [^ ]*" | cut -d' ' -f2 || echo "unknown")
    
    log "Distro: $DISTRO_NAME"
    log "Kernel: $(basename "$KERNEL_FILE") ($KERNEL_VER)"
}

create_squashfs() {
    log "Membuat filesystem squashfs..."
    
    # Exclude directories
    cat > "$WORK_DIR/exclude.list" << EOF
/boot/*
/dev/*
/proc/*
/sys/*
/tmp/*
/run/*
/mnt/*
/media/*
/lost+found
/var/cache/*
/var/tmp/*
/root/.cache
/home/*/.cache
$WORK_DIR
EOF
    
    mksquashfs "$SOURCE_DIR" "$WORK_DIR/live/filesystem.squashfs" \
        -comp xz \
        -b 1M \
        -no-exports \
        -wildcards \
        -ef "$WORK_DIR/exclude.list" \
        -noappend 2>&1 | tail -5
    
    SQUASHFS_SIZE=$(du -h "$WORK_DIR/live/filesystem.squashfs" | cut -f1)
    log "Squashfs created: $SQUASHFS_SIZE"
}

copy_kernel_initrd() {
    log "Copy kernel dan buat initrd..."
    
    # Copy kernel
    cp "$KERNEL_FILE" "$WORK_DIR/boot/vmlinuz"
    
    # Cek initrd yang ada
    if [[ -f "/boot/initrd.img" ]] || [[ -f "/boot/initramfs.img" ]]; then
        INITRD_FILE=$(ls -1 /boot/init*.img 2>/dev/null | head -1)
        cp "$INITRD_FILE" "$WORK_DIR/boot/initrd.img"
        log "Using existing initrd: $(basename "$INITRD_FILE")"
    else
        # Buat initrd sederhana untuk LiveCD
        create_minimal_initrd
    fi
}

create_minimal_initrd() {
    log "Membuat initrd minimal untuk LiveCD..."
    
    local INITRD_DIR="$WORK_DIR/initrd-tmp"
    rm -rf "$INITRD_DIR"
    mkdir -p "$INITRD_DIR"
    
    # Buat init script
    cat > "$INITRD_DIR/init" << 'EOF'
#!/bin/busybox sh

# Mount essential filesystems
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

# Setup console
exec 0</dev/console
exec 1>/dev/console
exec 2>/dev/console

# Parse kernel cmdline
for x in $(cat /proc/cmdline); do
    case $x in
        root=*) 
            ROOT_DEV=${x#root=}
            ;;
        livecd=*)
            LIVECD=${x#livecd=}
            ;;
    esac
done

echo "=== LFS LiveCD Boot ==="
echo "Looking for Live media..."

# Try to find CD/DVD or USB
for dev in /dev/sr0 /dev/sr1 /dev/cdrom /dev/hd* /dev/sd*; do
    [ -b "$dev" ] || continue
    echo "Trying $dev..."
    mount -t iso9660 -o ro "$dev" /mnt 2>/dev/null
    if [ $? -eq 0 ] && [ -f /mnt/live/filesystem.squashfs ]; then
        echo "Found LiveCD at $dev"
        break
    fi
    umount /mnt 2>/dev/null
done

# Mount squashfs
if [ -f /mnt/live/filesystem.squashfs ]; then
    echo "Mounting root filesystem..."
    mkdir /rootfs
    mount -t squashfs -o loop /mnt/live/filesystem.squashfs /rootfs
    
    # Setup overlay filesystem
    mkdir /overlay /ramdisk
    mount -t tmpfs tmpfs /ramdisk
    mkdir -p /ramdisk/upper /ramdisk/work
    
    mount -t overlay overlay \
        -o lowerdir=/rootfs,upperdir=/ramdisk/upper,workdir=/ramdisk/work \
        /new_root
        
    # Cleanup
    umount /mnt
    
    # Switch to new root
    echo "Switching to root filesystem..."
    exec switch_root /new_root /sbin/init
else
    echo "ERROR: Cannot find LiveCD filesystem!"
    echo "Dropping to emergency shell..."
    exec /bin/sh
fi
EOF
    
    chmod +x "$INITRD_DIR/init"
    
    # Download busybox static binary
    if ! wget -q -O "$INITRD_DIR/busybox" \
        "https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox"; then
        # Fallback: copy from system if available
        cp /bin/busybox "$INITRD_DIR/busybox" 2>/dev/null || \
        error "Cannot get busybox binary"
    fi
    chmod +x "$INITRD_DIR/busybox"
    
    # Create essential directories
    mkdir -p "$INITRD_DIR"/{bin,dev,proc,sys,mnt,new_root,rootfs,ramdisk,overlay}
    
    # Create device nodes
    mknod "$INITRD_DIR/dev/console" c 5 1
    mknod "$INITRD_DIR/dev/null" c 1 3
    mknod "$INITRD_DIR/dev/zero" c 1 5
    
    # Create busybox symlinks
    cd "$INITRD_DIR"
    ./busybox --install -s .
    
    # Create cpio archive
    find . | cpio -H newc -o | gzip -9 > "$WORK_DIR/boot/initrd.img"
    
    INITRD_SIZE=$(du -h "$WORK_DIR/boot/initrd.img" | cut -f1)
    log "Initrd created: $INITRD_SIZE"
}

setup_isolinux() {
    log "Setup ISOLINUX (BIOS bootloader)..."
    
    # Download syslinux jika belum ada
    if [[ ! -f "/usr/lib/ISOLINUX/isolinux.bin" ]]; then
        log "Downloading syslinux..."
        wget -q -O "$WORK_DIR/syslinux.tar.gz" \
            "https://mirrors.edge.kernel.org/pub/linux/utils/boot/syslinux/syslinux-6.03.tar.gz"
        tar -xzf "$WORK_DIR/syslinux.tar.gz" -C "$WORK_DIR"
        SYSLINUX_DIR="$WORK_DIR/syslinux-6.03"
    else
        SYSLINUX_DIR="/usr/lib/ISOLINUX/.."
    fi
    
    # Copy isolinux files
    if [[ -f "/usr/lib/ISOLINUX/isolinux.bin" ]]; then
        cp /usr/lib/ISOLINUX/isolinux.bin "$WORK_DIR/isolinux/"
        cp /usr/lib/syslinux/modules/bios/ldlinux.c32 "$WORK_DIR/isolinux/"
        cp /usr/lib/syslinux/modules/bios/libutil.c32 "$WORK_DIR/isolinux/"
        cp /usr/lib/syslinux/modules/bios/menu.c32 "$WORK_DIR/isolinux/"
        cp /usr/lib/syslinux/modules/bios/chain.c32 "$WORK_DIR/isolinux/"
    elif [[ -f "$SYSLINUX_DIR/bios/core/isolinux.bin" ]]; then
        cp "$SYSLINUX_DIR/bios/core/isolinux.bin" "$WORK_DIR/isolinux/"
        cp "$SYSLINUX_DIR/bios/com32/elflink/ldlinux/ldlinux.c32" "$WORK_DIR/isolinux/"
        cp "$SYSLINUX_DIR/bios/com32/libutil/libutil.c32" "$WORK_DIR/isolinux/"
        cp "$SYSLINUX_DIR/bios/com32/menu/menu.c32" "$WORK_DIR/isolinux/"
        cp "$SYSLINUX_DIR/bios/com32/chain/chain.c32" "$WORK_DIR/isolinux/"
    else
        warn "ISOLINUX files not found, trying to find alternatives..."
        find /usr -name "isolinux.bin" -exec cp {} "$WORK_DIR/isolinux/" \; 2>/dev/null || true
        find /usr -name "*.c32" -exec cp {} "$WORK_DIR/isolinux/" \; 2>/dev/null | head -5
    fi
    
    # Buat isolinux.cfg
    cat > "$WORK_DIR/isolinux/isolinux.cfg" << EOF
UI menu.c32
PROMPT 0
MENU TITLE $DISTRO_NAME LiveCD
TIMEOUT 300
DEFAULT live

MENU COLOR screen       37;40   #80ffffff #00000000 std
MENU COLOR border       30;44   #40ffffff #a0000000 std
MENU COLOR title        1;36;44 #ff33ccff #a0000000 std
MENU COLOR sel          7;37;40 #e0ffffff #20ffffff all
MENU COLOR unsel        37;44   #50ffffff #a0000000 std
MENU COLOR help         37;40   #c0ffffff #a0000000 std

LABEL live
  MENU LABEL ^Boot $DISTRO_NAME Live
  MENU DEFAULT
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/initrd.img root=live:CDLABEL=LFS_LIVE quiet splash
  
LABEL live-nomodeset
  MENU LABEL Boot Live (^nomodeset)
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/initrd.img root=live:CDLABEL=LFS_LIVE nomodeset quiet
  
LABEL memtest
  MENU LABEL ^Memory Test
  KERNEL /boot/memtest86+.bin
  
LABEL hdt
  MENU LABEL ^Hardware Detection Tool
  COM32 hdt.c32
  
LABEL reboot
  MENU LABEL Re^boot
  COM32 reboot.c32
  
LABEL poweroff
  MENU LABEL ^Power Off
  COM32 poweroff.c32
EOF
    
    # Copy memtest86+ jika ada
    if [[ -f "/boot/memtest86+.bin" ]]; then
        cp /boot/memtest86+.bin "$WORK_DIR/boot/"
    elif [[ -f "/usr/share/memtest86+/memtest.bin" ]]; then
        cp /usr/share/memtest86+/memtest.bin "$WORK_DIR/boot/memtest86+.bin"
    fi
}

create_iso_mbr() {
    log "Membuat ISO image (MBR/BIOS only)..."
    
    # Method 1: Menggunakan xorriso (lebih baik)
    if command -v xorriso >/dev/null; then
        log "Menggunakan xorriso..."
        
        xorriso -as mkisofs \
            -iso-level 3 \
            -full-iso9660-filenames \
            -volid "LFS_LIVE" \
            -eltorito-boot isolinux/isolinux.bin \
            -eltorito-catalog isolinux/boot.cat \
            -no-emul-boot \
            -boot-load-size 4 \
            -boot-info-table \
            -isohybrid-mbr /usr/lib/syslinux/isohdpfx.bin 2>/dev/null \
            -output "$OUTPUT_DIR/$ISO_NAME.iso" \
            "$WORK_DIR"
            
    # Method 2: Menggunakan genisoimage
    elif [[ $HAS_GENISO -eq 1 ]]; then
        log "Menggunakan genisoimage..."
        
        genisoimage -U -r -v -J -joliet-long \
            -V "LFS_LIVE" \
            -b isolinux/isolinux.bin \
            -c isolinux/boot.cat \
            -no-emul-boot \
            -boot-load-size 4 \
            -boot-info-table \
            -o "$OUTPUT_DIR/$ISO_NAME.iso" \
            "$WORK_DIR"
            
    # Method 3: Menggunakan mkisofs
    elif command -v mkisofs >/dev/null; then
        log "Menggunakan mkisofs..."
        
        mkisofs -U -r -v \
            -V "LFS_LIVE" \
            -b isolinux/isolinux.bin \
            -c isolinux/boot.cat \
            -no-emul-boot \
            -boot-load-size 4 \
            -boot-info-table \
            -o "$OUTPUT_DIR/$ISO_NAME.iso" \
            "$WORK_DIR"
    else
        error "Tidak ada tool untuk membuat ISO!"
    fi
    
    # Buat ISO hybrid untuk USB (optional)
    if command -v isohybrid >/dev/null; then
        log "Membuat ISO hybrid (bisa untuk USB)..."
        isohybrid "$OUTPUT_DIR/$ISO_NAME.iso" 2>/dev/null && \
        log "ISO sudah dijadikan hybrid (bisa dd ke USB)"
    fi
}

cleanup() {
    log "Cleaning up..."
    rm -rf "$WORK_DIR"
}

show_summary() {
    echo ""
    echo "========================================"
    echo "LFS LIVE ISO CREATION COMPLETE!"
    echo "========================================"
    echo "ISO File: $OUTPUT_DIR/$ISO_NAME.iso"
    echo "Size: $(du -h "$OUTPUT_DIR/$ISO_NAME.iso" | cut -f1)"
    echo ""
    echo "Boot mode: BIOS/MBR ONLY (NO UEFI)"
    echo ""
    echo "Untuk burn ke CD/DVD:"
    echo "  wodim -v dev=/dev/sr0 \"$OUTPUT_DIR/$ISO_NAME.iso\""
    echo ""
    echo "Untuk burn ke USB (dd method):"
    echo "  sudo dd if=\"$OUTPUT_DIR/$ISO_NAME.iso\" of=/dev/sdX bs=4M status=progress"
    echo ""
    echo "Untuk burn ke USB (hybrid ISO):"
    echo "  sudo cp \"$OUTPUT_DIR/$ISO_NAME.iso\" /path/to/ventoy/usb/"
    echo "  # Atau pakai Etcher, Rufus, dll."
    echo ""
    echo "Konten ISO:"
    echo "  - Kernel: /boot/vmlinuz"
    echo "  - Initrd: /boot/initrd.img"
    echo "  - RootFS: /live/filesystem.squashfs"
    echo "========================================"
}

main() {
    check_prerequisites
    prepare_workspace
    get_system_info
    create_squashfs
    copy_kernel_initrd
    setup_isolinux
    create_iso_mbr
    cleanup
    show_summary
}

# Run
main "$@"
