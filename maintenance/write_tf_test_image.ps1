# Apply a reviewed image plan to one identity-checked USB card, then compare every written byte.
param(
    [Parameter(Mandatory=$true)][string]$PlanPath,
    [Parameter(Mandatory=$true)][string]$OutDir
)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$sandbox = [IO.Path]::GetFullPath((Join-Path $repoRoot 'work')) + '\'
$targetDir = [IO.Path]::GetFullPath($OutDir)
if (-not $targetDir.StartsWith($sandbox, [StringComparison]::OrdinalIgnoreCase)) { throw 'Output must be below work.' }
if (Test-Path -LiteralPath $targetDir) { throw 'Output directory must be new.' }
New-Item -ItemType Directory -Path $targetDir | Out-Null
$started = Get-Date
$written = 0L
$writeAttempted = $false
$volume = $null
$volumeLocked = $false
$diskStream = $null
$image = $null
function Report-Progress([string]$stage, [long]$bytes) {
    @{stage=$stage; bytes=$bytes; time=(Get-Date -Format o)} | ConvertTo-Json |
        Set-Content -LiteralPath (Join-Path $targetDir 'progress.json') -Encoding UTF8
}
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class TfImageIO {
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool DeviceIoControl(SafeFileHandle handle, uint code,
        IntPtr input, uint inputSize, IntPtr output, uint outputSize, out uint returned, IntPtr overlapped);
    public static void Control(SafeFileHandle handle, uint code) {
        uint returned;
        if (!DeviceIoControl(handle, code, IntPtr.Zero, 0, IntPtr.Zero, 0, out returned, IntPtr.Zero))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    }
    public static void ReadExact(Stream stream, byte[] buffer, int count) {
        int done = 0;
        while (done < count) {
            int n = stream.Read(buffer, done, count - done);
            if (n == 0) throw new EndOfStreamException("Short image/card read");
            done += n;
        }
    }
    public static void Compare(byte[] expected, byte[] actual, int count, long offset) {
        for (int i = 0; i < count; i++)
            if (expected[i] != actual[i]) throw new IOException("Readback mismatch at byte " + (offset + i));
    }
}
'@
try {
    $plan = Get-Content -LiteralPath $PlanPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($plan.status -ne 'prepared_not_executed' -or $plan.physical_card_written -ne $false -or
        $plan.overwrite_offset -ne 0 -or $plan.overwrite_bytes -le 0 -or ($plan.overwrite_bytes % 512) -ne 0 -or
        $plan.overwrite_bytes -gt $plan.target_bytes) { throw 'Invalid reviewed write plan.' }
    $diskNumber = [int]$plan.target_disk_number_at_preparation
    function Assert-CardIdentity {
        $disk = Get-Disk -Number $diskNumber
        if ($disk.BusType -ne 'USB' -or $disk.Size -ne $plan.target_bytes -or
            $disk.FriendlyName -ne $plan.target_name -or $disk.SerialNumber.Trim() -ne $plan.target_serial -or
            $disk.IsBoot -or $disk.IsSystem) { throw 'Target identity changed; refusing write.' }
    }
    Assert-CardIdentity
    $backup = Get-Content -LiteralPath $plan.backup_manifest -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($backup.status -ne 'verified' -or $backup.bytes -ne $plan.target_bytes -or
        $backup.serial -ne $plan.target_serial -or $backup.name -ne $plan.target_name -or
        $backup.source_read_sha256 -ne $plan.backup_sha256 -or
        $backup.saved_image_sha256 -ne $plan.backup_sha256 -or
        (Get-Item -LiteralPath $plan.backup_image).Length -ne $plan.target_bytes) { throw 'Backup evidence mismatch.' }
    Report-Progress 'verifying_backup' 0
    if ((Get-FileHash -LiteralPath $plan.backup_image -Algorithm SHA256).Hash -ne $plan.backup_sha256) {
        throw 'Full backup hash mismatch.'
    }
    $image = [IO.File]::Open($plan.test_image, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { $imageHash = [BitConverter]::ToString($hasher.ComputeHash($image)).Replace('-', '').ToLowerInvariant() }
    finally { $hasher.Dispose() }
    if ($image.Length -ne $plan.overwrite_bytes -or $imageHash -ne $plan.test_image_sha256) { throw 'Test image mismatch.' }
    [void]$image.Seek(0, [IO.SeekOrigin]::Begin)
    Assert-CardIdentity
    $partitions = @(Get-Partition -DiskNumber $diskNumber)
    if ($partitions.Count -ne 1 -or $partitions[0].Offset -ne 0 -or
        [string]$partitions[0].DriveLetter -notmatch '^[A-Z]$') { throw 'Unexpected card volume layout.' }
    $volumePath = '\\.\' + $partitions[0].DriveLetter + ':'
    $volume = [IO.File]::Open($volumePath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)
    [TfImageIO]::Control($volume.SafeFileHandle, 0x00090018) # FSCTL_LOCK_VOLUME
    $volumeLocked = $true
    [TfImageIO]::Control($volume.SafeFileHandle, 0x00090020) # FSCTL_DISMOUNT_VOLUME
    $device = '\\.\PhysicalDrive' + $diskNumber
    $diskStream = [IO.File]::Open($device, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)
    $prefix = New-Object byte[] (16MB)
    [TfImageIO]::ReadExact($diskStream, $prefix, $prefix.Length)
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { $prefixHash = [BitConverter]::ToString($hasher.ComputeHash($prefix)).Replace('-', '').ToLowerInvariant() }
    finally { $hasher.Dispose() }
    if ($prefixHash -ne $backup.prefix_sha256) { throw 'Card contents changed since backup; refusing write.' }
    [void]$diskStream.Seek(0, [IO.SeekOrigin]::Begin)
    $buffer = New-Object byte[] (4MB)
    Report-Progress 'writing' 0
    $writeAttempted = $true
    while ($written -lt $plan.overwrite_bytes) {
        $count = [int][Math]::Min([long]$buffer.Length, [long]$plan.overwrite_bytes - $written)
        [TfImageIO]::ReadExact($image, $buffer, $count)
        $diskStream.Write($buffer, 0, $count)
        $written += $count
        Report-Progress 'writing' $written
    }
    $diskStream.Flush($true)
    $diskStream.Dispose()
    $diskStream = [IO.File]::Open($device, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    [void]$image.Seek(0, [IO.SeekOrigin]::Begin)
    $actual = New-Object byte[] $buffer.Length
    $readbackPath = Join-Path $targetDir 'readback_fat32.img'
    $readback = [IO.File]::Open($readbackPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try {
        $verified = 0L
        while ($verified -lt $written) {
            $count = [int][Math]::Min([long]$buffer.Length, $written - $verified)
            [TfImageIO]::ReadExact($image, $buffer, $count)
            [TfImageIO]::ReadExact($diskStream, $actual, $count)
            [TfImageIO]::Compare($buffer, $actual, $count, $verified)
            $readback.Write($actual, 0, $count)
            $verified += $count
            Report-Progress 'verifying_readback' $verified
        }
        $readback.Flush($true)
    } finally { $readback.Dispose() }
    $readbackHash = (Get-FileHash -LiteralPath $readbackPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($readbackHash -ne $imageHash) { throw 'Saved readback hash mismatch.' }
    @{
        status='verified'; started=$started.ToString('o'); completed=(Get-Date -Format o);
        device=$device; target_name=$plan.target_name; serial=$plan.target_serial; target_bytes=$plan.target_bytes;
        written_bytes=$written; verified_bytes=$verified; overwrite_offset=0;
        test_image=$plan.test_image; image_sha256=$imageHash; readback=$readbackPath; readback_sha256=$readbackHash;
        backup_image=$plan.backup_image; backup_sha256=$plan.backup_sha256; physical_card_written=$true;
        verification='Every byte compared after flush and reopening the card read-only; saved readback SHA256 matches image.';
        script_sha256=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $targetDir 'manifest.json') -Encoding UTF8
    Report-Progress 'verified' $verified
} catch {
    @{status='error'; message=$_.Exception.Message; written_bytes=$written; write_attempted=$writeAttempted;
      time=(Get-Date -Format o)} | ConvertTo-Json |
        Set-Content -LiteralPath (Join-Path $targetDir 'error.json') -Encoding UTF8
    exit 1
} finally {
    if ($null -ne $diskStream) { $diskStream.Dispose() }
    if ($null -ne $image) { $image.Dispose() }
    if ($null -ne $volume) {
        if ($volumeLocked) { [TfImageIO]::Control($volume.SafeFileHandle, 0x0009001c) } # FSCTL_UNLOCK_VOLUME
        $volume.Dispose()
    }
}
