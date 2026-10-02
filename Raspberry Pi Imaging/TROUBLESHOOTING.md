# Troubleshooting — Headless Raspberry Pi Imaging

Symptom → cause → fix. Every entry below was hit for real; none are hypothetical.

---

## Boot-time symptoms

### `ALERT! PARTUUID=xxxxxxxx-02 does not exist. Dropping to a shell!`

Console also shows `mmcblk0: p1 p2` — the partitions *are* there.

**Cause.** `cmdline.txt`'s `root=PARTUUID=` no longer matches the MBR disk
signature. Almost always because **first boot was interrupted mid-resize**: the
`resize` token makes the Pi grow the rootfs, regenerate the PARTUUID, and rewrite
`cmdline.txt` + `/etc/fstab`. Interrupt it and `cmdline.txt` is updated while the
partition table is not.

Diagnostic — if the PARTUUID appears **nowhere in the pristine image**, the Pi
minted it itself, which proves an interrupted resize rather than a bad write:

```bash
# what the pristine image ships with
python - <<'PY'
import struct
mbr = open('raspios.img','rb').read(512)
print('image signature: %08x' % struct.unpack('<I', mbr[0x1B8:0x1BC])[0])
PY
```

**Fix.** Re-image. **Not repairable from Windows** — `/etc/fstab` is on ext4,
unreadable there, so you cannot tell how far the rewrite got. Patching only the
signature may leave `fstab` inconsistent and fail later or drop to emergency mode.

**Prevent.** After inserting the card, leave the Pi alone for 3 full minutes. Two
or three automatic reboots are normal and look like hangs.

---

### `Please enter new username` on the console

**Cause.** Provisioning silently did not run. The Pi found no uid-1000 user and
fell through to the interactive `userconfig.service` wizard. Fatal when headless.

Usually one of:

| Root cause | Check |
|---|---|
| Used `custom.toml` on **Trixie** — unsupported, silently ignored | `grep -c custom.toml` in image rootfs → `0` |
| Hook written as `/boot/firmware/firstrun.sh` instead of `/boot/` | `grep 'systemd\.run=/boot/firstrun\.sh' /d/cmdline.txt` |
| Hook missing from `cmdline.txt` entirely | as above |
| `firstrun.sh` has CRLF endings | `tr -dc '\r' < /d/firstrun.sh \| wc -c` → must be `0` |
| `firstrun.sh` truncated early by a stray `rm ... firstrun.sh` line | `tail -1` must be that line, and it must appear only once |

**Fix without re-imaging.** The card is healthy; only provisioning failed. Put it
back in the reader and patch the FAT boot partition — **no elevation and no
re-image needed**:

1. copy `firstrun.sh` to `D:\firstrun.sh`
2. append the `systemd.run=/boot/firstrun.sh ...` hook to `cmdline.txt`
3. delete `custom.toml`
4. run `./simulate_fixup.sh /d`
5. eject, boot, wait 3 minutes

---

### Pi boots but is unreachable on the network

1. Is it on Ethernet? That path needs no configuration (DHCP) and is the reliable one.
2. mDNS: `[System.Net.Dns]::GetHostAddresses('host.local')`
3. Sweep ARP for Pi OUIs `b8:27:eb`, `dc:a6:32`, `e4:5f:01`, `28:cd:c1`, `2c:cf:67`, `d8:3a:dd`:
   `Get-NetNeighbor -AddressFamily IPv4 | Where-Object IPAddress -like '192.168.1.*'`
4. Confirm SSH is actually listening — read the banner rather than guessing:

```powershell
$c = New-Object System.Net.Sockets.TcpClient; $c.Connect($ip,22)
$b = New-Object byte[] 128; $n = $c.GetStream().Read($b,0,128)
[Text.Encoding]::ASCII.GetString($b,0,$n)      # SSH-2.0-OpenSSH_... Debian...
```

Don't identify the host by mDNS name alone — verify with `hostname` over SSH.
An mDNS answer can point at a stale or unrelated device.

---

## Wi-Fi symptoms

### `Error: Connection activation failed: The Wi-Fi network could not be found`

**Cause (most likely).** SSID case mismatch. WPA SSIDs are case-sensitive, and
this error points you at radio/range problems rather than at spelling.

**Fix.** Get ground truth from the air, never from a saved profile or registry entry:

```bash
sudo nmcli device wifi list
sudo nmcli con modify preconfigured wifi.ssid 'ExactCaseSSID'
sudo nmcli con up preconfigured
```

A saved rpi-imager profile is **not** authoritative — one recorded the SSID with
the wrong capitalisation, and its stored PSK was derived from that wrong spelling,
so that profile could never have connected either.

### Wi-Fi silently unconfigured, no error anywhere

**Cause.** `imager_custom set_wlan` called with `-c AU`. Its arguments are
**positional**:

```
set_wlan [-h|--hidden] [-p|--plain] SSID [PASS [COUNTRY]]
```

A flag it doesn't recognise makes it print usage and exit non-zero **without
configuring anything**. If the call sits inside `if ... then ... else <fallback>`,
the fallback never runs — the `if` succeeded structurally.

Look for this in `/var/log/firstrun-provision.log`:

```
Usage:
  /usr/lib/raspberrypi-sys-mods/imager_custom set_wlan [-h|--hidden] [-p|--plain] SSID [PASS [COUNTRY]]
wifi done                      <-- "done" is a lie
```

**Fix.** Use positional args and check the exit status (the template does).

### Connects but the wrong key is used

**Cause.** A precomputed PSK hex was supplied. The PSK is derived from
`(passphrase, SSID)`, so it is silently invalid if the SSID differs at all.

**Fix.** Supply the plaintext passphrase and let NetworkManager derive the key.

---

## Windows / tooling symptoms

### `rpi-imager --cli` exits 1 immediately with no output

Verified on **v2.0.10**. It enumerates drives, then tears down and exits `rc=1`
without writing. It emits **nothing** to stdout — not even for `--help` — because
it is a GUI-subsystem binary whose output does not survive redirection.

**Diagnose.** Only `--log-file` produces anything:

```powershell
rpi-imager.exe --cli --debug --log-file C:\tmp\imager.log --first-run-script f.sh img.img \\.\PHYSICALDRIVE1
```

**Fix.** Use `write_card.ps1`. The Imager **GUI** works if a human drives it; its
CLI is not viable for automation on Windows, and it has no flag to apply the saved
OS-customisation profile anyway.

### Elevated `write_card.ps1` exits 1 instantly, no log, nothing written

**Cause.** Launching it with `Start-Process powershell -Verb RunAs -ArgumentList "-File `"...\AI Tools\...\write_card.ps1`" ..."`:
the quoting of a path containing a space does not survive the elevation hop, and
the elevated window closes before anything can be read (2026-10-02).

**Fix.** Put a small wrapper `.ps1` in a space-free directory that calls
`& 'C:\...\write_card.ps1' -ImagePath ... -DiskNumber N -LogPath ... -Confirm:$false`
inside `Start-Transcript`, and elevate the wrapper with an argument **array**:
`Start-Process powershell.exe -Verb RunAs -Wait -PassThru -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$wrapper`"")`.
The transcript gives you the full log afterwards.

### `Could not find file 'C:\PhysicalDrive1'`

**Cause.** A literal `\\.\` string lost a backslash passing through a shell or
heredoc, becoming `\.\PhysicalDrive1`, which resolves relative to `C:`.

**Fix.** Build the path from char codes:

```powershell
$bs = [string][char]92
$dev = $bs + $bs + '.' + $bs + 'PHYSICALDRIVE' + $n
```

### Exit codes always empty; everything looks like it failed

**Cause.** `Start-Process -PassThru` **without** `-Wait` returns a process object
whose `.ExitCode` is inaccessible.

**Fix.** Use `-Wait`, or wrap in a batch file reading `%ERRORLEVEL%`. Be alert to
this: it produces confident false failure readings and sends you chasing
non-existent bugs.

### Batch `EXITCODE=` always empty

**Cause.** `echo EXITCODE=%ERRORLEVEL%>> f` expands to `echo EXITCODE=1>> f`, and
cmd parses the trailing `1>` as a **stream redirect**, consuming the digit.

**Fix.** Put a space before `>>`: `echo EXITCODE=%ERRORLEVEL% >> f`

### `git@github.com: Permission denied (publickey)` although the key is valid

**Cause.** In Git Bash `HOME` may be something like `C:\SPB_Data`, not
`C:\Users\<you>`, so `~/.ssh` resolves to a non-existent directory.

**Fix.**

```bash
export GIT_SSH_COMMAND='ssh -i /c/Users/<you>/.ssh/id_rsa -o IdentitiesOnly=yes'
```

Confirm which identity you are: `ssh -T -i <key> git@github.com` → `Hi <user>!`

### Hang opening `\\.\PHYSICALDRIVE1` after writing

**Cause.** Opening the physical drive while its volume is mounted, typically from
a defensive MBR-signature rewrite.

**Fix.** Remove it. **Windows does not re-stamp the signature** of a freshly
imaged card — tested and disproved by direct comparison against the image.

---

## Peripheral symptoms

### 1-Wire devices appear as `00-400000000000`

Family code `00` = **phantom**. The bus is floating with **no probe attached**. A
real DS18B20 enumerates as `28-*`. Check wiring, 3V3 power, and the 4.7 kΩ pull-up.

### `i2cdetect: command not found`

`i2c-tools` is not installed on Raspberry Pi OS Lite: `sudo apt install -y i2c-tools`

### I2C devices intermittent / NACK on long cable runs

Drop the bus speed — cable capacitance is usually the culprit:

```
dtparam=i2c_arm_baudrate=100000
```

---

## General principle

Nearly every failure above shares one shape: **a file was verified as present and
well-formed, but nothing verified the system would act on it.** Valid input to a
mechanism that does not exist looks exactly like success until the device is
unreachable.

Before trusting any provisioning file, confirm the consuming code exists — grep
the image rootfs — and where you can, simulate the chain (`simulate_fixup.sh`)
while the card is still in the reader and mistakes are cheap.
