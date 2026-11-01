# Read-only whole-card backup. No physical-disk write handle is opened.
param(
    [Parameter(Mandatory=$true)][int]$DiskNumber,
    [Parameter(Mandatory=$true)][long]$ExpectedBytes,
    [Parameter(Mandatory=$true)][string]$ExpectedSerial,
    [Parameter(Mandatory=$true)][string]$ExpectedName,
    [Parameter(Mandatory=$true)][string]$OutDir,
    [Parameter(Mandatory=$true)][string]$ExpectedPrefixSha256
)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$sandbox = [IO.Path]::GetFullPath((Join-Path $repoRoot 'work')) + '\'
$targetDir = [IO.Path]::GetFullPath($OutDir)
if (-not $targetDir.StartsWith($sandbox, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Backup output must be below work.'
}
if (Test-Path -LiteralPath $targetDir) { throw 'Backup directory must be new.' }
New-Item -ItemType Directory -Path $targetDir | Out-Null
$progressPath = Join-Path $targetDir 'progress.json'
$partialPath = Join-Path $targetDir 'full_card.img.partial'
$imagePath = Join-Path $targetDir 'full_card.img'
$started = Get-Date
function Report-Progress([string]$stage, [long]$copied) {
    @{stage=$stage; bytes=$copied; total=$ExpectedBytes; time=(Get-Date -Format o)} |
        ConvertTo-Json | Set-Content -LiteralPath $progressPath -Encoding UTF8
}
function Assert-CardIdentity {
    $disk = Get-Disk -Number $DiskNumber
    if ($disk.BusType -ne 'USB' -or $disk.Size -ne $ExpectedBytes -or
        $disk.FriendlyName -ne $ExpectedName -or $disk.SerialNumber.Trim() -ne $ExpectedSerial -or
        $disk.IsBoot -or $disk.IsSystem -or $ExpectedBytes -le 0 -or ($ExpectedBytes % 512) -ne 0) {
        throw 'Card identity/size changed, or target is not a non-system USB disk.'
    }
}
try {
    Assert-CardIdentity
    $drive = New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($targetDir))
    if ($drive.AvailableFreeSpace -lt ($ExpectedBytes + 1GB)) { throw 'Insufficient backup space.' }
    $device = '\\.\PhysicalDrive' + $DiskNumber
    $card = [IO.File]::Open($device, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        # Bind this reader to the previously inspected card contents as well as its USB identity.
        $prefix = New-Object byte[] (16MB)
        $prefixRead = 0
        while ($prefixRead -lt $prefix.Length) {
            $count = $card.Read($prefix, $prefixRead, $prefix.Length - $prefixRead)
            if ($count -le 0) { throw 'Short card prefix read.' }
            $prefixRead += $count
        }
        $prefixHasher = [Security.Cryptography.SHA256]::Create()
        try { $prefixHash = [BitConverter]::ToString($prefixHasher.ComputeHash($prefix)).Replace('-', '').ToLowerInvariant() }
        finally { $prefixHasher.Dispose() }
        if ($prefixHash -ne $ExpectedPrefixSha256.ToLowerInvariant()) { throw 'Card contents differ from the earlier inspection.' }
        [void]$card.Seek(0, [IO.SeekOrigin]::Begin)
        $image = [IO.File]::Open($partialPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        $streamHasher = [Security.Cryptography.SHA256]::Create()
        try {
            $buffer = New-Object byte[] (4MB)
            [long]$copied = 0
            [long]$lastReport = 0
            Report-Progress 'copying' 0
            while ($copied -lt $ExpectedBytes) {
                $wanted = [int][Math]::Min([long]$buffer.Length, $ExpectedBytes - $copied)
                $count = $card.Read($buffer, 0, $wanted)
                if ($count -le 0) { throw 'Unexpected end of physical card.' }
                $image.Write($buffer, 0, $count)
                [void]$streamHasher.TransformBlock($buffer, 0, $count, $buffer, 0)
                $copied += $count
                if (($copied - $lastReport) -ge 64MB -or $copied -eq $ExpectedBytes) {
                    Report-Progress 'copying' $copied
                    $lastReport = $copied
                }
            }
            [void]$streamHasher.TransformFinalBlock((New-Object byte[] 0), 0, 0)
            $sourceHash = [BitConverter]::ToString($streamHasher.Hash).Replace('-', '').ToLowerInvariant()
            $image.Flush($true)
        } finally { $image.Dispose(); $streamHasher.Dispose() }
    } finally { $card.Dispose() }
    Assert-CardIdentity
    Report-Progress 'verifying_saved_image' $copied
    if ((Get-Item -LiteralPath $partialPath).Length -ne $ExpectedBytes) { throw 'Backup size mismatch.' }
    $savedHash = (Get-FileHash -LiteralPath $partialPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($savedHash -ne $sourceHash) { throw 'Saved image differs from the card read stream.' }
    Move-Item -LiteralPath $partialPath -Destination $imagePath
    @{
        status='verified'; started=$started.ToString('o'); completed=(Get-Date -Format o);
        device=$device; name=$ExpectedName; serial=$ExpectedSerial; bytes=$ExpectedBytes;
        image=$imagePath; source_read_sha256=$sourceHash; saved_image_sha256=$savedHash;
        prefix_sha256=$prefixHash; physical_access='Read'; physical_card_written=$false;
        script_sha256=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant();
        verification='Exact byte count; SHA256 of the whole card read stream equals separately hashed saved image.'
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $targetDir 'manifest.json') -Encoding UTF8
    Report-Progress 'verified' $copied
} catch {
    @{status='error'; message=$_.Exception.Message; time=(Get-Date -Format o)} |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $targetDir 'error.json') -Encoding UTF8
    exit 1
}
