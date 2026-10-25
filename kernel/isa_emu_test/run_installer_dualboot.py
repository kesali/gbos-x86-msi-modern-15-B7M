#!/usr/bin/env python3
"""run_installer_dualboot.py KERNEL [--boot] [--keep DIR] -- test the dual-boot mode of usb/install.sh on an emulated NVMe laid out like a
Windows machine (GPT: p1 "SYSTEM" EFI system partition with a Windows boot manager and a fallback EFI/BOOT/BOOTX64.EFI, p2 a 4 GiB data
partition with marker bytes, about 28 GiB unallocated).

  1. wrong serial          -> nothing written: the GPT, the ESP and the data partition are byte-identical
  2. correct serial        -> GBOSSYS + GBOS_DATA appended after the two existing partitions, which are unchanged; the kernel is at
                              EFI/gbos86/BOOTX64.EFI and every other file on the ESP (Windows boot manager, fallback BOOTX64.EFI) is untouched;
                              no GBOS_META partition, instead gbos/metadata.img (ext4) on GBOSSYS; GBOS_DATA is clean ext4
  3. ACTION=update         -> updates EFI/gbos86 only, still no change to the fallback EFI/BOOT/BOOTX64.EFI
  4. dual-boot again       -> refused (an install exists), nothing written
  5. no room               -> a disk with only 4 GiB unallocated is refused before anything is written
  --boot: 6. NVMe only, no stick -> stage0 finds GBOSSYS on nvme0n1p3
Prints ISA_EMU_INSTALLER_DUALBOOT_PASS on success. Needs qemu-system-x86_64, mkfs.fat, mtools and e2fsprogs (Homebrew)."""
import hashlib, os, pathlib, re, shutil, struct, subprocess, sys, tempfile, time, uuid, zlib

repo = pathlib.Path(__file__).resolve().parents[2]
usb = repo / 'usb'
args = sys.argv[1:]
keep = None
if '--keep' in args:
    i = args.index('--keep'); keep = pathlib.Path(args[i + 1]); del args[i:i + 2]
do_boot = '--boot' in args
if do_boot: args.remove('--boot')
kernel = pathlib.Path(args[0]).resolve()

free_gb = shutil.disk_usage(tempfile.gettempdir()).free / 1e9
if free_gb < 15: sys.exit(f'refusing to run: only {free_gb:.1f} GB free, need 15 GB')
work = keep or pathlib.Path(tempfile.mkdtemp(prefix='gbos-dualboot-'))
work.mkdir(parents=True, exist_ok=True)
FAIL = []
def check(ok, msg):
    print(('PASS ' if ok else 'FAIL ') + msg, flush=True)
    if not ok: FAIL.append(msg)
def run(cmd, **kw): return subprocess.run(cmd, capture_output=True, text=True, errors='replace', **kw)
def e2fsck(img, offset):
    if shutil.which('e2fsck'): return run(['e2fsck', '-fn', f'{img}?offset={offset}'])
    return run(['docker', 'run', '--rm', '--platform', 'linux/amd64', '-v', f'{img.parent}:/w', 'alpine:latest', 'sh', '-c',
                f'apk add -q e2fsprogs >/dev/null && e2fsck -fn "/w/{img.name}?offset={offset}"'])

MIB = 1 << 20
GIB = 1 << 30
ESP_GUID = 'C12A7328-F81F-11D2-BA4B-00A0C93EC93B'
MSDATA_GUID = 'EBD0A0A2-B9E5-4433-87C0-68B6B72699C7'
SERIAL = 'NVME-DUALBOOT-1'

# ---------------------------------------------------------------- the stick (as in run_installer_emmc.py)
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
    kver = next((usb / 'modules/lib/modules').iterdir()).name
    md = G / 'modules/lib/modules' / kver; md.mkdir(parents=True)
    for f in (usb / 'modules/lib/modules' / kver).iterdir():
        if f.is_file(): shutil.copy(f, md / f.name)
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
def qemu(stick, nvme, extra_cmdline, done_re, timeout=900, label=''):
    cmd = ['qemu-system-x86_64', '-machine', 'q35', '-cpu', 'Skylake-Client', '-m', '2048', '-smp', '2', '-nographic', '-no-reboot', '-nic', 'none']
    if stick: cmd += ['-drive', f'if=none,id=stick,file={stick},format=raw', '-device', 'qemu-xhci', '-device', 'usb-storage,drive=stick']
    cmd += ['-drive', f'if=none,id=nv,file={nvme},format=raw', '-device', f'nvme,drive=nv,serial={SERIAL}']
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
            if nvme.exists() and os.stat(nvme).st_blocks * 512 > 6e9:
                print(f'   [{label}] ABORT: the NVMe image uses more than 6 GB of disk', flush=True)
                FAIL.append('NVMe image grew past the disk guard'); break
        if p.poll() is None:
            if matched: time.sleep(3)
            p.kill()
        p.wait()
    txt = buf.decode(errors='replace')
    print(f'   [{label}] {time.time() - t0:.0f}s, log {log}', flush=True)
    return txt, matched

# ---------------------------------------------------------------- a Windows-like disk, written by hand (GPT)
def gpt_entries(parts):
    out = b''
    for guid, name, first, last in parts:
        out += uuid.UUID(guid).bytes_le + uuid.uuid4().bytes_le + struct.pack('<QQQ', first, last, 0) + name.encode('utf-16le').ljust(72, b'\0')
    return out.ljust(128 * 128, b'\0')

def write_gpt(f, disk_bytes, parts):
    nsec = disk_bytes // 512
    ents = gpt_entries(parts)
    def header(cur, other, first_usable, last_usable, ent_lba):
        h = bytearray(92)
        h[0:8] = b'EFI PART'; struct.pack_into('<IIII', h, 8, 0x10000, 92, 0, 0)
        struct.pack_into('<QQQQ', h, 24, cur, other, first_usable, last_usable)
        h[56:72] = uuid.uuid4().bytes_le
        struct.pack_into('<QIII', h, 72, ent_lba, 128, 128, zlib.crc32(ents))
        struct.pack_into('<I', h, 16, zlib.crc32(bytes(h)))
        return bytes(h).ljust(512, b'\0')
    mbr = bytearray(512); mbr[446 + 4] = 0xee; struct.pack_into('<II', mbr, 446 + 8, 1, min(nsec - 1, 0xffffffff)); mbr[510:512] = b'\x55\xaa'
    f.seek(0); f.write(mbr)
    f.seek(512); f.write(header(1, nsec - 1, 34, nsec - 34, 2))
    f.seek(1024); f.write(ents)
    f.seek((nsec - 33) * 512); f.write(ents)
    f.seek((nsec - 1) * 512); f.write(header(nsec - 1, 1, 34, nsec - 34, nsec - 33))

def read_gpt(path):
    with open(path, 'rb') as f:
        f.seek(512); h = f.read(92)
        if h[:8] != b'EFI PART': return None
        ent_lba, n, sz = struct.unpack_from('<QII', h, 72)
        f.seek(ent_lba * 512); data = f.read(n * sz)
    out = []
    for i in range(n):
        e = data[i * sz:(i + 1) * sz]
        if e[:16] == b'\0' * 16: continue
        first, last = struct.unpack_from('<QQ', e, 32)
        out.append((e[56:128].decode('utf-16le').rstrip('\0'), first, last - first + 1))
    return out

ESP_FILES = {'EFI/Microsoft/Boot/bootmgfw.efi': b'WINDOWS BOOT MANAGER ' * 500, 'EFI/BOOT/BOOTX64.EFI': b'WINDOWS FALLBACK LOADER ' * 500,
             'EFI/Microsoft/Boot/BCD': os.urandom(4096)}
DATA_MARK = (os.urandom(MIB), os.urandom(MIB))
def sha(b): return hashlib.sha256(b).hexdigest()

def fresh_nvme(free_gib=28, data_gib=4):
    nvme = work / 'nvme.raw'; nvme.unlink(missing_ok=True)
    esp_mb = 100
    total = (esp_mb * MIB + data_gib * GIB + free_gib * GIB + 2 * MIB + 1 * MIB)
    total = (total // GIB + 1) * GIB                       # whole GiB, as a real disk
    with open(nvme, 'wb') as f: f.truncate(total)
    esp_first = 2048; esp_last = esp_first + esp_mb * MIB // 512 - 1
    d_first = esp_last + 1; d_last = d_first + data_gib * GIB // 512 - 1
    esp = work / 'esp.fat'; esp.write_bytes(b''); os.truncate(esp, esp_mb * MIB)
    assert run(['mkfs.fat', '-F', '32', '-n', 'SYSTEM', str(esp)]).returncode == 0
    for name, data in ESP_FILES.items():
        t = work / 'esp_src' / name; t.parent.mkdir(parents=True, exist_ok=True); t.write_bytes(data)
    r = run(['mcopy', '-s', '-i', str(esp)] + [str(x) for x in sorted((work / 'esp_src').iterdir())] + ['::/']); assert r.returncode == 0, r.stderr
    with open(nvme, 'r+b') as f:
        write_gpt(f, total, [(ESP_GUID, 'EFI system partition', esp_first, esp_last), (MSDATA_GUID, 'Basic data partition', d_first, d_last)])
        f.seek(esp_first * 512); f.write(esp.read_bytes())
        f.seek(d_first * 512); f.write(DATA_MARK[0])
        f.seek((d_last + 1) * 512 - MIB); f.write(DATA_MARK[1])
    esp.unlink(); shutil.rmtree(work / 'esp_src')
    return nvme

def windows_intact(nvme, tag):
    parts = {p[0]: p for p in read_gpt(nvme) or []}
    ok = 'EFI system partition' in parts and 'Basic data partition' in parts
    check(ok, f'{tag}: the two existing partitions are still in the GPT at the same place')
    if not ok: return
    e = parts['EFI system partition']; d = parts['Basic data partition']
    bad = []
    for name, data in ESP_FILES.items():
        out = work / 'esp_chk'; out.unlink(missing_ok=True)
        r = run(['mcopy', '-n', '-i', f'{nvme}@@{e[1] * 512}', '::' + name, str(out)])
        if r.returncode != 0 or out.read_bytes() != data: bad.append(name)
    check(not bad, f'{tag}: every file of the Windows ESP is unchanged ({", ".join(bad) or "all " + str(len(ESP_FILES))})')
    with open(nvme, 'rb') as f:
        f.seek(d[1] * 512); a = f.read(MIB); f.seek((d[1] + d[2]) * 512 - MIB); b = f.read(MIB)
    check((a, b) == DATA_MARK, f'{tag}: the Windows data partition is byte-identical (markers at both ends)')

stick = work / 'stick.img'
cfg = f'MODE=install\nLOAD_I915=0\nGBOS_INSTALL_MODE=dualboot\n'

print('== 1. wrong serial: must cancel and write nothing')
nvme = fresh_nvme()
before = read_gpt(nvme)
with open(nvme, 'rb') as f: head0 = f.read(2 * MIB)
make_stick(stick, cfg)
txt, ok = qemu(stick, nvme, 'gbos_install_confirm=wrong-serial', r'Cancelled\. Nothing was written', 600, 'cancel')
check('Target disk: /dev/nvme0n1 (NVMe)' in txt, 'installer picked the NVMe')
check('[Unallocated free space]' in txt and '[vfat]' in txt, 'partition layout with filesystem types and the free space is shown')
check('mode taken from gbos.cfg: dualboot' in txt, 'dual-boot mode selected')
check(ok, 'cancelled with a wrong serial')
with open(nvme, 'rb') as f: head1 = f.read(2 * MIB)
check(head0 == head1 and read_gpt(nvme) == before, 'GPT, ESP and start of the disk unchanged after the cancel')
windows_intact(nvme, 'after cancel')

print('== 2. correct serial: dual-boot install')
txt, ok = qemu(stick, nvme, f'gbos_install_confirm={SERIAL}', r'gbOS86 is installed on /dev/nvme0n1 alongside', 1500, 'install')
check(ok, 'installer reports success')
parts = read_gpt(nvme)
names = [p[0] for p in parts or []]
check(names == ['EFI system partition', 'Basic data partition', 'GBOSSYS', 'GBOS_DATA'], f'GPT: {names}')
windows_intact(nvme, 'after install')
if parts and names[2:] == ['GBOSSYS', 'GBOS_DATA']:
    d = {p[0]: p for p in parts}
    off = lambda n: d[n][1] * 512
    check(d['GBOSSYS'][2] * 512 == 8 * GIB, f'GBOSSYS is 8 GiB ({d["GBOSSYS"][2] * 512 // MIB} MiB)')
    check(d['GBOS_DATA'][2] * 512 > 15 * GIB, f'GBOS_DATA took the rest of the free space ({d["GBOS_DATA"][2] * 512 // MIB} MiB)')
    e = d['EFI system partition']
    out = work / 'k.efi'; out.unlink(missing_ok=True)
    r = run(['mcopy', '-n', '-i', f'{nvme}@@{e[1] * 512}', '::EFI/gbos86/BOOTX64.EFI', str(out)])
    check(r.returncode == 0 and out.read_bytes() == kernel.read_bytes(), 'kernel is at EFI/gbos86/BOOTX64.EFI on the Windows ESP')
    o = work / 'x'; shutil.rmtree(o, ignore_errors=True); o.mkdir()
    r = run(['mcopy', '-n', '-s', '-i', f'{nvme}@@{off("GBOSSYS")}', '::gbos', str(o)])
    check(r.returncode == 0, 'GBOSSYS read back with mtools')
    bad = []
    srcg = work / 'gbos/gbos'
    for f in sorted(p for p in srcg.rglob('*') if p.is_file()):
        rel = f.relative_to(srcg)
        if rel.name in ('gbos.cfg', 'install.sh'): continue
        g = o / 'gbos' / rel
        if not g.exists() or g.read_bytes() != f.read_bytes(): bad.append(str(rel))
    check(not bad, f'every stick file is on GBOSSYS and identical ({len(bad)} differ{": " + ", ".join(bad[:5]) if bad else ""})')
    mi = o / 'gbos/metadata.img'
    check(mi.exists() and mi.stat().st_size == 64 * MIB, 'gbos/metadata.img (64 MiB) is on GBOSSYS: /metadata without a GBOS_META partition')
    if mi.exists():
        r = e2fsck(mi, 0)
        check(r.returncode == 0, 'metadata.img is a clean ext4 filesystem')
    check(e2fsck(nvme, off('GBOS_DATA')).returncode == 0, 'GBOS_DATA clean ext4')
    cfgi = (o / 'gbos/gbos.cfg').read_text() if (o / 'gbos/gbos.cfg').exists() else ''
    check('MODE=boot' in cfgi and 'MODE=install' not in cfgi, 'installed gbos.cfg boots normally')

print('== 3. update of the dual-boot install must not touch the fallback loader')
if parts and names[2:] == ['GBOSSYS', 'GBOS_DATA']:
    make_stick(stick, 'MODE=install\nLOAD_I915=0\nACTION=update\n', lambda G: (G / 'hook.sh').write_bytes(b'# changed on the stick\n'))
    txt, ok = qemu(stick, nvme, 'gbos_install_confirm=update-test', r'Update done\.', 900, 'update')
    check(ok and 'verify failed' not in txt, 'update completed and verified')
    windows_intact(nvme, 'after update')
    o2 = work / 'x2'; shutil.rmtree(o2, ignore_errors=True); o2.mkdir()
    run(['mcopy', '-n', '-s', '-i', f'{nvme}@@{off("GBOSSYS")}', '::gbos/hook.sh', str(o2)])
    check((o2 / 'hook.sh').exists() and (o2 / 'hook.sh').read_bytes().startswith(b'# changed on the stick'), 'changed file reached GBOSSYS')

print('== 4. a second dual-boot install is refused')
if parts and names[2:] == ['GBOSSYS', 'GBOS_DATA']:
    gpt_before = read_gpt(nvme)
    make_stick(stick, cfg)
    txt, ok = qemu(stick, nvme, f'gbos_install_confirm={SERIAL}', r'INSTALL FAILED|gbOS86 is installed|Update done|Found an existing', 600, 'again')
    check(ok and 'never a second dual-boot' in txt or 'Found an existing gbOS86 install' in txt, 'refused (or asked: an install exists)')
    check(read_gpt(nvme) == gpt_before, 'GPT unchanged')
    windows_intact(nvme, 'after the refused install')

print('== 5. not enough free space: refused before anything is written')
nvme.unlink(missing_ok=True)
nvme = fresh_nvme(free_gib=12, data_gib=12)   # >= 24 GB disk (installer minimum) but under 17 GB free
before = read_gpt(nvme)
with open(nvme, 'rb') as f: head0 = f.read(2 * MIB)
make_stick(stick, cfg)
txt, ok = qemu(stick, nvme, f'gbos_install_confirm={SERIAL}', r'INSTALL FAILED|gbOS86 is installed', 600, 'nospace')
check('dual-boot needs 17 GB' in txt, 'refused for lack of unallocated space')
with open(nvme, 'rb') as f: head1 = f.read(2 * MIB)
check(head0 == head1 and read_gpt(nvme) == before, 'nothing written')

if do_boot:
    print('== 6. boot from the NVMe alone')
    nvme.unlink(missing_ok=True); nvme = fresh_nvme()
    make_stick(stick, cfg)
    txt, ok = qemu(stick, nvme, f'gbos_install_confirm={SERIAL}', r'gbOS86 is installed on /dev/nvme0n1 alongside', 1500, 'install2')
    txt, ok = qemu(None, nvme, '', r'found gbos volume on nvme at /dev/nvme0n1p\d|FATAL: no GBOS', 240, 'boot')
    check(re.search(r'found gbos volume on nvme at /dev/nvme0n1p3', txt) is not None, 'stage0 found GBOSSYS (p3) without the stick')

print('RESULT:', 'ISA_EMU_INSTALLER_DUALBOOT_PASS' if not FAIL else 'FAILED: ' + '; '.join(FAIL))
if not keep: shutil.rmtree(work, ignore_errors=True)
sys.exit(1 if FAIL else 0)
