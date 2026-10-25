#!/usr/bin/env python3
"""run_installer_sata.py KERNEL [--keep DIR] -- test usb/install.sh on an emulated SATA disk (QEMU q35, ICH9 AHCI + ide-hd).

KERNEL is a BOOTX64.EFI (kernel with the stage0 initramfs). The test builds a fake USB stick (MBR, p1 EFI with KERNEL, p2 FAT "GBOS"
with the real install.sh, hwdetect.sh, installer tools and the other stick files; the big items are small dummies) and a 32 GiB qcow2
SATA disk image, then boots QEMU several times:
  1. wrong serial typed      -> installer must show "(SATA)", the drive's serial, and write NOTHING to the disk
  2. correct serial          -> install; then the host checks the GPT, FAT and ext4 partitions and compares every file
  3. ACTION=update           -> update of the installed copy finds the disk by label and verifies
  4. no stick, SATA only     -> stage0 must find GBOSSYS on sda
  5. NVMe + SATA present     -> the NVMe is the target, the SATA disk is left alone (old behaviour kept)
  6. NVMe + SATA, INSTALL_DISK=sda -> the SATA disk is the target
  7. two SATA disks          -> refused ("more than one internal disk")
  8. a USB disk only         -> never a target
Prints ISA_EMU_INSTALLER_SATA_PASS on success. Needs qemu-system-x86_64, mkfs.fat, mtools and e2fsprogs (all in Homebrew)."""
import os, pathlib, re, shutil, struct, subprocess, sys, tempfile, time, zlib

repo = pathlib.Path(__file__).resolve().parents[2]
usb = repo / 'usb'
args = sys.argv[1:]
keep = None
if '--keep' in args:
    i = args.index('--keep'); keep = pathlib.Path(args[i + 1]); del args[i:i + 2]
kernel = pathlib.Path(args[0]).resolve()

free_gb = shutil.disk_usage(tempfile.gettempdir()).free / 1e9
if free_gb < 15:
    # The first runs of this test filled a Mac's disk: the eMMC image grew by ~6 GB while the installer formatted the 25 GB data partition.
    sys.exit(f'refusing to run: only {free_gb:.1f} GB free, need 15 GB (the emulated eMMC image can grow by several GB)')
work = keep or pathlib.Path(tempfile.mkdtemp(prefix='gbos-sata-'))
work.mkdir(parents=True, exist_ok=True)
FAIL = []
def check(ok, msg):
    print(('PASS ' if ok else 'FAIL ') + msg, flush=True)
    if not ok: FAIL.append(msg)
def run(cmd, **kw): return subprocess.run(cmd, capture_output=True, text=True, errors='replace', **kw)
def e2fsck(img, offset):
    """e2fsck -fn on the ext4 filesystem at OFFSET bytes in IMG: Homebrew's e2fsprogs if present, else alpine in docker."""
    if shutil.which('e2fsck'): return run(['e2fsck', '-fn', f'{img}?offset={offset}'])
    return run(['docker', 'run', '--rm', '--platform', 'linux/amd64', '-v', f'{img.parent}:/w', 'alpine:latest', 'sh', '-c',
                f'apk add -q e2fsprogs >/dev/null && e2fsck -fn "/w/{img.name}?offset={offset}"'])

# ---------------------------------------------------------------- the stick
MIB = 1 << 20
def build_tree(cfg):
    g = work / 'gbos'
    shutil.rmtree(g, ignore_errors=True); (g / 'gbos').mkdir(parents=True)
    G = g / 'gbos'
    for f in ['install.sh', 'hook.sh', 'aidiag.sh', 'early_patch.sh', 'hwdetect.sh', 'apex_patch.sh', 'crossystem', 'libkm_compat.so',
              'system_ext_manifest.xml', 'soft_gk', 'bootdisk.img']:
        src = usb / f
        if src.exists(): shutil.copy(src, G / f)
        else: (G / f).write_bytes(b'test dummy ' + f.encode())
    (G / 'super.img').write_bytes(os.urandom(6 * MIB)); (G / 'super.layout').write_bytes(b'test dummy layout')
    shutil.copytree(usb / 'installer', G / 'installer', symlinks=False)
    for d in ('firmware', 'patched', 'audio', 'kmod', 'surface', 'ksu'):
        (G / d).mkdir(); (G / d / 'dummy').write_bytes(os.urandom(70000))
    # modules: only the tree metadata and the four mmc host modules, so the installer's fallback (bind the stick's tree, modprobe) is exercised
    kver = next((usb / 'modules/lib/modules').iterdir()).name
    md = G / 'modules/lib/modules' / kver; md.mkdir(parents=True)
    for f in (usb / 'modules/lib/modules' / kver).iterdir():
        if f.is_file(): shutil.copy(f, md / f.name)
    for m in ('sdhci', 'sdhci-uhs2', 'cqhci', 'sdhci-pci'):
        dst = md / 'kernel/drivers/mmc/host'; dst.mkdir(parents=True, exist_ok=True)
        shutil.copy(usb / 'modules/lib/modules' / kver / 'kernel/drivers/mmc/host' / (m + '.ko'), dst / (m + '.ko'))
    (G / 'gbos.cfg').write_text(cfg)

def pack_stick(path):
    g = work / 'gbos'
    efi = work / 'efi'; shutil.rmtree(efi, ignore_errors=True); (efi / 'EFI/BOOT').mkdir(parents=True)
    shutil.copy(kernel, efi / 'EFI/BOOT/BOOTX64.EFI')
    p1, p2 = work / 'p1.fat', work / 'p2.fat'
    for f, mb, label, src in ((p1, 64, 'EFI', efi), (p2, 160, 'GBOS', g)):
        f.write_bytes(b''); os.truncate(f, mb * MIB)
        r = run(['mkfs.fat', '-F', '32', '-n', label, str(f)]); assert r.returncode == 0, r.stderr
        r = run(['mcopy', '-s', '-i', str(f)] + [str(x) for x in sorted(src.iterdir())] + ['::/']); assert r.returncode == 0, r.stderr
    # MBR: two FAT32 LBA partitions at 1 MiB
    s1, n1 = MIB // 512, 64 * MIB // 512; s2, n2 = s1 + n1, 160 * MIB // 512
    mbr = bytearray(512)
    for i, (st, n) in enumerate(((s1, n1), (s2, n2))):
        mbr[446 + 16 * i:446 + 16 * (i + 1)] = struct.pack('<B3sB3sII', 0, b'\xfe\xff\xff', 0x0c, b'\xfe\xff\xff', st, n)
    mbr[510:512] = b'\x55\xaa'
    with open(path, 'wb') as out:
        out.write(mbr); out.seek(MIB); out.write(p1.read_bytes()); out.write(p2.read_bytes())
    p1.unlink(); p2.unlink()

def make_stick(path, cfg, edit=None):
    build_tree(cfg)
    if edit: edit(work / 'gbos/gbos')
    pack_stick(path)

# ---------------------------------------------------------------- QEMU
CMD_TAIL = 'console=ttyS0 8250.nr_uarts=1 panic=-1 loglevel=7 rdinit=/init'
def sata(path, ident='sd0', serial='SATA-TEST-123', port=0):
    return ['-drive', f'if=none,id={ident},file={path},format=raw', '-device', f'ide-hd,drive={ident},bus=ide.{port},serial={serial}']
def qemu(stick, emmc_q, extra_cmdline, done_re, timeout=900, label='', disk=None):
    """Boot and stream the serial console until done_re matches (or QEMU exits, or timeout). Returns (log, matched)."""
    cmd = ['qemu-system-x86_64', '-machine', 'q35', '-cpu', 'Skylake-Client', '-m', '2048', '-smp', '2', '-nographic', '-no-reboot', '-nic', 'none']
    if stick:
        cmd += ['-drive', f'if=none,id=stick,file={stick},format=raw', '-device', 'qemu-xhci', '-device', 'usb-storage,drive=stick']
    cmd += disk or sata(emmc_q)
    cmd += ['-kernel', str(kernel), '-append', f'{CMD_TAIL} {extra_cmdline}'.strip()]
    log = work / f'qemu-{label}.log'
    t0 = time.time(); buf = b''
    with open(log, 'wb') as lf:
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
        os.set_blocking(p.stdout.fileno(), False)
        matched = False
        while time.time() - t0 < timeout:
            try: d = p.stdout.read(65536)
            except BlockingIOError: d = None
            if d:
                buf += d; lf.write(d); lf.flush()
                if re.search(done_re, buf.decode(errors='replace')): matched = True; break
            elif p.poll() is not None: break
            else: time.sleep(0.2)
            if emmc_q and emmc_q.exists() and os.stat(emmc_q).st_blocks * 512 > MAX_EMMC_GB * 1e9:
                print(f'   [{label}] ABORT: the eMMC image uses more than {MAX_EMMC_GB} GB of disk', flush=True)
                FAIL.append('eMMC image grew past the disk guard'); break
        if p.poll() is None:
            # let a poweroff finish if we matched on its message, else kill
            if matched:
                time.sleep(3)
            p.kill()
        p.wait()
    txt = buf.decode(errors='replace')
    print(f'   [{label}] {time.time() - t0:.0f}s, log {log}', flush=True)
    return txt, matched

def serial_of(txt):
    m = re.search(r'install:\s+serial:\s+(\S+)', txt)
    return m.group(1) if m else None

# ---------------------------------------------------------------- GPT / filesystem checks on the host
BASE = 0      # byte offset of the eMMC user area in the image: QEMU stores the two boot partitions first
def gpt(path):
    global BASE
    with open(path, 'rb') as f:
        head = f.read(4 * MIB)
        k = next((i for i in range(1, len(head) // 512) if head[i * 512:i * 512 + 8] == b'EFI PART'), None)
        if k is None: return None
        BASE = (k - 1) * 512
        h = head[k * 512:k * 512 + 92]
        ent_lba, n, sz = struct.unpack_from('<QII', h, 72)
        f.seek(BASE + ent_lba * 512); data = f.read(n * sz)
    out = []
    for i in range(n):
        e = data[i * sz:(i + 1) * sz]
        if e[:16] == b'\0' * 16: continue
        first, last = struct.unpack_from('<QQ', e, 32)
        out.append((e[56:128].decode('utf-16le').rstrip('\0'), first, last - first + 1))
    return out

# The disk is a sparse raw file; qemu() kills the run if its real disk usage passes MAX_EMMC_GB.
emmc = work / 'sata.raw'
emmc_q = emmc
MAX_EMMC_GB = 6
SERIAL = 'SATA-TEST-123'
def fresh_disk(p=emmc):
    p.unlink(missing_ok=True)
    with open(p, 'wb') as f: f.truncate(32 * (1 << 30))
    with open(p, 'r+b') as f: f.write(b'D' * 480)             # recognisable, to prove "nothing was written"
fresh_disk()
def untouched(p):
    with open(p, 'rb') as f: head = f.read(480)
    return head == b'D' * 480 and os.stat(p).st_blocks * 512 < MIB and gpt(p) is None

stick = work / 'stick.img'
cfg_install = 'MODE=install\nLOAD_I915=0\n'

print('== 1. wrong serial: must cancel and write nothing')
make_stick(stick, cfg_install)
txt, ok = qemu(stick, emmc_q, 'gbos_install_confirm=wrong-serial', r'Cancelled\. Nothing was written|no internal', 600, 'cancel')
check('Target disk: /dev/sda (SATA)' in txt, 'installer picked /dev/sda and reports it as SATA')
serial = serial_of(txt)
check(serial == SERIAL, f'serial shown is the drive\'s serial: {serial}')
m = re.search(r'install:\s+model:\s+(.*)', txt)
check(bool(m) and 'QEMU' in m.group(1), f'model shown: {m and m.group(1).strip()}')
check(ok and 'Cancelled. Nothing was written' in txt, 'cancelled with a wrong serial')
check(untouched(emmc), 'SATA disk untouched after the cancelled install (marker intact, nothing allocated, no partition table)')
if not serial:
    print(txt[-3000:]); sys.exit(1)

print('== 2. correct serial: install')
txt, ok = qemu(stick, emmc_q, f'gbos_install_confirm={serial}', r'gbOS86 is installed on /dev/sda', 1500, 'install')
check(ok, 'installer reports success')
parts = gpt(emmc)
check(bool(parts) and [p[0] for p in parts] == ['GBOS_EFI', 'GBOSSYS', 'GBOS_META', 'GBOS_DATA'], f'GPT on the SATA disk: {parts and [p[0] for p in parts]}')
if parts:
    d = {p[0]: p for p in parts}
    off = lambda n: BASE + d[n][1] * 512
    r = run(['mdir', '-b', '-i', f'{emmc}@@{off("GBOS_EFI")}', '::EFI/BOOT/BOOTX64.EFI'])
    check(r.returncode == 0, 'GBOS_EFI has EFI/BOOT/BOOTX64.EFI')
    out = work / 'x'; shutil.rmtree(out, ignore_errors=True); out.mkdir()
    r = run(['mcopy', '-n', '-s', '-i', f'{emmc}@@{off("GBOSSYS")}', '::gbos', str(out)])
    check(r.returncode == 0, 'read GBOSSYS back with mtools: ' + r.stderr.strip()[:200])
    bad = []
    srcg = work / 'gbos/gbos'
    for f in sorted(p for p in srcg.rglob('*') if p.is_file()):
        rel = f.relative_to(srcg)
        if rel.name in ('gbos.cfg', 'install.sh'): continue   # gbos.cfg is rewritten; install.sh is never installed (stage0 runs it from the stick)
        g = out / 'gbos' / rel
        if not g.exists() or g.read_bytes() != f.read_bytes(): bad.append(str(rel))
    check(not bad, f'every stick file is on GBOSSYS and identical ({len(bad)} differ{": " + ", ".join(bad[:5]) if bad else ""})')
    cfgi = (out / 'gbos/gbos.cfg').read_text() if (out / 'gbos/gbos.cfg').exists() else ''
    check('MODE=boot' in cfgi and 'MODE=install' not in cfgi, 'installed gbos.cfg boots normally (MODE=boot)')
    for n in ('GBOS_META', 'GBOS_DATA'):
        r = e2fsck(emmc, off(n))
        check(r.returncode == 0, f'e2fsck {n} clean')
    r = run(['mlabel', '-s', '-i', f'{emmc}@@{off("GBOSSYS")}', '::'])
    check('GBOSSYS' in (r.stdout + r.stderr), 'GBOSSYS FAT label')

print('== 3. update of the installed copy')
if parts:
    make_stick(stick, 'MODE=install\nLOAD_I915=0\nACTION=update\n',
               lambda G: (G / 'hook.sh').write_bytes(b'# changed on the stick, update must copy this\n'))
    txt, ok = qemu(stick, emmc_q, 'gbos_install_confirm=update-test', r'Update done\.', 900, 'update')
    check(ok, 'update completed')
    check('Verifying' in txt and 'verify failed' not in txt, 'update verified')
    out2 = work / 'x2'; shutil.rmtree(out2, ignore_errors=True); out2.mkdir()
    run(['mcopy', '-n', '-s', '-i', f'{emmc}@@{off("GBOSSYS")}', '::gbos/hook.sh', str(out2)])
    check((out2 / 'hook.sh').exists() and (out2 / 'hook.sh').read_bytes().startswith(b'# changed on the stick'), 'changed file reached GBOSSYS')
    r = e2fsck(emmc, off('GBOS_DATA'))
    check(r.returncode == 0, 'GBOS_DATA still clean after update')

if parts:
    print('== 4. boot from the SATA disk alone (no stick)')
    txt, ok = qemu(None, emmc_q, '', r'found gbos volume on nvme at /dev/sda2|FATAL: no GBOS', 240, 'boot')
    check('found gbos volume on nvme at /dev/sda2' in txt, 'stage0 found GBOSSYS on /dev/sda2 without the stick')

def nvme_disk(p, serial='NVME-TEST-123'):
    return ['-drive', f'if=none,id=nv,file={p},format=raw', '-device', f'nvme,drive=nv,serial={serial}']

print('== 5. NVMe and SATA both present: the NVMe stays the target, SATA is left alone')
nv = work / 'nvme.raw'; fresh_disk(nv); fresh_disk(emmc)
make_stick(stick, cfg_install)
txt, ok = qemu(stick, None, 'gbos_install_confirm=wrong-serial', r'Cancelled\. Nothing was written|more than one|no internal', 300, 'both', disk=nvme_disk(nv) + sata(emmc))
check('Target disk: /dev/nvme0n1 (NVMe)' in txt and 'serial: NVME-TEST-123' in txt, 'NVMe chosen when a SATA disk is also present')
check(ok and untouched(emmc), 'SATA disk untouched')

print('== 6. NVMe and SATA, INSTALL_DISK=sda: the SATA disk is the target')
make_stick(stick, cfg_install + 'INSTALL_DISK=sda\n')
txt, ok = qemu(stick, None, 'gbos_install_confirm=wrong-serial', r'Cancelled\. Nothing was written|more than one|not one of|no internal', 300, 'pick', disk=nvme_disk(nv) + sata(emmc))
check('Target disk: /dev/sda (SATA)' in txt, 'INSTALL_DISK=sda selects the SATA disk')
check(ok and untouched(nv), 'NVMe untouched')
nv.unlink()

print('== 7. two SATA disks: refused')
sb = work / 'sata2.raw'; fresh_disk(sb); fresh_disk(emmc)
make_stick(stick, cfg_install)
txt, ok = qemu(stick, None, 'gbos_install_confirm=whatever', r'more than one internal disk|Target disk:', 300, 'two', disk=sata(emmc) + sata(sb, 'sd1', 'SATA-TEST-456', 1))
check('more than one internal disk' in txt and 'Target disk:' not in txt, 'two SATA disks: installer refuses and asks for INSTALL_DISK')
check(untouched(emmc) and untouched(sb), 'neither disk touched')
sb.unlink()

print('== 8. regression: a USB disk is never a target')
usbd = work / 'usbdisk.raw'; fresh_disk(usbd)
txt, ok = qemu(stick, None, 'gbos_install_confirm=whatever', r'no internal NVMe, eMMC or SATA disk found|Target disk:', 300, 'usb',
               disk=['-drive', f'if=none,id=u2,file={usbd},format=raw', '-device', 'usb-storage,drive=u2'])
check('no internal NVMe, eMMC or SATA disk found' in txt and 'Target disk:' not in txt, 'USB disk refused as an install target')
check(untouched(usbd), 'USB disk untouched')
usbd.unlink()

print('RESULT:', 'ISA_EMU_INSTALLER_SATA_PASS' if not FAIL else 'FAILED: ' + '; '.join(FAIL))
if not keep: shutil.rmtree(work, ignore_errors=True)
sys.exit(1 if FAIL else 0)
