<#
    FiveM Optimizer
    ----------------
    Safe, reversible Windows tweaks for CPU-bound FiveM (GTA V) sessions.

    - Every registry / power-plan change is backed up before it is applied,
      and "Restore" puts everything back exactly as it was.
    - Nothing is uninstalled, no Windows service is disabled.

    Run through Start-Optimizer.bat (it asks for admin rights automatically).
#>

#Requires -Version 5.1

$ErrorActionPreference = 'Continue'

$DataDir    = Join-Path $env:ProgramData 'FiveMOptimizer'
$BackupFile = Join-Path $DataDir 'backup.json'
$PlanName   = 'FiveM Optimizer'
$FiveMApp   = Join-Path $env:LOCALAPPDATA 'FiveM\FiveM.app'

# FiveM game process is named e.g. FiveM_GTAProcess / FiveM_b3095_GTAProcess
$GamePattern = '^FiveM.*GTAProcess$'

# Apps that are pushed to the efficiency cores / lower priority while playing
$BackgroundApps = @(
    'chrome', 'msedge', 'firefox', 'opera', 'brave', 'Discord', 'Spotify',
    'steamwebhelper', 'EpicGamesLauncher', 'OneDrive', 'Teams', 'ms-teams',
    'Telegram', 'WhatsApp', 'obs64', 'MedalEncoder', 'Medal'
)

# ---------------------------------------------------------------- helpers ---

function Write-Title($text) {
    Write-Host ''
    Write-Host ('=' * 60) -ForegroundColor DarkCyan
    Write-Host "  $text" -ForegroundColor Cyan
    Write-Host ('=' * 60) -ForegroundColor DarkCyan
}

function Write-Ok($text)   { Write-Host "  [OK]   $text" -ForegroundColor Green }
function Write-Warn($text) { Write-Host "  [!]    $text" -ForegroundColor Yellow }
function Write-Bad($text)  { Write-Host "  [X]    $text" -ForegroundColor Red }
function Write-Info($text) { Write-Host "  [i]    $text" -ForegroundColor Gray }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Read-YesNo($question) {
    $answer = Read-Host "  $question [y/N]"
    return $answer -match '^(y|yes)$'
}

# powercfg writes errors to stderr; return everything as one string
function Invoke-PowerCfg {
    $ErrorActionPreference = 'Continue'
    return ((& powercfg.exe @args 2>&1 | ForEach-Object { "$_" }) -join ' ')
}

function Format-Size([double]$bytes) {
    if ($bytes -ge 1GB) { return '{0:N1} GB' -f ($bytes / 1GB) }
    if ($bytes -ge 1MB) { return '{0:N0} MB' -f ($bytes / 1MB) }
    return '{0:N0} KB' -f ($bytes / 1KB)
}

function Get-FolderSize($path) {
    if (-not (Test-Path $path)) { return 0 }
    $sum = (Get-ChildItem $path -Recurse -Force -File -ErrorAction SilentlyContinue |
            Measure-Object Length -Sum).Sum
    if ($sum) { return $sum } else { return 0 }
}

# --------------------------------------------------- hybrid CPU detection ---
# Intel 12th-14th gen have Performance (P) and Efficient (E) cores. FiveM runs
# best when its threads stay on the P-cores. GetSystemCpuSetInformation reports
# an EfficiencyClass per logical processor: the highest class = P-cores.

Add-Type -ErrorAction SilentlyContinue -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class CpuSets {
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetSystemCpuSetInformation(IntPtr info, uint length,
        out uint returned, IntPtr process, uint flags);

    // Returns one int[2] per logical processor: { logicalIndex, efficiencyClass }
    public static List<int[]> Get() {
        var result = new List<int[]>();
        uint len;
        GetSystemCpuSetInformation(IntPtr.Zero, 0, out len, IntPtr.Zero, 0);
        if (len == 0) return result;
        IntPtr buf = Marshal.AllocHGlobal((int)len);
        try {
            if (!GetSystemCpuSetInformation(buf, len, out len, IntPtr.Zero, 0))
                return result;
            int offset = 0;
            while (offset < len) {
                int size = Marshal.ReadInt32(buf, offset);
                int type = Marshal.ReadInt32(buf, offset + 4);
                if (size <= 0) break;
                if (type == 0) {
                    int group   = Marshal.ReadInt16(buf, offset + 12);
                    int logical = Marshal.ReadByte(buf, offset + 14);
                    int eff     = Marshal.ReadByte(buf, offset + 18);
                    if (group == 0) result.Add(new int[] { logical, eff });
                }
                offset += size;
            }
        } finally {
            Marshal.FreeHGlobal(buf);
        }
        return result;
    }
}
'@

function Get-CoreMasks {
    $all = [int64]0; $p = [int64]0; $e = [int64]0
    $sets = @()
    try { $sets = [CpuSets]::Get() } catch { }
    if ($sets.Count -eq 0) {
        $n = [Math]::Min([Environment]::ProcessorCount, 63)
        for ($i = 0; $i -lt $n; $i++) { $all = $all -bor ([int64]1 -shl $i) }
        return @{ All = $all; P = $all; E = [int64]0; Hybrid = $false; PCount = $n; ECount = 0 }
    }
    $maxEff = ($sets | ForEach-Object { $_[1] } | Measure-Object -Maximum).Maximum
    foreach ($s in $sets) {
        if ($s[0] -gt 62) { continue }
        $bit = [int64]1 -shl $s[0]
        $all = $all -bor $bit
        if ($s[1] -eq $maxEff) { $p = $p -bor $bit } else { $e = $e -bor $bit }
    }
    $pCount = @($sets | Where-Object { $_[1] -eq $maxEff }).Count
    return @{ All = $all; P = $p; E = $e; Hybrid = ($e -ne 0)
              PCount = $pCount; ECount = $sets.Count - $pCount }
}

# ----------------------------------------------------------------- backup ---

function Get-Backup {
    if (Test-Path $BackupFile) {
        return Get-Content $BackupFile -Raw -ErrorAction Stop | ConvertFrom-Json
    }
    return $null
}

function Get-RegState($path, $name) {
    $state = [ordered]@{ Path = $path; Name = $name; Exists = $false; Value = $null; Kind = $null }
    if (Test-Path $path) {
        $key = Get-Item $path
        if ($key.GetValueNames() -contains $name) {
            $state.Exists = $true
            $state.Value  = $key.GetValue($name)
            $state.Kind   = $key.GetValueKind($name).ToString()
        }
    }
    return $state
}

# Registry tweaks: Path, Name, Value, Type, Description
$Tweaks = @(
    @('HKCU:\System\GameConfigStore', 'GameDVR_Enabled', 0, 'DWord',
      'Disable Xbox Game DVR background recording'),
    @('HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR', 'AppCaptureEnabled', 0, 'DWord',
      'Disable Game Bar app capture'),
    @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR', 'AllowGameDVR', 0, 'DWord',
      'Block Game DVR by policy'),
    @('HKCU:\Software\Microsoft\GameBar', 'AutoGameModeEnabled', 1, 'DWord',
      'Enable Windows Game Mode'),
    @('HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications', 'GlobalUserDisabled', 1, 'DWord',
      'Stop Store apps running in the background'),
    @('HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile', 'SystemResponsiveness', 10, 'DWord',
      'Give games more multimedia scheduler time'),
    @('HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games', 'GPU Priority', 8, 'DWord',
      'Games task: GPU priority 8'),
    @('HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games', 'Priority', 6, 'DWord',
      'Games task: CPU priority 6'),
    @('HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games', 'Scheduling Category', 'High', 'String',
      'Games task: scheduling category High'),
    @('HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers', 'HwSchMode', 2, 'DWord',
      'Hardware-accelerated GPU scheduling (needs restart)')
)

# --------------------------------------------------------------- diagnose ---

function Invoke-Diagnose {
    Write-Title 'System diagnosis'

    $os = Get-CimInstance Win32_OperatingSystem
    $build = [int]$os.BuildNumber
    $isWin11 = $build -ge 22000
    Write-Info ("Windows : {0} (build {1})" -f $os.Caption, $build)

    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $masks = Get-CoreMasks
    Write-Info ("CPU     : {0}" -f $cpu.Name.Trim())
    Write-Info ("Cores   : {0} cores / {1} threads" -f $cpu.NumberOfCores, $cpu.NumberOfLogicalProcessors)
    if ($masks.Hybrid) {
        Write-Info ("Hybrid  : {0} P-core threads + {1} E-cores" -f $masks.PCount, $masks.ECount)
        if (-not $isWin11) {
            Write-Bad 'Windows 10 on a hybrid Intel CPU: Win10 often puts game threads on E-cores.'
            Write-Bad 'Upgrading to Windows 11 (or using the Game Booster P-core option) fixes stutter.'
        } else {
            Write-Ok 'Windows 11 understands P/E cores (Thread Director).'
        }
    }

    $bios = Get-CimInstance Win32_BIOS
    Write-Info ("BIOS    : {0} ({1:yyyy-MM-dd})" -f $bios.SMBIOSBIOSVersion, $bios.ReleaseDate)
    if ($cpu.Name -match '1[34]\d{2}') {
        Write-Warn '13th/14th gen Intel: install the latest motherboard BIOS (Intel microcode fix).'
    }

    # RAM
    $mods = @(Get-CimInstance Win32_PhysicalMemory)
    $totalGB = ($mods | Measure-Object Capacity -Sum).Sum / 1GB
    $usedPct = [Math]::Round((1 - $os.FreePhysicalMemory / $os.TotalVisibleMemorySize) * 100)
    Write-Info ("RAM     : {0:N0} GB in {1} stick(s), {2}% in use right now" -f $totalGB, $mods.Count, $usedPct)
    foreach ($m in $mods) {
        $type = switch ($m.SMBIOSMemoryType) { 26 { 'DDR4' } 34 { 'DDR5' } default { 'DDR' } }
        Write-Info ("          {0} {1:N0} GB  rated {2} MT/s, running {3} MT/s  [{4}]" -f `
            $type, ($m.Capacity / 1GB), $m.Speed, $m.ConfiguredClockSpeed, $m.DeviceLocator)
    }
    if ($mods.Count -eq 1) {
        Write-Bad 'Only ONE RAM stick = single channel. FiveM loses a LOT of FPS. Use 2 matching sticks.'
    }
    $slowest = ($mods | Measure-Object ConfiguredClockSpeed -Minimum).Minimum
    $isDdr5 = @($mods | Where-Object { $_.SMBIOSMemoryType -eq 34 }).Count -gt 0
    if (($isDdr5 -and $slowest -le 4800) -or (-not $isDdr5 -and $slowest -le 2666)) {
        Write-Warn 'RAM runs at base speed. Enable XMP / EXPO in BIOS for free CPU-side FPS.'
    }
    if ($totalGB -lt 20) {
        Write-Warn '16 GB is the bare minimum for FiveM. Close browsers/Discord while playing or go 32 GB.'
    }
    if ($usedPct -ge 75) {
        Write-Bad "RAM is already $usedPct% used before/while playing - Windows will start paging."
    }

    # Page file
    $pf = @(Get-CimInstance Win32_PageFileUsage)
    if ($pf.Count -eq 0) {
        Write-Bad 'No page file! FiveM crashes / stutters without one. Set it to "System managed".'
    } else {
        foreach ($p in $pf) { Write-Ok ("Page file: {0} ({1} MB)" -f $p.Name, $p.AllocatedBaseSize) }
    }

    # GPU
    foreach ($g in Get-CimInstance Win32_VideoController) {
        Write-Info ("GPU     : {0}  driver {1} ({2:yyyy-MM-dd})" -f $g.Name, $g.DriverVersion, $g.DriverDate)
    }

    # Power plan
    $active = Invoke-PowerCfg /getactivescheme
    Write-Info ("Power   : {0}" -f ($active -replace '^.*\(|\)\s*$', ''))
    if ($active -notmatch 'e9a42b02|8c5e7fda' -and $active -notmatch [regex]::Escape($PlanName)) {
        Write-Warn 'Not on a high performance power plan (option 2 fixes this).'
    }

    # Game DVR
    $dvr = Get-RegState 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled'
    if (-not $dvr.Exists -or $dvr.Value -ne 0) {
        Write-Warn 'Xbox Game DVR background recording is ON (costs FPS, option 2 fixes this).'
    } else {
        Write-Ok 'Game DVR is off.'
    }

    # Disk
    $c = Get-PSDrive C -ErrorAction SilentlyContinue
    if ($c) {
        $freeGB = $c.Free / 1GB
        if ($freeGB -lt 30) { Write-Warn ("Only {0:N0} GB free on C: - keep at least 30 GB free." -f $freeGB) }
        else { Write-Ok ("{0:N0} GB free on C:" -f $freeGB) }
    }
    if (Test-Path $FiveMApp) {
        Write-Info ("FiveM   : {0}" -f $FiveMApp)
        Write-Info ("          cache size {0}" -f (Format-Size (
            (Get-FolderSize "$FiveMApp\data\cache") +
            (Get-FolderSize "$FiveMApp\data\server-cache") +
            (Get-FolderSize "$FiveMApp\data\server-cache-priv"))))
    }

    # Startup apps
    $startup = @(Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue)
    Write-Info ("Startup : {0} apps start with Windows (Task Manager > Startup apps)" -f $startup.Count)

    # Heavy processes
    Write-Host ''
    Write-Host '  Top 10 processes by RAM:' -ForegroundColor Cyan
    Get-Process | Group-Object ProcessName | ForEach-Object {
        [pscustomobject]@{
            Name = $_.Name
            RAM  = ($_.Group | Measure-Object WorkingSet64 -Sum).Sum
            CPU  = ($_.Group | Measure-Object CPU -Sum).Sum
        }
    } | Sort-Object RAM -Descending | Select-Object -First 10 | ForEach-Object {
        Write-Host ("     {0,-28} {1,10}" -f $_.Name, (Format-Size $_.RAM))
    }
}

# ------------------------------------------------------------------ apply ---

function Invoke-Optimize {
    Write-Title 'Apply optimizations'

    $backup = Get-Backup
    $firstRun = $null -eq $backup
    if ($firstRun) {
        $backup = [ordered]@{
            Created   = (Get-Date).ToString('s')
            PowerPlan = $null
            OurPlan   = $null
            Registry  = @()
        }
        $current = Invoke-PowerCfg /getactivescheme
        if ($current -match '([0-9a-fA-F-]{36})') { $backup.PowerPlan = $Matches[1] }
        foreach ($t in $Tweaks) { $backup.Registry += Get-RegState $t[0] $t[1] }
    } else {
        Write-Info "Backup from $($backup.Created) kept (original settings stay restorable)."
    }

    # Power plan: duplicate Ultimate Performance (fallback High Performance)
    $ourPlan = $backup.OurPlan
    $planExists = $ourPlan -and (Invoke-PowerCfg /list) -match $ourPlan
    if (-not $planExists) {
        $out = Invoke-PowerCfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61
        if ($out -notmatch '([0-9a-fA-F-]{36})') {
            $out = Invoke-PowerCfg -duplicatescheme 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c
        }
        if ($out -match '([0-9a-fA-F-]{36})') {
            $ourPlan = $Matches[1]
            Invoke-PowerCfg -changename $ourPlan $PlanName 'High performance plan for FiveM' | Out-Null
        } else {
            $ourPlan = $null
            Write-Bad "Could not create a power plan: $out"
        }
    }
    if ($ourPlan) {
        # Keep all cores unparked and at full minimum clock
        Invoke-PowerCfg -setacvalueindex $ourPlan SUB_PROCESSOR CPMINCORES 100 | Out-Null
        Invoke-PowerCfg -setacvalueindex $ourPlan SUB_PROCESSOR PROCTHROTTLEMIN 100 | Out-Null
        Invoke-PowerCfg -setactive $ourPlan | Out-Null
        Write-Ok "Power plan '$PlanName' active (cores unparked)"
    }
    $backup.OurPlan = $ourPlan

    # Save the backup BEFORE touching the registry
    New-Item -ItemType Directory -Path $DataDir -Force -ErrorAction Stop | Out-Null
    $backup | ConvertTo-Json -Depth 5 | Set-Content $BackupFile -Encoding UTF8 -ErrorAction Stop

    foreach ($t in $Tweaks) {
        try {
            if (-not (Test-Path $t[0])) { New-Item -Path $t[0] -Force -ErrorAction Stop | Out-Null }
            New-ItemProperty -Path $t[0] -Name $t[1] -Value $t[2] -PropertyType $t[3] -Force -ErrorAction Stop | Out-Null
            Write-Ok $t[4]
        } catch {
            Write-Bad "$($t[4]): $($_.Exception.Message)"
        }
    }

    Write-Host ''
    Write-Ok "Backup saved to $BackupFile"
    Write-Warn 'Restart Windows once so GPU scheduling takes effect.'
}

# ---------------------------------------------------------------- restore ---

function Invoke-Restore {
    Write-Title 'Restore original settings'
    $backup = Get-Backup
    if (-not $backup) { Write-Warn 'No backup found - nothing to restore.'; return }

    foreach ($r in $backup.Registry) {
        try {
            if ($r.Exists) {
                if (-not (Test-Path $r.Path)) { New-Item -Path $r.Path -Force -ErrorAction Stop | Out-Null }
                New-ItemProperty -Path $r.Path -Name $r.Name -Value $r.Value -PropertyType $r.Kind -Force -ErrorAction Stop | Out-Null
            } elseif (Test-Path $r.Path) {
                Remove-ItemProperty -Path $r.Path -Name $r.Name -ErrorAction SilentlyContinue
            }
            Write-Ok "Restored $($r.Name)"
        } catch {
            Write-Bad "$($r.Name): $($_.Exception.Message)"
        }
    }

    if ($backup.PowerPlan) {
        Invoke-PowerCfg -setactive $backup.PowerPlan | Out-Null
        Write-Ok 'Original power plan re-activated'
    }
    if ($backup.OurPlan) {
        Invoke-PowerCfg -delete $backup.OurPlan | Out-Null
        Write-Ok "Removed '$PlanName' power plan"
    }

    Remove-Item $BackupFile -Force
    Write-Warn 'Restart Windows to finish restoring.'
}

# ------------------------------------------------------------------ clean ---

function Invoke-Clean {
    Write-Title 'Clean FiveM cache and temp files'

    if (Get-Process | Where-Object { $_.ProcessName -match '^FiveM' }) {
        Write-Bad 'Close FiveM first.'
        return
    }

    $targets = @(
        "$FiveMApp\data\cache",
        "$FiveMApp\data\server-cache",
        "$FiveMApp\data\server-cache-priv",
        "$FiveMApp\crashes",
        "$FiveMApp\logs",
        $env:TEMP,
        "$env:SystemRoot\Temp"
    )

    $freed = 0
    foreach ($path in $targets) {
        if (-not (Test-Path $path)) { continue }
        $before = Get-FolderSize $path
        Get-ChildItem $path -Force -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        $gone = $before - (Get-FolderSize $path)
        $freed += $gone
        Write-Ok ("{0,-55} {1}" -f $path, (Format-Size $gone))
    }
    Write-Host ''
    Write-Ok ("Freed {0}. First join on each server will re-download assets." -f (Format-Size $freed))
}

# ---------------------------------------------------------------- free RAM ---

function Invoke-FreeRam {
    Write-Title 'Close heavy apps before playing'

    $protected = 'System|Idle|Registry|smss|csrss|wininit|winlogon|services|lsass|svchost|' +
                 'dwm|explorer|fontdrvhost|Memory Compression|MsMpEng|audiodg|powershell|' +
                 'conhost|WindowsTerminal|nvcontainer|NVDisplay.Container|ctfmon|sihost|' +
                 'SearchHost|StartMenuExperienceHost|ShellExperienceHost|RuntimeBroker|FiveM'

    $list = @(Get-Process | Where-Object { $_.ProcessName -notmatch "^($protected)" } |
        Group-Object ProcessName | ForEach-Object {
            [pscustomobject]@{
                Name = $_.Name
                RAM  = ($_.Group | Measure-Object WorkingSet64 -Sum).Sum
            }
        } | Sort-Object RAM -Descending | Select-Object -First 15)

    for ($i = 0; $i -lt $list.Count; $i++) {
        Write-Host ("  {0,2}) {1,-30} {2,10}" -f ($i + 1), $list[$i].Name, (Format-Size $list[$i].RAM))
    }
    Write-Host ''
    $pick = Read-Host '  Numbers to close (e.g. 1,3,4) or Enter to skip'
    foreach ($n in ($pick -split '[,\s]+' | Where-Object { $_ -match '^\d+$' })) {
        $idx = [int]$n - 1
        if ($idx -lt 0 -or $idx -ge $list.Count) { continue }
        $name = $list[$idx].Name
        Get-Process -Name $name -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Write-Ok "Closed $name ($(Format-Size $list[$idx].RAM))"
    }
}

# ----------------------------------------------------------- game booster ---

function Invoke-Booster {
    Write-Title 'Game Booster (keep this window open while playing)'

    $masks = Get-CoreMasks
    $pinGame = $false
    $pushBg  = $false
    if ($masks.Hybrid) {
        Write-Info ("Hybrid CPU: {0} P-core threads, {1} E-cores." -f $masks.PCount, $masks.ECount)
        $pinGame = Read-YesNo 'Lock FiveM to the P-cores (recommended on Windows 10)?'
        $pushBg  = Read-YesNo 'Move Discord/browsers/etc. to the E-cores?'
    }
    Write-Host ''
    Write-Info 'Waiting for FiveM... press Q to stop and undo.'

    $boosted = @{}
    $moved   = @{}
    try {
        while ($true) {
            foreach ($proc in Get-Process | Where-Object { $_.ProcessName -match $GamePattern }) {
                if ($boosted.ContainsKey($proc.Id)) { continue }
                try {
                    $proc.PriorityClass = [Diagnostics.ProcessPriorityClass]::High
                    if ($pinGame) { $proc.ProcessorAffinity = [IntPtr]$masks.P }
                    $boosted[$proc.Id] = $proc
                    $where = if ($pinGame) { ', P-cores only' } else { '' }
                    Write-Ok ("{0} (PID {1}) -> High priority{2}" -f $proc.ProcessName, $proc.Id, $where)
                } catch {
                    Write-Bad "Could not boost $($proc.ProcessName): $($_.Exception.Message)"
                    $boosted[$proc.Id] = $null
                }
            }

            if ($boosted.Count -gt 0) {
                foreach ($proc in Get-Process -Name $BackgroundApps -ErrorAction SilentlyContinue) {
                    if ($moved.ContainsKey($proc.Id)) { continue }
                    try {
                        $proc.PriorityClass = [Diagnostics.ProcessPriorityClass]::BelowNormal
                        if ($pushBg) { $proc.ProcessorAffinity = [IntPtr]$masks.E }
                        $moved[$proc.Id] = $proc
                    } catch {
                        $moved[$proc.Id] = $null
                    }
                }
            }

            # Forget processes that exited
            foreach ($id in @($boosted.Keys)) {
                if (-not (Get-Process -Id $id -ErrorAction SilentlyContinue)) {
                    $boosted.Remove($id)
                    Write-Info "Game process $id closed. Waiting for FiveM..."
                }
            }

            for ($i = 0; $i -lt 30; $i++) {
                if ([Console]::KeyAvailable -and [Console]::ReadKey($true).Key -eq 'Q') { return }
                Start-Sleep -Milliseconds 100
            }
        }
    } finally {
        foreach ($proc in $moved.Values) {
            if (-not $proc -or $proc.HasExited) { continue }
            try {
                $proc.PriorityClass = [Diagnostics.ProcessPriorityClass]::Normal
                $proc.ProcessorAffinity = [IntPtr]$masks.All
            } catch { }
        }
        if ($moved.Count -gt 0) { Write-Ok 'Background apps restored to normal.' }
        Write-Info 'Booster stopped.'
    }
}

# ------------------------------------------------------------------- menu ---

if (-not (Test-Admin)) {
    Write-Bad 'Run this as Administrator (use Start-Optimizer.bat).'
    Read-Host '  Press Enter to exit'
    exit 1
}

while ($true) {
    Write-Title 'FiveM Optimizer'
    Write-Host '   1) Diagnose my PC (start here)'
    Write-Host '   2) Apply optimizations (power plan, Game DVR off, scheduler...)'
    Write-Host '   3) Clean FiveM cache + temp files'
    Write-Host '   4) Close heavy apps (free RAM)'
    Write-Host '   5) Game Booster - run while playing'
    Write-Host '   6) Restore original Windows settings'
    Write-Host '   0) Exit'
    $choice = Read-Host "`n  Choose"
    try {
        switch ($choice) {
            '1' { Invoke-Diagnose }
            '2' { Invoke-Optimize }
            '3' { Invoke-Clean }
            '4' { Invoke-FreeRam }
            '5' { Invoke-Booster }
            '6' { Invoke-Restore }
            '0' { exit 0 }
            default { Write-Warn 'Unknown option.' }
        }
    } catch {
        Write-Bad $_.Exception.Message
    }
    Read-Host "`n  Press Enter to go back to the menu"
}
