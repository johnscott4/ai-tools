<#
.SYNOPSIS
    Write a Raspberry Pi OS image to an SD card on Windows, with safety guards
    and a mandatory PARTUUID-vs-signature verification before ejection.

.DESCRIPTION
    Raw disk writes on Windows REQUIRE Administrator. This is a kernel
    restriction, not a tool choice - dd, Etcher, Win32DiskImager and
    rpi-imager all hit it. Launch your terminal elevated up front.

    This script does NOT provision the OS. After writing, copy firstrun.sh onto
    the boot partition and append the systemd.run hook to cmdline.txt - see
    README.md. Then run simulate_fixup.sh before ejecting.

.EXAMPLE
    .\write_card.ps1 -ImagePath C:\images\raspios.img
    .\write_card.ps1 -ImagePath C:\images\raspios.img -DiskNumber 1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$ImagePath,
    # Omit to auto-select the single removable USB disk.
    [int]$DiskNumber = -1,
    [string]$LogPath = "$PSScriptRoot\write_card.log"
)

$ErrorActionPreference = 'Stop'

function Log($m) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m
    Write-Host $line
    Add-Content -Path $LogPath -Value $line -Encoding utf8
}

Set-Content -Path $LogPath -Value '' -Encoding utf8
Log "=== SD card write ==="

# ---------------------------------------------------------------- elevation
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "NOT ELEVATED. Raw disk writes require Administrator on Windows. Relaunch elevated."
}
Log "elevated: yes"

if (-not (Test-Path $ImagePath)) { throw "Image not found: $ImagePath" }
$img = Get-Item $ImagePath
Log ("image: {0} ({1:N0} bytes)" -f $img.Name, $img.Length)

# ------------------------------------------------------------ disk selection
if ($DiskNumber -lt 0) {
    $cands = @(Get-Disk | Where-Object { $_.BusType -eq 'USB' -and -not $_.IsSystem -and -not $_.IsBoot })
    if ($cands.Count -ne 1) {
        Get-Disk | Format-Table Number, FriendlyName, BusType, @{n='GB';e={[math]::Round($_.Size/1GB,1)}}, IsSystem, IsBoot
        throw "Expected exactly one removable USB disk; found $($cands.Count). Pass -DiskNumber explicitly."
    }
    $DiskNumber = $cands[0].Number
}
$d = Get-Disk -Number $DiskNumber
Log ("target: disk {0} '{1}' bus={2} {3} GB system={4} boot={5}" -f `
     $d.Number, $d.FriendlyName, $d.BusType, [math]::Round($d.Size/1GB,1), $d.IsSystem, $d.IsBoot)

# ------------------------------------------------------------ safety guards
if ($d.IsSystem)          { throw "REFUSING: disk $DiskNumber is the system disk" }
if ($d.IsBoot)            { throw "REFUSING: disk $DiskNumber is the boot disk" }
if ($d.BusType -ne 'USB') { throw "REFUSING: disk $DiskNumber bus is '$($d.BusType)', expected USB" }
if ($d.Size -gt 128GB)    { throw "REFUSING: disk $DiskNumber is $([math]::Round($d.Size/1GB,1))GB - too large for an SD card" }
if ($d.Size -lt 4GB)      { throw "REFUSING: disk $DiskNumber is $([math]::Round($d.Size/1GB,1))GB - too small" }
if ($img.Length -gt $d.Size) { throw "REFUSING: image is larger than the target disk" }
Log "safety checks passed"

if (-not $PSCmdlet.ShouldProcess("disk $DiskNumber ($($d.FriendlyName))", "ERASE and write $($img.Name)")) {
    Log "WhatIf / declined - nothing written"; return
}

# ------------------------------------------------------------------- write
# Clear the partition table first so Windows releases volume locks.
if ((Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0) {
    Clear-Disk -Number $DiskNumber -RemoveData -RemoveOEM -Confirm:$false -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Log "partition table cleared"
}

# GOTCHA: a literal '\\.\' string gets mangled passing through shells and
# heredocs (it silently became '\.\' once, resolving to C:\PhysicalDrive1).
# Build it from char codes so it survives any quoting layer.
$bs  = [string][char]92
$dev = $bs + $bs + '.' + $bs + 'PHYSICALDRIVE' + $DiskNumber
Log "device: $dev"

$src = [System.IO.File]::Open($ImagePath, [System.IO.FileMode]::Open,
                              [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
$dst = New-Object System.IO.FileStream($dev, [System.IO.FileMode]::Open,
                              [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::ReadWrite)
try {
    $bufSize = 4MB                       # must be a multiple of the 512 B sector size
    $buf     = New-Object byte[] $bufSize
    $total   = $src.Length
    $written = 0L
    $lastPct = -1
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    while ($true) {
        $n = $src.Read($buf, 0, $bufSize)
        if ($n -le 0) { break }
        if ($n -ne $bufSize) {           # pad a short final read up to a sector
            $pad = [int]([math]::Ceiling($n / 512.0) * 512)
            for ($i = $n; $i -lt $pad; $i++) { $buf[$i] = 0 }
            $n = $pad
        }
        $dst.Write($buf, 0, $n)
        $written += $n
        $pct = [int](100 * $written / $total)
        if ($pct -ne $lastPct -and $pct % 10 -eq 0) {
            $mbps = [math]::Round(($written/1MB) / [math]::Max($sw.Elapsed.TotalSeconds, 0.001), 1)
            Log ("  {0,3}%  {1} / {2} MB   {3} MB/s" -f $pct, [int]($written/1MB), [int]($total/1MB), $mbps)
            $lastPct = $pct
        }
    }
    Log "flushing to card (can take a while)..."
    $dst.Flush($true)
    $sw.Stop()
    Log ("write complete: {0:N0} bytes in {1}" -f $written, $sw.Elapsed.ToString('mm\:ss'))
}
finally {
    $dst.Close(); $src.Close()
}

# NOTE: deliberately NO MBR-signature rewriting here. Windows does NOT re-stamp
# the signature of a freshly imaged card - that was tested and disproved. The
# defensive rewrite added previously only caused a hang opening the physical
# drive while the volume was mounted.

Update-HostStorageCache
Start-Sleep -Seconds 4

# ------------------------------------------------ MANDATORY verification
Log "--- verification ---"
$ok = $true

$parts = Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue
foreach ($p in $parts) {
    Log ("  part {0} letter={1} {2} MB type={3}" -f $p.PartitionNumber, $p.DriveLetter, [int]($p.Size/1MB), $p.Type)
}

$boot = $parts | Where-Object { $_.DriveLetter -and $_.Size -lt 2GB } | Select-Object -First 1
if (-not $boot) { Log "  FAIL: boot (FAT32) partition did not mount"; $ok = $false }
else {
    $bl = $boot.DriveLetter
    # PARTUUID for an MBR disk is <disk signature>-<partition number>. If the
    # cmdline PARTUUID and the on-disk signature disagree, the Pi halts with
    # "ALERT! PARTUUID=xxxxxxxx-02 does not exist" and drops to an initramfs shell.
    $sig  = '{0:x8}' -f (Get-Disk -Number $DiskNumber).Signature
    $cl   = (Get-Content "${bl}:\cmdline.txt" -Raw).Trim()
    Log "  disk signature   : $sig"
    Log "  cmdline.txt      : $cl"
    if ($cl -match 'root=PARTUUID=([0-9a-fA-F]{8})-') {
        $cu = $Matches[1].ToLower()
        if ($cu -eq $sig) { Log "  PARTUUID $cu MATCHES signature - will boot" }
        else { Log "  FAIL: cmdline PARTUUID $cu != disk signature $sig"; $ok = $false }
    } else { Log "  WARN: no root=PARTUUID= found in cmdline.txt" }

    if (($cl -split "`n").Count -ne 1) { Log "  FAIL: cmdline.txt must be a single line"; $ok = $false }
}

if ($ok) { Log "=== VERIFICATION PASSED ===" } else { Log "=== VERIFICATION FAILED - DO NOT BOOT THIS CARD ===" }

Log ""
Log "NEXT: copy firstrun.sh to ${bl}:\firstrun.sh, append the systemd.run hook to"
Log "      cmdline.txt, then run simulate_fixup.sh BEFORE ejecting. See README.md."

if (-not $ok) { exit 1 }
