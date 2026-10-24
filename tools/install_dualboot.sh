#!/bin/sh
# tools/install_dualboot.sh: Automated, Non-Destructive Persistent Dual-Boot Installer for gbOS86
# Installs gbOS86 on a target disk alongside existing Windows and Linux (Ubuntu) installations.
# Usage: sudo tools/install_dualboot.sh --target /dev/sdX [options]

set -e

ROOT=$(cd "$(dirname "$0")/.." && pwd)
U=$ROOT/usb
TARGET_DISK=""
EFI_PART=""
SYS_SIZE="10G"
META_SIZE="64M"
DATA_SIZE="64G"
REFORMAT=0
DRY_RUN=0
SKIP_DOWNLOAD=0

say() { printf '\n== %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: sudo $0 --target <disk> [options]

Options:
  --target <disk>      Target disk device (e.g. /dev/sda, /dev/sdb). REQUIRED.
  --efi-part <part>    EFI partition to use (default: auto-detected, e.g. /dev/sda2).
  --sys-size <size>    Size of GBOSSYS partition (default: 10G).
  --meta-size <size>   Size of GBOS_META partition (default: 64M).
  --data-size <size>   Size of GBOS_DATA partition (default: 64G).
  --reformat           Re-format existing gbOS86 partitions.
  --dry-run            Simulate operations without writing changes.
  -h, --help           Show this help message.

Example:
  sudo $0 --target /dev/sda
EOF
  exit "${1:-1}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGET_DISK="$2"; shift 2;;
    --efi-part) EFI_PART="$2"; shift 2;;
    --sys-size) SYS_SIZE="$2"; shift 2;;
    --meta-size) META_SIZE="$2"; shift 2;;
    --data-size) DATA_SIZE="$2"; shift 2;;
    --reformat) REFORMAT=1; shift;;
    --dry-run) DRY_RUN=1; shift;;
    -h|--help) usage 0;;
    *) die "Unknown argument: $1";;
  esac
done

[ -n "$TARGET_DISK" ] || usage 1
[ -b "$TARGET_DISK" ] || die "$TARGET_DISK is not a valid block device."

# Safety guard against accidental NVMe root wipe
if [ "$(id -u)" -ne 0 ]; then
  die "This script requires root privileges. Please run with sudo."
fi

say "Target disk: $TARGET_DISK"

# Auto-detect EFI partition if not specified
if [ -z "$EFI_PART" ]; then
  for p in $(lsblk -rn -o NAME,PARTTYPE "$TARGET_DISK" 2>/dev/null | awk '$2 ~ /c12a7328-f81f-11d2-ba4b-00a0c93ec93b/i {print $1}'); do
    EFI_PART="/dev/$p"
    break
  done
  if [ -z "$EFI_PART" ]; then
    # Fallback to partition 1 or 2 if labeled EFI / SYSTEM
    for p in $(lsblk -rn -o NAME,LABEL "$TARGET_DISK" 2>/dev/null | awk '$2 ~ /^(EFI|SYSTEM|ESP|GBOS_EFI)$/i {print $1}'); do
      EFI_PART="/dev/$p"
      break
    done
  fi
fi

[ -n "$EFI_PART" ] && [ -b "$EFI_PART" ] || die "Could not identify EFI partition on $TARGET_DISK. Specify with --efi-part."
say "EFI partition: $EFI_PART"

# Check for existing GBOS partitions
SYS_PART=$(lsblk -rn -o NAME,LABEL "$TARGET_DISK" 2>/dev/null | awk '$2=="GBOSSYS"{print "/dev/"$1; exit}')
META_PART=$(lsblk -rn -o NAME,LABEL "$TARGET_DISK" 2>/dev/null | awk '$2=="GBOS_META"{print "/dev/"$1; exit}')
DATA_PART=$(lsblk -rn -o NAME,LABEL "$TARGET_DISK" 2>/dev/null | awk '$2=="GBOS_DATA"{print "/dev/"$1; exit}')

case "$TARGET_DISK" in
  *[0-9]) P_PREFIX="${TARGET_DISK}p";;
  *) P_PREFIX="${TARGET_DISK}";;
esac

if [ -n "$SYS_PART" ] && [ -n "$META_PART" ] && [ -n "$DATA_PART" ]; then
  say "Found existing gbOS86 partitions on $TARGET_DISK:"
  echo "  GBOSSYS:   $SYS_PART"
  echo "  GBOS_META: $META_PART"
  echo "  GBOS_DATA: $DATA_PART"
  ALREADY_PARTITIONED=1
else
  ALREADY_PARTITIONED=0
  SYS_PART="${P_PREFIX}3"
  META_PART="${P_PREFIX}4"
  DATA_PART="${P_PREFIX}5"
fi

if [ $DRY_RUN -eq 1 ]; then
  say "[DRY RUN] Would install gbOS86 on $TARGET_DISK without wiping existing OS partitions."
  exit 0
fi

# Partition if not already present
if [ $ALREADY_PARTITIONED -eq 0 ]; then
  command -v sgdisk >/dev/null 2>&1 || die "sgdisk is required to partition $TARGET_DISK non-destructively."
  say "Creating gbOS86 partitions non-destructively..."
  sgdisk \
    -n 3:0:+"$SYS_SIZE"  -t 3:0700 -c 3:"GBOSSYS" \
    -n 4:0:+"$META_SIZE" -t 4:8300 -c 4:"GBOS_META" \
    -n 5:0:+"$DATA_SIZE" -t 5:8300 -c 5:"GBOS_DATA" \
    "$TARGET_DISK"
  partprobe "$TARGET_DISK" 2>/dev/null || sleep 2
fi

# Format partitions
if [ $ALREADY_PARTITIONED -eq 0 ] || [ $REFORMAT -eq 1 ]; then
  say "Formatting partitions..."
  mkfs.vfat -F 32 -n GBOSSYS "$SYS_PART"
  mkfs.ext4 -F -L GBOS_META "$META_PART"
  mkfs.ext4 -F -O verity -L GBOS_DATA "$DATA_PART"
fi

# Populate GBOSSYS
MNT_SYS=$(mktemp -d)
trap 'umount "$MNT_SYS" 2>/dev/null; rmdir "$MNT_SYS" 2>/dev/null' EXIT INT TERM
mount "$SYS_PART" "$MNT_SYS"

say "Copying system files to $SYS_PART (GBOSSYS)..."
mkdir -p "$MNT_SYS/EFI/BOOT" "$MNT_SYS/gbos/logs"
[ -f "$U/out/BOOTX64.EFI" ] && cp "$U/out/BOOTX64.EFI" "$MNT_SYS/EFI/BOOT/BOOTX64.EFI"
[ -f "$ROOT/kernel/out/busybox" ] && cp "$ROOT/kernel/out/busybox" "$MNT_SYS/busybox"

for f in hook.sh optimize.sh aidiag.sh early_patch.sh hwdetect.sh install.sh apex_patch.sh gbos.cfg \
         crossystem bootdisk.img libkm_compat.so system_ext_manifest.xml soft_gk; do
  [ -f "$U/$f" ] && cp "$U/$f" "$MNT_SYS/gbos/$f"
done

for d in firmware patched audio installer kmod modules surface ksu; do
  [ -d "$U/$d" ] && { mkdir -p "$MNT_SYS/gbos/$d"; cp -R "$U/$d/." "$MNT_SYS/gbos/$d/"; }
done

# If super.img is in dist or build, copy it
for s in "$ROOT/dist" "$ROOT/build"; do
  if [ -f "$s/super.img" ]; then
    say "Copying $s/super.img..."
    cp "$s/super.img" "$MNT_SYS/gbos/super.img"
    [ -f "$s/super.layout" ] && cp "$s/super.layout" "$MNT_SYS/gbos/super.layout"
    break
  fi
done

# Ensure MODE=boot in gbos.cfg
sed -i 's/^MODE=.*/MODE=boot/' "$MNT_SYS/gbos/gbos.cfg" 2>/dev/null || true

# Copy kernel to EFI partition
MNT_EFI=$(mktemp -d)
mount "$EFI_PART" "$MNT_EFI"
mkdir -p "$MNT_EFI/EFI/gbos86"
if [ -f "$U/out/BOOTX64.EFI" ]; then
  cp "$U/out/BOOTX64.EFI" "$MNT_EFI/EFI/gbos86/BOOTX64.EFI"
  say "Installed gbOS86 UEFI kernel to $EFI_PART -> EFI/gbos86/BOOTX64.EFI"
fi
umount "$MNT_EFI" && rmdir "$MNT_EFI"

# Configure GRUB 40_custom if running on Linux with GRUB
if [ -d /etc/grub.d ] && command -v update-grub >/dev/null 2>&1; then
  SYS_UUID=$(blkid -s UUID -o value "$SYS_PART" 2>/dev/null || true)
  if [ -n "$SYS_UUID" ] && ! grep -q "Googlebook OS" /etc/grub.d/40_custom 2>/dev/null; then
    say "Adding gbOS86 dual-boot menu entry to /etc/grub.d/40_custom..."
    cat <<GRUB_EOF >> /etc/grub.d/40_custom

menuentry "Googlebook OS (gbOS86 persistent)" --class android --class gnu-linux --class os {
    insmod part_gpt
    insmod fat
    search --no-floppy --fs-uuid --set=root $SYS_UUID
    chainloader /EFI/BOOT/BOOTX64.EFI
}
GRUB_EOF
    update-grub || true
  fi
fi

sync
say "gbOS86 persistent dual-boot installation complete!"
echo "Reboot and select gbOS86 from GRUB or your UEFI boot menu (F12)."
