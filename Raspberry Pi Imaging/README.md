# Headless Raspberry Pi Imaging (Windows)

Authoritative procedure for writing a Raspberry Pi OS card that comes up on the
network **unattended, first time**, with no keyboard or monitor ever attached.

Written for an AI agent to follow start to finish. Every claim below was
verified empirically during a session that took roughly an hour and burned three
failed cards. Follow it and it takes about ten minutes.

> **Verified again 2026-10-02** for a **Raspberry Pi 5** with the 2026-09-15 Trixie
> Lite arm64 image: the same image serves Pi 4 and Pi 5, the initramfs fixup is
> byte-identical, `set_wlan` is still positional, `custom.toml` still absent.

---

## Read these two things first

### 1. Raspberry Pi OS **Trixie** does not support `custom.toml`

This is the single most expensive trap. Nearly every guide online (all
Bookworm-era) tells you to drop `custom.toml` on the boot partition to set
hostname, user, SSH and Wi-Fi.

**On Trixie that file is silently ignored.** Verified by scanning the image's
root filesystem:

```bash
# custom.toml appears ZERO times anywhere in the Trixie rootfs
python - <<'PY'
f=open('raspios.img','rb'); f.seek(545259520)   # p2 offset from the MBR
print(f.read(1400*1024*1024).count(b'custom.toml'))   # -> 0
PY
```

There is no code that reads it. The Pi boots, finds no uid-1000 user, and falls
through to the interactive `userconfig.service` wizard — which prints
**"Please enter new username"** on a console you cannot reach. On a headless Pi
that is a dead card.

> **Rule: verify the *mechanism* exists, not just that your file is present and
> well-formed.** A valid, correctly-populated `custom.toml` that nothing reads
> looks identical to a working one right up until the Pi is unreachable. Grep the
> image rootfs for the consuming code before trusting any provisioning file.

Use `firstrun.sh` instead (below).

### 2. Never interrupt the first boot

The stock `cmdline.txt` carries a `resize` token. On first boot the Pi:

1. grows the root partition to fill the card,
2. **regenerates the MBR disk signature / PARTUUID**,
3. rewrites `cmdline.txt` *and* `/etc/fstab` to match,
4. reboots itself.

Cut power partway and you get `cmdline.txt` updated but the partition table not,
which halts at:

```
ALERT!  PARTUUID=xxxxxxxx-02 does not exist.  Dropping to a shell!
```

**This is not repairable from Windows**, because `/etc/fstab` lives on ext4 which
Windows cannot read, so you cannot know how far the rewrite got. The card must be
re-imaged.

With provisioning there are **two or three automatic reboots**. They look like
hangs. Give it **3 full minutes** and do not touch it.

---

## Pre-flight checklist

| # | Check | Why |
|---|-------|-----|
| 1 | Terminal/agent launched **as Administrator** | Raw disk writes require it; see below. Doing it up front avoids repeated UAC prompts. |
| 2 | Target confirmed with `Get-Disk` — USB, removable, not system/boot | A wrong disk number destroys the host OS. |
| 3 | Image SHA256 verified against `extract_sha256` | See "Download & verify". |
| 4 | Wi-Fi SSID confirmed **on the air**, not from a saved profile | WPA SSIDs are case-sensitive; see "Wi-Fi". |
| 5 | Password hash generated: `openssl passwd -6 'pw'` | `firstrun.sh` needs a crypt hash, not plaintext. |

### Elevation is mandatory and unavoidable

Writing raw sectors to `\\.\PHYSICALDRIVE<n>` requires Administrator. This is a
Windows kernel restriction, **not** a tool choice — `dd`, Etcher,
Win32DiskImager and `rpi-imager` all hit the same wall, and rpi-imager has the
check compiled in:

```
ERROR: Not running as Administrator.
Writing to storage devices requires elevated privileges.
```

Do not burn time hunting for a tool that avoids it. Launch elevated.

---

## Step 1 — Download and verify the image

Get the current URL from Raspberry Pi's own manifest:

```powershell
$j = (Invoke-WebRequest 'https://downloads.raspberrypi.com/os_list_imagingutility_v4.json' -UseBasicParsing).Content | ConvertFrom-Json
($j.os_list | Where-Object name -eq 'Raspberry Pi OS (other)').subitems |
  Select-Object name, release_date, url, extract_sha256
```

**Gotcha:** `image_download_sha256` is published **empty**. Verifying against it
always reports a mismatch. Decompress first and verify the `.img` against
`extract_sha256`:

```bash
xz -dk -T0 raspios.img.xz
sha256sum raspios.img          # must equal extract_sha256
```

Use **Lite (64-bit)** for a headless server — no desktop, smaller attack surface.

---

## Step 2 — Write the card

```powershell
.\write_card.ps1 -ImagePath C:\path\to\raspios.img
```

Guards built in: refuses the system/boot disk, refuses non-USB, refuses >128 GB
or <4 GB, refuses an image larger than the target. Auto-selects when exactly one
removable USB disk is present. Expect ~26 MB/s (≈2 min for a 3 GB image).

### On `rpi-imager --cli` (don't bother on Windows)

Tested with **v2.0.10**: it exits `rc=1` after merely enumerating drives, writes
nothing, and produces **no stdout at all — not even for `--help`** — because it
is a GUI-subsystem binary whose output does not survive redirection. Only
`--log-file` yields anything:

```
[DEBUG] Drive added: "\\\\.\\PhysicalDrive1"
[DEBUG] Stopping background drive list polling      <- then it just exits
```

Its CLI also has **no option to apply the saved OS-customisation profile**; the
only provisioning hooks are `--first-run-script` and cloud-init. The GUI works
fine if a human is driving; for automation, use `write_card.ps1`.

---

## Step 3 — Provision with `firstrun.sh`

This is the mechanism Trixie actually supports.

1. Copy `firstrun.sh` (from `firstrun.sh.template`, placeholders filled) to the
   **root of the boot partition**, e.g. `D:\firstrun.sh`.
2. Append this to `cmdline.txt` — **on the same single line**, space-separated:

```
systemd.run=/boot/firstrun.sh systemd.run_success_action=reboot systemd.unit=kernel-command-line.target
```

```python
# byte-precise; cmdline.txt must stay ONE line
HOOK = ' systemd.run=/boot/firstrun.sh systemd.run_success_action=reboot systemd.unit=kernel-command-line.target'
p = 'D:/cmdline.txt'
line = open(p, 'rb').read().decode('ascii').strip()
if 'systemd.run=' not in line:
    open(p, 'wb').write((line + HOOK + '\n').encode('ascii'))
```

3. Delete any `custom.toml` — it does nothing but mislead.

### Use the literal `/boot/` path, not `/boot/firmware/`

Counter-intuitive but required. The image ships an initramfs fixup that greps
for **exactly** `systemd.run=/boot/firstrun.sh`:

```sh
if ! grep -q 'systemd\.run=/boot/firstrun\.sh' /proc/cmdline; then exit 0; fi
sed -i 's|/boot/|/boot/firmware/|g' /run/imager_fixup/cmdline.txt
sed -n -i '/rm.*firstrun\.sh$/q;p' /run/imager_fixup/firstrun.sh
cat >> /run/imager_fixup/firstrun.sh << \EOF
rm -f /boot/firmware/firstrun.sh
sed -i 's| systemd\.[^ ]*||g' /boot/firmware/cmdline.txt
exit 0
EOF
```

Write `/boot/firmware/` yourself and the grep fails, the fixup never runs, and
nothing is provisioned. Two consequences of that `sed -n` line:

- **`firstrun.sh` must END with `rm -f /boot/firstrun.sh`.** The fixup truncates
  at the first line matching `/rm.*firstrun\.sh$/` and appends its own cleanup.
  Anything after that line is discarded.
- **No earlier line may match that regex — comments included.** While writing
  the template for this repo, a *comment* reading `=> The LAST line ... must be:
  rm -f /boot/firstrun.sh` matched at line 13 and would have truncated all 164
  remaining lines, producing a silently unprovisioned Pi. `simulate_fixup.sh`
  caught it. Run it.

---

## Step 4 — Prove the chain before ejecting

**Do not skip this.** It is what finally made the process succeed, and it costs
seconds. It replays the initramfs fixup against your real files:

```bash
./simulate_fixup.sh /d          # /d = mounted boot partition
```

It verifies the hook triggers, the path rewrites to `/boot/firmware/firstrun.sh`,
`root=PARTUUID=` survives, the truncated script still parses, your config
survived truncation, and it won't re-trigger on later boots.

### Verification checklist

| Check | Command | Expected |
|-------|---------|----------|
| PARTUUID == disk signature | `(Get-Disk -N 1).Signature` vs `root=PARTUUID=` | must match, else `ALERT!` at boot |
| `cmdline.txt` line count | `wc -l < /d/cmdline.txt` | exactly 1 |
| `firstrun.sh` endings | `tr -dc '\r' < /d/firstrun.sh \| wc -c` | 0 (CRLF breaks it) |
| `firstrun.sh` last line | `tail -1 /d/firstrun.sh` | `rm -f /boot/firstrun.sh` |
| Syntax | `bash -n /d/firstrun.sh` | clean |
| No stale `custom.toml` | `ls /d/custom.toml` | absent |

**PARTUUID vs signature** deserves emphasis. For an MBR disk the PARTUUID is
`<4-byte disk signature>-<partition number>`. Readable on Windows **without
elevation**:

```powershell
'{0:x8}' -f (Get-Disk -Number 1).Signature      # e.g. 041bba91
Get-Content D:\cmdline.txt                       # root=PARTUUID=041bba91-02
```

Mismatch ⇒ the Pi halts in an initramfs shell.

> Note: **Windows does *not* re-stamp the MBR signature** of a freshly imaged
> card. That was suspected and disproved by direct comparison. Do not add
> defensive signature-rewriting — an earlier attempt to do so hung indefinitely
> opening `\\.\PHYSICALDRIVE1` while the volume was still mounted.

Then eject:

```powershell
(New-Object -ComObject Shell.Application).Namespace(17).ParseName('D:').InvokeVerb('Eject')
```

---

## Step 5 — Boot and connect

Insert, power on, **wait 3 minutes untouched**. Sequence:

1. initramfs fixup rewrites paths → reboot
2. `firstrun.sh` provisions → reboot
3. normal boot, fully configured

Then:

```powershell
[System.Net.Dns]::GetHostAddresses('yourhostname.local')
ssh -i ~\.ssh\id_rsa user@yourhostname.local
```

If mDNS fails, sweep the subnet and look for Raspberry Pi MAC OUIs
(`b8:27:eb`, `dc:a6:32`, `e4:5f:01`, `28:cd:c1`, `2c:cf:67`, `d8:3a:dd`):

```powershell
Get-NetNeighbor -AddressFamily IPv4 | Where-Object IPAddress -like '192.168.1.*'
```

**Always confirm provisioning actually ran** rather than assuming:

```bash
sudo cat /var/log/firstrun-provision.log
```

Ethernet is the reliable path and needs no configuration (DHCP). Treat Wi-Fi as
the fallback.

---

## Wi-Fi

### Verify the SSID against the air, never a saved profile

WPA SSIDs are **case-sensitive**. In this session a saved rpi-imager profile in
the registry recorded the SSID with a capital first letter while the access point
actually broadcast it lowercase. Trusting the registry over the user's own
(correct) spelling broke a working value and cost another cycle.

```bash
sudo nmcli device wifi list        # ground truth
```

### Prefer the passphrase over a precomputed PSK

The WPA PSK is derived from **both** passphrase and SSID:

```python
hashlib.pbkdf2_hmac('sha1', passphrase, ssid, 4096, 32)
```

So a precomputed PSK is silently wrong if the SSID case is off by one character —
and it fails as "network not found", which points you at the wrong problem. Hand
NetworkManager the plaintext passphrase and let it derive the key from the real
SSID.

### `imager_custom set_wlan` takes positional arguments

```
set_wlan [-h|--hidden] [-p|--plain] SSID [PASS [COUNTRY]]
```

Passing `-c AU` prints usage and **silently does nothing**, returning non-zero.
Because such a call typically sits inside an `if`, the else-branch fallback never
runs and Wi-Fi ends up unconfigured with no error surfaced. **Always check the
exit status of these helpers** — the template does.

Fix afterwards over SSH:

```bash
sudo nmcli con add type wifi con-name preconfigured ifname wlan0 ssid 'ExactSSID' \
     wifi-sec.key-mgmt wpa-psk wifi-sec.psk 'passphrase' connection.autoconnect yes
sudo nmcli con up preconfigured
```

---

## Peripherals (I2C / 1-Wire)

`raspi-config nonint` uses **0 = enable** (counter-intuitive):

```bash
sudo raspi-config nonint do_i2c 0
sudo raspi-config nonint do_onewire 0
```

`config.txt` equivalents:

```
dtparam=i2c_arm=on
dtparam=i2c_arm_baudrate=100000          # 100 kHz: long/daisy-chained runs
dtoverlay=w1-gpio,gpiopin=4,pullup=on
```

Verify:

```bash
ls /dev/i2c-*                  # /dev/i2c-1 expected
lsmod | grep -E 'i2c|w1_'
ls /sys/bus/w1/devices/
```

**1-Wire phantoms:** entries with family code `00-*` (e.g. `00-400000000000`)
mean **no probe is attached** — that is a floating bus, not a device. A real
DS18B20 enumerates as `28-*`. Don't mistake phantoms for a working sensor.

`i2c-tools` (for `i2cdetect`) is **not** installed on Lite: `sudo apt install -y i2c-tools`.

---

## Windows scripting gotchas that cost real time

| Gotcha | Symptom | Fix |
|--------|---------|-----|
| `echo EXITCODE=%ERRORLEVEL%>> f` in batch | `EXITCODE=` always empty | cmd parses the expanded `1>` as a **stream redirect** and eats the digit. Put a **space** before `>>`. |
| `Start-Process -PassThru` without `-Wait` | `.ExitCode` empty ⇒ every run looks failed | Use `-Wait`, or a batch wrapper reading `%ERRORLEVEL%`. Diagnosing with a broken instrument wastes cycles. |
| Literal `\\.\` through shells/heredocs | Became `\.\`, resolving to `C:\PhysicalDrive1` → "Could not find file" | Build from `[char]92`: `$bs+$bs+'.'+$bs+'PHYSICALDRIVE'+$n`. |
| GUI-subsystem exe + `-RedirectStandardOutput` | Zero output captured | Redirect via `cmd /c "app > out.txt 2>&1"`, or use the app's own `--log-file`. |
| Git Bash `HOME` ≠ `USERPROFILE` | `~/.ssh` empty, SSH auth fails | `HOME` may be e.g. `C:\SPB_Data`. Pass keys explicitly with `-i`. |

---

## Files here

| File | Purpose |
|------|---------|
| `README.md` | This procedure. |
| `TROUBLESHOOTING.md` | Symptom → cause → fix. |
| `firstrun.sh.template` | Provisioning script; fill the `{{PLACEHOLDERS}}`. |
| `write_card.ps1` | Guarded raw writer + PARTUUID verification. |
| `simulate_fixup.sh` | Pre-eject proof the boot chain fires. |

No secrets are stored in this repository. Fill placeholders at use time.
