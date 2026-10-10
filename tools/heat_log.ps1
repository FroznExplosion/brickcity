# Logs the machine's heat and load every few seconds, so a crash that takes the
# whole PC down (no blue screen, no dump: Kernel-Power 41 with bugcheck 0) leaves
# behind what the machine was doing in its last minutes.
#
# One line per sample, appended (and closed) each time so a power cut loses at
# most the last line or two. Files: %LOCALAPPDATA%\brickcity-heat\heat_<date>.csv,
# kept 14 days.
#
# Columns:
#   time        local time
#   temp_c      ACPI thermal zone \_TZ.TZ01 -- on the Legion Go (Ryzen Z1 Extreme)
#               the CPU and the GPU are one chip, so this is both
#   passive_pct 100 = not held back; lower = Windows is throttling for heat
#   throttle    thermal zone throttle reasons (0 = none)
#   cpu_perf    % of base clock the CPU runs at (over 100 = boosting)
#   gpu_3d      GPU 3D engine busy, %
#   gpu_mb      memory the GPU holds in shared (system) RAM, MB
#   free_mb     free system RAM, MB
#   godot       each Godot process: what it runs, and its RAM in MB
#
# Run:  powershell -NoProfile -WindowStyle Hidden -File tools\heat_log.ps1
# Only one copy runs at a time; a second start exits at once.
param([int]$Every = 5)

$mutex = New-Object System.Threading.Mutex($false, 'Local\brickcity_heat_log')
if (-not $mutex.WaitOne(0)) { exit }

$dir = Join-Path $env:LOCALAPPDATA 'brickcity-heat'
New-Item -ItemType Directory -Force $dir | Out-Null
Get-ChildItem $dir -Filter 'heat_*.csv' | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-14) } | Remove-Item -Force

$counters = @(
    '\Thermal Zone Information(*)\High Precision Temperature',
    '\Thermal Zone Information(*)\% Passive Limit',
    '\Thermal Zone Information(*)\Throttle Reasons',
    '\Processor Information(_Total)\% Processor Performance',
    '\GPU Engine(*engtype_3D)\Utilization Percentage',
    '\GPU Adapter Memory(*)\Shared Usage',
    '\Memory\Available MBytes'
)

# What a Godot process runs: the scene or script it was given, plus its user
# args (-- --gate), or "editor".
function Describe-Godot($cmd) {
    if ($cmd -match '--editor|(^|\s)-e(\s|$)') { return 'editor' }
    $what = ''
    if ($cmd -match 'res://\S+') { $what = ($Matches[0] -replace '^res://', '' -replace '"', '') }
    elseif ($cmd -match '--import') { $what = 'import' }
    else { $what = 'game' }
    if ($cmd -match '\s--\s+(.*)$') { $what += ' ' + $Matches[1].Trim() }
    if ($cmd -match '--headless') { $what += ' (headless)' }
    return $what
}

while ($true) {
    $now = Get-Date
    $file = Join-Path $dir ('heat_{0:yyyy-MM-dd}.csv' -f $now)
    if (-not (Test-Path $file)) {
        Add-Content -Path $file -Value 'time,temp_c,passive_pct,throttle,cpu_perf,gpu_3d,gpu_mb,free_mb,godot'
    }
    $temp = ''; $passive = ''; $throttle = ''; $cpu = ''; $gpu = 0.0; $gpuMb = 0.0; $free = ''
    try {
        foreach ($s in (Get-Counter $counters -ErrorAction SilentlyContinue).CounterSamples) {
            $p = $s.Path
            if ($p -like '*high precision temperature') { $temp = '{0:N1}' -f ($s.CookedValue / 10 - 273.15) }
            elseif ($p -like '*% passive limit') { $passive = [int]$s.CookedValue }
            elseif ($p -like '*throttle reasons') { $throttle = [int]$s.CookedValue }
            elseif ($p -like '*% processor performance') { $cpu = [int]$s.CookedValue }
            elseif ($p -like '*utilization percentage') { $gpu += $s.CookedValue }
            elseif ($p -like '*shared usage') { $gpuMb += $s.CookedValue / 1MB }
            elseif ($p -like '*available mbytes') { $free = [int]$s.CookedValue }
        }
    } catch {}
    $godot = @()
    try {
        foreach ($g in Get-CimInstance Win32_Process -Filter "name like 'Godot%'" -ErrorAction SilentlyContinue) {
            $godot += '{0} {1}MB' -f (Describe-Godot $g.CommandLine), [int]($g.WorkingSetSize / 1MB)
        }
    } catch {}
    $line = '{0:HH:mm:ss},{1},{2},{3},{4},{5},{6},{7},"{8}"' -f $now, $temp, $passive, $throttle, $cpu,
        [int][Math]::Min(100, $gpu), [int]$gpuMb, $free, (($godot -join '; ') -replace '"', "'")
    try { Add-Content -Path $file -Value $line } catch {}
    Start-Sleep -Seconds $Every
}
