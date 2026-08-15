[CmdletBinding()]
param(
    [ValidateRange(1, 100)]
    [int]$StopAdmissionPercent = 88,
    [ValidateRange(1, 100)]
    [int]$CriticalPercent = 90,
    [ValidateRange(0, 1048576)]
    [int]$ReserveMB = 4096
)

$ErrorActionPreference = "Stop"

$os = Get-CimInstance Win32_OperatingSystem
$totalMb = [math]::Round(([double]$os.TotalVisibleMemorySize / 1024), 2)
$freeMb = [math]::Round(([double]$os.FreePhysicalMemory / 1024), 2)
$usedMb = [math]::Round(($totalMb - $freeMb), 2)
$usedPercent = if ($totalMb -gt 0) { [math]::Round(($usedMb / $totalMb) * 100, 2) } else { 100 }
$allowed = ($usedPercent -lt $StopAdmissionPercent -and $freeMb -gt $ReserveMB)
$critical = ($usedPercent -ge $CriticalPercent)

[pscustomobject]@{
    host_used_percent = $usedPercent
    total_mb = $totalMb
    used_mb = $usedMb
    available_mb = $freeMb
    reserve_mb = $ReserveMB
    admission_allowed = $allowed
    critical = $critical
    reason = if ($allowed) { $null } elseif ($critical) { "host-memory-critical" } else { "host-memory-stop-admission" }
    measured_at = (Get-Date).ToUniversalTime().ToString("o")
} | ConvertTo-Json -Compress

