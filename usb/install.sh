# gbOS86 installer/updater for the laptop's internal disk: NVMe, eMMC or SATA (M.2 SATA / 2.5"). Sourced by stage0 for menu choice 2 (or gbos.cfg
# MODE=install), after the stick is mounted at /gbos ($G=/gbos/gbos, log dir $L, stick partition $DEV) and drivers loaded.
#
# ERASES THE WHOLE TARGET DISK and lays it out as:
#   p1 GBOS_EFI   512 MiB FAT32, EFI system partition: EFI/BOOT/BOOTX64.EFI (this kernel + stage0)
#   p2 GBOSSYS      8 GiB FAT32: gbos/ as on the stick (super.img, hook.sh, firmware, ...)
#   p3 GBOS_META   64 MiB ext4: Android /metadata
#   p4 GBOS_DATA   rest   ext4: Android /data
# Nothing is written until the disk's serial number is typed (eMMC: the MMC serial, or its CID if that is empty or zero; SATA: the drive's serial). Every copied file is checked with
# sha256 after being read back from the disk. Never returns: powers off or waits on failure.

I=$G/installer
tool() { $I/lib/ld-musl-x86_64.so.1 --library-path $I/lib $I/bin/"$@"; }
TTY=/dev/tty1
say() { echo "$*" > $TTY; echo "$*" >> $L/install.log; log "install: $*"; }
halt_here() { say ""; say "$1"; say "Power off with the power button."; sync; while true; do sleep 3600; done; }
# save_logs MOUNTED_GBOS_DIR [BOOTS]: copy the installed system's last BOOTS (default 3) boot-N log dirs to
# this boot's log dir on the stick (gbos/logs/boot-N/nvme-logs). A file FAT can't read in full (cluster chain
# cut short by a power-off) is copied with dd conv=noerror,sync instead of failing; the tail is then NULs.
save_logs() {
  mkdir -p $L/nvme-logs
  for b in $(ls $1/logs | sort -t- -k2 -n | tail -n ${2:-3}); do
    say "  $b"
    (cd $1/logs && find $b -type d) | while read d; do mkdir -p $L/nvme-logs/$d; done
    (cd $1/logs && find $b -type f) | while read f; do
      cp $1/logs/$f $L/nvme-logs/$f 2>/dev/null || dd if=$1/logs/$f of=$L/nvme-logs/$f bs=4k conv=noerror,sync 2>/dev/null
    done
  done
  sync
}
die() { halt_here "INSTALL FAILED: $*  (log: gbos/logs/boot-$N/install.log on the stick)"; }
ask() { printf '%s' "$1" > $TTY; read -r REPLY < $TTY; echo "$1$REPLY" >> $L/install.log; }
# check SOURCE COPY: byte-for-byte compare (the page cache is dropped before verifying, so this re-reads the copy from the disk). Much
# faster than hashing both files with busybox's software sha256 (that took minutes for the 5 GB system image).
check() { cmp -s "$1" "$2" || die "verify failed: $2"; echo "ok $2" >> $L/install.log; }

# Big items (system image, firmware, modules) are skipped on update when nothing about them changed since the last VERIFIED copy.
# A "stamp" is a hash of an item's file names, sizes and modification times on the stick. It is saved on the SSD (gbos/.stamps/) only
# after the copy was verified, so the next update compares two short strings instead of reading ~5.5 GB twice and re-copying ~400 MB.
# Replacing an item on the stick changes its file times, so a stale stamp cannot hide a real change. UPDATE_FULL=1 in gbos.cfg, or a
# missing stamp, forces the full compare, copy and verify.
STAMPED="super.img firmware modules"
stamp_of() { _l=$(find "$G/$1" -type f -exec stat -c '%n %s %Y' {} + 2>/dev/null | sort); [ -n "$_l" ] || return 1; printf '%s\n' "$_l" | sha256sum | cut -d' ' -f1; }
stamp_same() { [ -z "$UPDATE_FULL" ] && [ -f /mnt/nsys/gbos/.stamps/$1 ] && _s=$(stamp_of $1) && [ "$(cat /mnt/nsys/gbos/.stamps/$1)" = "$_s" ]; }
stamp_save() { _s=$(stamp_of $1) && mkdir -p /mnt/nsys/gbos/.stamps && printf '%s\n' "$_s" > /mnt/nsys/gbos/.stamps/$1; }
is_skipped() { case " $SKIP " in *" $1 "*) return 0;; esac; return 1; }

# Write the installed system's gbos.cfg from the stick's: it boots normally.
write_installed_cfg() {
  grep -v -e '^MODE=' -e '^ACTION=' $G/gbos.cfg > /mnt/nsys/gbos/gbos.cfg
  echo 'MODE=boot' >> /mnt/nsys/gbos/gbos.cfg
}

chvt 1 2>/dev/null
clear > $TTY 2>/dev/null
say "=============================================================="
say " gbOS86 installer"
say "=============================================================="

# Everything this needs must be on the stick before anything is touched.
STICKDISK=$(basename $(readlink -f /sys/class/block/${DEV##*/}/..))
EFIPART=/dev/$(ls /sys/class/block/$STICKDISK | grep -m1 "^${STICKDISK}p\?1$")
mkdir -p /mnt/stickefi && mount -t vfat -o ro $EFIPART /mnt/stickefi 2>/dev/null \
  || die "cannot mount the stick's EFI partition ($EFIPART)"
KERNEL=/mnt/stickefi/EFI/BOOT/BOOTX64.EFI
FILES="super.img super.layout hook.sh aidiag.sh early_patch.sh hwdetect.sh apex_patch.sh crossystem bootdisk.img libkm_compat.so system_ext_manifest.xml soft_gk"
DIRS="firmware patched audio installer kmod modules surface ksu"
for f in $FILES; do [ -f $G/$f ] || die "missing gbos/$f on the stick"; done
for d in $DIRS; do [ -d $G/$d ] || die "missing gbos/$d/ on the stick"; done
[ -f $KERNEL ] || die "missing EFI/BOOT/BOOTX64.EFI on the stick's EFI partition"
tool sfdisk --version > /dev/null 2>&1 || die "partitioning tools in gbos/installer/ don't run"

# ACTION=update in gbos.cfg: don't erase anything. Save the installed system's last 3 boots of logs
# to this boot's log dir on the stick, then bring its gbos/ files and kernel up to the stick's.
# GBOS_DATA and GBOS_META (apps, accounts, settings) are not touched.
# The EFI partition of the internal disk that holds $1 (GBOSSYS). The stick's own EFI partition is also labelled EFI, so a label lookup
# can return the wrong one: take the EFI system partition (GPT type) from the same disk, labels only as a fallback.
internal_efi() {
  [ -b "$1" ] || return 0
  _d=/dev/$(basename "$(readlink -f /sys/class/block/$(basename $1)/..)")
  _e=$(tool sfdisk -d $_d 2>/dev/null | awk 'toupper($0) ~ /TYPE=C12A7328-F81F-11D2-BA4B-00A0C93EC93B/ {print $1; exit}')
  [ -n "$_e" ] || _e=$(findfs LABEL=GBOS_EFI 2>/dev/null)
  [ -n "$_e" ] || _e=$(findfs LABEL=EFI 2>/dev/null)
  [ -n "$_e" ] || _e=$(findfs LABEL=SYSTEM 2>/dev/null)
  echo "$_e"
}
NSYS=$(findfs LABEL=GBOSSYS 2>/dev/null)
NEFI=$(internal_efi $NSYS)
NDATA=$(findfs LABEL=GBOS_DATA 2>/dev/null)
if [ -z "$ACTION" ] && [ -n "$NSYS" ] && [ -n "$NDATA" ]; then
  # An install exists: never erase it just because the stick was left in. Ask.
  say "Found an existing gbOS86 install on the internal disk."
  say "  1) Update it: keep apps, accounts and settings; save its logs to this stick"
  say "  2) Reinstall: ERASE the disk and install from scratch"
  say "  3) Only save its logs to this stick (nothing on the disk is changed)"
  say "  anything else: cancel"
  ask "choice> "
  case "$REPLY" in 1) ACTION=update;; 2) ACTION=install;; 3) ACTION=logs;; *) halt_here "Cancelled. Nothing was written.";; esac
fi
# ACTION=logs (menu choice 3, or ACTION=logs in gbos.cfg): read-only on the internal disk, takes seconds.
# LOG_BOOTS in gbos.cfg = how many of the installed system's last boots to copy (default 3).
if [ "$ACTION" = logs ]; then
  [ -n "$NSYS" ] || die "no gbos install on the internal disk (GBOSSYS not found)"
  mkdir -p /mnt/nsys
  mount -t vfat -o ro $NSYS /mnt/nsys || die "mount GBOSSYS failed"
  [ -d /mnt/nsys/gbos/logs ] || die "the installed system has no gbos/logs"
  say "Saving the installed system's last ${LOG_BOOTS:-3} boots of logs to the stick (gbos/logs/boot-$N/nvme-logs) ..."
  save_logs /mnt/nsys/gbos ${LOG_BOOTS:-3}
  umount /mnt/nsys; sync
  say ""
  say "Logs saved. Remove the USB stick and turn the laptop back on."
  log "install: logs saved"; sync
  ask "Press Enter to power off. "
  poweroff -f
fi
if [ "${ACTION:-install}" = update ]; then
  NSYS=$(findfs LABEL=GBOSSYS 2>/dev/null)
  NEFI=$(internal_efi $NSYS)
  [ -n "$NSYS" ] && [ -n "$NEFI" ] || die "no gbos install on the internal disk (GBOSSYS/EFI not found)"
  mkdir -p /mnt/nsys /mnt/nefi
  mount -t vfat -o flush $NSYS /mnt/nsys || die "mount GBOSSYS failed"
  mount -t vfat $NEFI /mnt/nefi || die "mount EFI failed"
  # A dual-boot install keeps its kernel in the machine's own EFI partition as EFI/gbos86/BOOTX64.EFI. An EFI partition that is not ours
  # (not labelled GBOS_EFI) without that file is some other OS's: never write to it.
  SHARED_EFI=0; [ -f /mnt/nefi/EFI/gbos86/BOOTX64.EFI ] && SHARED_EFI=1
  [ "$NEFI" = "$(findfs LABEL=GBOS_EFI 2>/dev/null)" ] || [ $SHARED_EFI = 1 ] || die "$NEFI is not a gbOS86 EFI partition (no EFI/gbos86/BOOTX64.EFI); nothing was changed"
  say "Saving the installed system's logs to the stick (gbos/logs/boot-$N/nvme-logs) ..."
  save_logs /mnt/nsys/gbos 3
  say "Updating the installed system (data is not touched) ..."
  SKIP=""
  for f in $FILES; do
    case " $STAMPED " in *" $f "*) if stamp_same $f; then SKIP="$SKIP $f"; say "  $f unchanged, skipped"; continue; fi;; esac
    cmp -s $G/$f /mnt/nsys/gbos/$f || { say "  $f"; cp $G/$f /mnt/nsys/gbos/$f || die "copy $f failed"; }
  done
  for d in $DIRS; do
    case " $STAMPED " in *" $d "*) if stamp_same $d; then SKIP="$SKIP $d"; say "  $d/ unchanged, skipped"; continue; fi;; esac
    say "  $d/"; rm -rf /mnt/nsys/gbos/$d; cp -r $G/$d /mnt/nsys/gbos/ || die "copy $d/ failed"
  done
  if [ $SHARED_EFI = 1 ]; then
    cmp -s $KERNEL /mnt/nefi/EFI/gbos86/BOOTX64.EFI || { say "  kernel (EFI/gbos86)"; cp $KERNEL /mnt/nefi/EFI/gbos86/BOOTX64.EFI || die "copy kernel failed"; }
  else
    cmp -s $KERNEL /mnt/nefi/EFI/BOOT/BOOTX64.EFI || { say "  kernel"; cp $KERNEL /mnt/nefi/EFI/BOOT/BOOTX64.EFI || die "copy kernel failed"; }
  fi
  # Settings such as DENSITY follow the stick; the installed copy always boots normally.
  write_installed_cfg
  sync; echo 3 > /proc/sys/vm/drop_caches
  say "Verifying ..."
  if [ $SHARED_EFI = 1 ]; then check $KERNEL /mnt/nefi/EFI/gbos86/BOOTX64.EFI; else check $KERNEL /mnt/nefi/EFI/BOOT/BOOTX64.EFI; fi
  for f in $FILES; do is_skipped $f || check $G/$f /mnt/nsys/gbos/$f; done
  for d in $DIRS; do is_skipped $d && continue; (cd $G && find $d -type f) | while read f; do check $G/$f /mnt/nsys/gbos/$f; done || exit 1; done || die "verify failed"
  for i in $STAMPED; do stamp_save $i || say "  (could not save the update stamp for $i; the next update will do a full compare)"; done
  umount /mnt/nefi /mnt/nsys /mnt/stickefi; sync
  say ""
  say "Update done. Remove the USB stick and turn the laptop back on."
  log "install: update complete"; sync
  ask "Press Enter to power off. "
  poweroff -f
fi

# Target: an internal disk, never the stick: an NVMe namespace, eMMC or a SATA disk. eMMC needs its host controller driver (sdhci-pci). The
# kernel's initramfs has it from kernel #33 on; older kernels only have it in the stick's module tree, so bind that tree and load it from there.
# The SATA/AHCI driver and the SCSI disk driver are built into the kernel.
if ! ls /sys/block | grep -q '^mmcblk'; then
  KVER=$(uname -r)
  [ -f $G/modules/lib/modules/$KVER/modules.dep ] && ! mountpoint -q /lib/modules 2>/dev/null && mount --bind $G/modules/lib/modules /lib/modules 2>/dev/null
  modprobe -q sdhci-pci 2>/dev/null && log "install: sdhci-pci loaded"
fi
# A disk is SATA when libata owns it: its sysfs path runs through an ataN port. A USB stick, a USB-SATA bridge, a card reader or a
# virtual disk is also an sdX, but its path goes through usb / virtio / ..., so it is never a target.
is_sata() { case "$(readlink -f /sys/block/$1 2>/dev/null)" in */ata[0-9]*/host*) return 0;; esac; return 1; }
# Candidates: nvmeXnY, and mmcblkN whose device type is MMC (eMMC). SD cards and card readers are never targets; the eMMC's own
# mmcblkNbootX / mmcblkNrpmb nodes are not matched. The stick's disk is never a candidate.
fast_disks() {
  for n in $(ls /sys/block | grep -E '^(nvme[0-9]+n[0-9]+|mmcblk[0-9]+)$'); do
    [ "$n" = "$STICKDISK" ] && continue
    case $n in mmcblk*) [ "$(cat /sys/block/$n/device/type 2>/dev/null)" = MMC ] || continue;; esac
    echo $n
  done
}
sata_disks() {
  for n in $(ls /sys/block | grep -E '^sd[a-z]+$'); do
    [ "$n" = "$STICKDISK" ] && continue
    is_sata $n && echo $n
  done
}
# SATA disks are only offered when there is no NVMe/eMMC: a laptop with an NVMe and a SATA data disk keeps installing to the NVMe as
# before. INSTALL_DISK=sda in gbos.cfg picks a SATA disk explicitly (also when there are several, or an NVMe is present).
internal_disks() {
  _f=$(fast_disks)
  if [ -n "$_f" ]; then echo "$_f"; else sata_disks; fi
}
# eMMC and SATA take a moment to enumerate (driver load, link-up, IDENTIFY).
for i in 1 2 3 4 5 6 7 8 9 10; do mdev -s; [ -n "$(internal_disks)" ] && break; sleep 1; done
set -- $(internal_disks)
[ $# -ge 1 ] || [ -n "$INSTALL_DISK" ] || die "no internal NVMe, eMMC or SATA disk found (block devices: $(ls /sys/block | tr '\n' ' '))"
if [ -n "$INSTALL_DISK" ]; then   # gbos.cfg INSTALL_DISK=mmcblk0 chooses when there is more than one
  case " $(fast_disks) $(sata_disks) " in *" $INSTALL_DISK "*) set -- $INSTALL_DISK;; *) die "INSTALL_DISK=$INSTALL_DISK is not one of the internal disks ($(fast_disks) $(sata_disks))";; esac
fi
[ $# -eq 1 ] || die "more than one internal disk ($*); set INSTALL_DISK=<name> in gbos.cfg on the stick to pick one"
T=$1; TD=/dev/$T
[ "$T" != "$STICKDISK" ] || die "target $T is the stick"
CTRL=/sys/block/$T/device
case $T in
  mmcblk*)
    KIND=eMMC
    MODEL="$(cat $CTRL/name 2>/dev/null | sed 's/ *$//') (eMMC, manufacturer id $(cat $CTRL/manfid 2>/dev/null))"
    SERIAL=$(cat $CTRL/serial 2>/dev/null | sed 's/^ *//; s/ *$//')
    case "$SERIAL" in ''|0|0x0|0x00000000) SERIAL=$(cat $CTRL/cid 2>/dev/null | sed 's/ //g');; esac;;
  sd*)
    KIND=SATA
    MODEL="$(cat $CTRL/vendor 2>/dev/null | sed 's/ *$//') $(cat $CTRL/model 2>/dev/null | sed 's/ *$//')"
    # The drive's serial: the SCSI "unit serial number" page when the kernel exposes it, else from the WWID, which libata builds as
    # "t10.ATA" + vendor + the full 40-character model + the serial (the sysfs model above is cut to 16 characters).
    SERIAL=$(tail -c +5 $CTRL/vpd_pg80 2>/dev/null | tr -d '\000' | tr -c '[:print:]' ' ' | sed 's/^ *//; s/ *$//')
    WWID=$(cat $CTRL/wwid 2>/dev/null | sed 's/^ *//; s/ *$//')
    case "$WWID" in
      t10.ATA*)
        _r=$(printf '%s' "${WWID#t10.ATA}" | sed 's/^ *//; s/ *$//')
        [ -n "$SERIAL" ] || SERIAL=$(printf '%s' "$_r" | awk '{print $NF}')
        MODEL="ATA $(printf '%s' "$_r" | sed 's/ *[^ ]*$//')";;
      *) [ -n "$SERIAL" ] || SERIAL=$WWID;;
    esac;;
  *)
    KIND=NVMe
    MODEL=$(cat $CTRL/model 2>/dev/null | sed 's/ *$//'); SERIAL=$(cat $CTRL/serial 2>/dev/null | sed 's/^ *//; s/ *$//');;
esac
SIZE=$(( $(cat /sys/block/$T/size) * 512 )); GB=$(( SIZE / 1000000000 ))
[ -n "$SERIAL" ] || die "cannot read the serial number of $T"
[ $GB -ge 24 ] || die "$T is only ${GB} GB; need at least 24 GB"

say ""
say "Target disk: $TD ($KIND)"
say "  model:  $MODEL"
say "  serial: $SERIAL"
say "  size:   ${GB} GB"
say ""

CURRENT_PARTS=$(ls /sys/block/$T | grep "^${T}p\?[0-9]")
INSTALL_MODE=clean
free_mb=0
if [ -n "$CURRENT_PARTS" ]; then
  say "Current partition layout on $TD:"
  part_sectors=0
  for p in $CURRENT_PARTS; do
    sz_sec=$(cat /sys/block/$T/$p/size 2>/dev/null || echo 0)
    part_sectors=$(( part_sectors + sz_sec ))
    sz_mb=$(( sz_sec / 2048 ))
    if [ $sz_mb -ge 1024 ]; then
      sz_str="$(( sz_mb / 1024 )) GB"
    else
      sz_str="${sz_mb} MB"
    fi
    info=$(tool blkid /dev/$p 2>/dev/null)
    lbl=$(echo "$info" | sed -n 's/.*LABEL="\([^"]*\)".*/\1/p')
    fst=$(echo "$info" | sed -n 's/.*TYPE="\([^"]*\)".*/\1/p')
    extra=""
    [ -n "$fst" ] && extra="[$fst]"
    [ -n "$lbl" ] && extra="$extra \"$lbl\""
    say "  /dev/$p : $sz_str $extra"
  done

  # Calculate unallocated free space
  tot_sec=$(cat /sys/block/$T/size 2>/dev/null || echo 0)
  free_sec=$(( tot_sec - part_sectors ))
  if [ $free_sec -gt 0 ]; then
    free_mb=$(( free_sec / 2048 ))
    if [ $free_mb -ge 1024 ]; then
      free_str="$(( free_mb / 1024 )) GB"
    else
      free_str="${free_mb} MB"
    fi
    say "  [Unallocated free space]: about $free_str"
  fi
  say ""
  say "Choose installation mode:"
  say "  1) Dual-Boot: keep existing OS (Windows/Linux); install into free space or GBOS partitions"
  say "  2) Full clean install: ERASE ENTIRE DISK (Windows, Linux, files, all partitions)"
  say "  anything else: cancel"
  # GBOS_INSTALL_MODE=dualboot|clean in gbos.cfg answers this question (unattended and QEMU tests); the serial is asked either way.
  case "$GBOS_INSTALL_MODE" in dualboot|clean) REPLY=$GBOS_INSTALL_MODE; say "(mode taken from gbos.cfg: $REPLY)";; *) ask "choice> ";; esac
  case "$REPLY" in
    1|dualboot|dual-boot) INSTALL_MODE=dualboot;;
    2|clean|erase) INSTALL_MODE=clean;;
    *) halt_here "Cancelled. Nothing was written to $TD.";;
  esac
fi

if [ "$INSTALL_MODE" = clean ]; then
  say ""
  say "EVERYTHING ON THIS DISK WILL BE ERASED (Windows, files, all partitions)."
  say "To continue, type the serial number exactly as shown. Anything else cancels."
  CONFIRM=$(sed -n 's/.*gbos_install_confirm=\([^ ]*\).*/\1/p' /proc/cmdline)
  if [ -n "$CONFIRM" ]; then
    REPLY=$CONFIRM; say "(serial taken from the kernel command line: $REPLY)"
  else
    ask "serial> "
  fi
  [ "$REPLY" = "$SERIAL" ] || halt_here "Cancelled. Nothing was written to $TD."

  # Keep the old install's recent logs (best effort) before they're erased.
  if [ -n "$NSYS" ] && mkdir -p /mnt/oldsys && mount -t vfat -o ro $NSYS /mnt/oldsys 2>/dev/null; then
    mkdir -p $L/nvme-logs
    for b in $(ls /mnt/oldsys/gbos/logs 2>/dev/null | sort -t- -k2 -n | tail -3); do cp -r /mnt/oldsys/gbos/logs/$b $L/nvme-logs/ 2>/dev/null; done
    say "Saved the old install's logs to gbos/logs/boot-$N/nvme-logs on the stick."
    umount /mnt/oldsys
  fi

  say ""
  say "Erasing and partitioning $TD ..."
  for p in $(ls /sys/block/$T | grep "^${T}p\?[0-9]"); do umount /dev/$p 2>/dev/null; done
  # Clear old signatures at both ends (the backup GPT lives at the end).
  dd if=/dev/zero of=$TD bs=1M count=16 conv=fsync 2>/dev/null
  dd if=/dev/zero of=$TD bs=1M count=16 seek=$(( SIZE / 1048576 - 16 )) conv=fsync 2>/dev/null
  tool sfdisk --wipe always --wipe-partitions always $TD >> $L/install.log 2>&1 <<EOF || die "sfdisk failed"
label: gpt
size=512MiB, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="GBOS_EFI"
size=8GiB, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, name="GBOSSYS"
size=64MiB, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="GBOS_META"
type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="GBOS_DATA"
EOF
  blockdev --rereadpt $TD 2>/dev/null; sleep 2; mdev -s
  case $T in *[0-9]) P=${TD}p;; *) P=$TD;; esac   # nvme0n1p1, mmcblk0p1, sda1
  for i in 1 2 3 4; do [ -b $P$i ] || { sleep 2; mdev -s; }; [ -b $P$i ] || die "partition $P$i did not appear"; done
  tool sfdisk -l $TD >> $L/install.log 2>&1

  say "Formatting ..."
  tool mkfs.fat -F 32 -n GBOS_EFI ${P}1 >> $L/install.log 2>&1 || die "mkfs GBOS_EFI failed"
  tool mkfs.fat -F 32 -n GBOSSYS ${P}2 >> $L/install.log 2>&1 || die "mkfs GBOSSYS failed"
  NODISCARD=; [ -n "$CONFIRM" ] && NODISCARD="-E nodiscard"
  tool mke2fs -F -q -t ext4 $NODISCARD -L GBOS_META ${P}3 >> $L/install.log 2>&1 || die "mkfs GBOS_META failed"
  tool mke2fs -F -q -t ext4 $NODISCARD -L GBOS_DATA -m 0 -O verity ${P}4 >> $L/install.log 2>&1 || die "mkfs GBOS_DATA failed"
  tool e2fsck -fn ${P}3 >> $L/install.log 2>&1 || die "fsck GBOS_META failed"
  tool e2fsck -fn ${P}4 >> $L/install.log 2>&1 || die "fsck GBOS_DATA failed"
  TARGET_EFI=${P}1
  TARGET_SYS=${P}2
else
  # Dual-boot: add GBOSSYS + GBOS_DATA in the disk's free space and put the kernel in the existing EFI system partition under EFI/gbos86/.
  # Nothing that exists is erased, reformatted or overwritten; everything is checked BEFORE the first write.
  say ""
  say "Dual-boot on $TD (existing partitions are kept) ..."
  [ -z "$(findfs LABEL=GBOSSYS 2>/dev/null)$(findfs LABEL=GBOS_DATA 2>/dev/null)" ] \
    || die "a gbOS86 install already exists on this machine: choose Update (keeps your data) or a full clean install, never a second dual-boot"
  tool sfdisk -d $TD 2>/dev/null | grep -q '^label: gpt' || die "dual-boot needs a GPT disk; $TD is not"
  # The EFI system partition: GPT type first (Windows labels it "SYSTEM", "ESP", "EFI" or nothing), the usual labels as a fallback.
  TARGET_EFI=$(tool sfdisk -d $TD 2>/dev/null | awk 'toupper($0) ~ /TYPE=C12A7328-F81F-11D2-BA4B-00A0C93EC93B/ {print $1; exit}')
  [ -n "$TARGET_EFI" ] || TARGET_EFI=$(findfs LABEL=EFI 2>/dev/null)
  [ -n "$TARGET_EFI" ] || TARGET_EFI=$(findfs LABEL=SYSTEM 2>/dev/null)
  [ -n "$TARGET_EFI" ] && [ -b "$TARGET_EFI" ] || die "no EFI system partition found on $TD"
  mkdir -p /mnt/nefi
  mount -t vfat -o ro $TARGET_EFI /mnt/nefi || die "cannot mount the EFI system partition $TARGET_EFI"
  efi_free_kb=$(df -k /mnt/nefi | awk 'NR==2{print $4}'); umount /mnt/nefi
  [ "${efi_free_kb:-0}" -ge 45000 ] || die "the EFI system partition $TARGET_EFI has only $(( ${efi_free_kb:-0} / 1024 )) MB free; the kernel needs 40 MB"
  [ $free_mb -ge 17000 ] || die "only about $(( free_mb / 1024 )) GB of unallocated space on $TD; dual-boot needs 17 GB (8 GB system + 8 GB data at least). Shrink a partition in Windows/Linux first."

  say "This will add two partitions in the unallocated space (about $(( free_mb / 1024 )) GB): GBOSSYS (8 GiB) and GBOS_DATA (the rest)."
  say "Nothing existing is erased or reformatted. The kernel goes to $TARGET_EFI as EFI/gbos86/BOOTX64.EFI (no other file there is touched)."
  say "To continue, type the serial number exactly as shown. Anything else cancels."
  CONFIRM=$(sed -n 's/.*gbos_install_confirm=\([^ ]*\).*/\1/p' /proc/cmdline)
  if [ -n "$CONFIRM" ]; then
    REPLY=$CONFIRM; say "(serial taken from the kernel command line: $REPLY)"
  else
    ask "serial> "
  fi
  [ "$REPLY" = "$SERIAL" ] || halt_here "Cancelled. Nothing was written to $TD."

  tool sfdisk --append $TD >> $L/install.log 2>&1 <<EOF || die "sfdisk failed to add the partitions (see install.log); the disk's existing partitions were not changed"
size=8GiB, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, name="GBOSSYS"
type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="GBOS_DATA"
EOF
  blockdev --rereadpt $TD 2>/dev/null; sleep 2; mdev -s
  for i in 1 2 3 4 5; do
    # The new partitions have no filesystem yet, so look them up by GPT name.
    PT=$(tool sfdisk -d $TD 2>/dev/null)
    TARGET_SYS=$(echo "$PT" | awk '/name="GBOSSYS"/ {print $1; exit}'); TARGET_DATA=$(echo "$PT" | awk '/name="GBOS_DATA"/ {print $1; exit}')
    [ -b "$TARGET_SYS" ] && [ -b "$TARGET_DATA" ] && break
    sleep 2; mdev -s
  done
  [ -n "$TARGET_SYS" ] && [ -b "$TARGET_SYS" ] || die "GBOSSYS partition did not appear on $TD"
  [ -n "$TARGET_DATA" ] && [ -b "$TARGET_DATA" ] || die "GBOS_DATA partition did not appear on $TD"

  say "Formatting the new partitions GBOSSYS ($TARGET_SYS) and GBOS_DATA ($TARGET_DATA) ..."
  tool mkfs.fat -F 32 -n GBOSSYS $TARGET_SYS >> $L/install.log 2>&1 || die "mkfs GBOSSYS failed"
  NODISCARD=; [ -n "$CONFIRM" ] && NODISCARD="-E nodiscard"   # QEMU tests only (see the clean install)
  tool mke2fs -F -q -t ext4 $NODISCARD -L GBOS_DATA -m 0 -O verity $TARGET_DATA >> $L/install.log 2>&1 || die "mkfs GBOS_DATA failed"
  tool e2fsck -fn $TARGET_DATA >> $L/install.log 2>&1 || die "fsck GBOS_DATA failed"
fi

# Copy, then check every file against the source after dropping the page cache.
mkdir -p /mnt/nefi /mnt/nsys
mount -t vfat $TARGET_EFI /mnt/nefi || die "mount EFI failed"
mount -t vfat -o flush $TARGET_SYS /mnt/nsys || die "mount GBOSSYS failed"
mkdir -p /mnt/nsys/gbos/logs
[ "$INSTALL_MODE" = dualboot ] || mkdir -p /mnt/nefi/EFI/BOOT

# If physical GBOS_META is absent (dualboot), create loopback metadata.img inside GBOSSYS
if [ -z "$(findfs LABEL=GBOS_META 2>/dev/null)" ] && [ ! -f /mnt/nsys/gbos/metadata.img ]; then
  say "Creating loopback metadata.img (64 MB ext4) inside GBOSSYS..."
  dd if=/dev/zero of=/mnt/nsys/gbos/metadata.img bs=1M count=64 2>/dev/null
  tool mke2fs -F -q -t ext4 -L GBOS_META /mnt/nsys/gbos/metadata.img >> $L/install.log 2>&1
fi

say "Copying the kernel ..."
if [ "$INSTALL_MODE" = dualboot ]; then
  mkdir -p /mnt/nefi/EFI/gbos86
  cp $KERNEL /mnt/nefi/EFI/gbos86/BOOTX64.EFI || die "copy BOOTX64.EFI failed"
fi
# The fallback path EFI/BOOT/BOOTX64.EFI belongs to the machine's other OS on a shared EFI partition: only a clean install owns it.
if [ "$INSTALL_MODE" = clean ]; then
  cp $KERNEL /mnt/nefi/EFI/BOOT/BOOTX64.EFI || die "copy BOOTX64.EFI failed"
fi
say "Copying the system (super.img is $(( $(stat -c %s $G/super.img) / 1048576 )) MiB, this takes a few minutes) ..."
for f in $FILES; do cp $G/$f /mnt/nsys/gbos/$f || die "copy $f failed"; done
for d in $DIRS; do cp -r $G/$d /mnt/nsys/gbos/ || die "copy $d/ failed"; done
cp /gbos/busybox /mnt/nsys/busybox 2>/dev/null
# The installed system boots normally and can't re-run the installer.
write_installed_cfg
sync; echo 3 > /proc/sys/vm/drop_caches

say "Verifying ..."
if [ "$INSTALL_MODE" = dualboot ]; then check $KERNEL /mnt/nefi/EFI/gbos86/BOOTX64.EFI; else check $KERNEL /mnt/nefi/EFI/BOOT/BOOTX64.EFI; fi
for f in $FILES; do check $G/$f /mnt/nsys/gbos/$f; done
for d in $DIRS; do (cd $G && find $d -type f) | while read f; do check $G/$f /mnt/nsys/gbos/$f; done || exit 1; done || die "verify failed"
for i in $STAMPED; do stamp_save $i || true; done
umount /mnt/nefi /mnt/nsys /mnt/stickefi; sync

say ""
say "=============================================================="
if [ "$INSTALL_MODE" = dualboot ]; then
  say " gbOS86 is installed on $TD alongside existing OS."
  say " Remove the USB stick, then turn the laptop back on."
  say " Press your boot key (F12 / F9 / Esc) at the logo and pick"
  say " 'gbOS86' or the internal drive UEFI boot entry."
else
  say " gbOS86 is installed on $TD."
  say " Remove the USB stick, then turn the laptop back on. If it doesn't"
  say " boot gbos, press F12 at the logo and pick the internal disk's UEFI entry"
  say " (or add \\EFI\\BOOT\\BOOTX64.EFI as a boot option in BIOS setup)."
fi
say "=============================================================="
log "install: complete"; sync
if [ -n "$CONFIRM" ]; then poweroff -f; fi
ask "Press Enter to power off. "
poweroff -f
