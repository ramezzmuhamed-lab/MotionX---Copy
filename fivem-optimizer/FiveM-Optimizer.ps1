<#
    FiveM Optimizer
    ----------------
    Windows tuning for CPU-bound FiveM (GTA V) - the useful parts of a
    "lite Windows" build, without reinstalling and without breaking anything.

    - Every registry value, service, scheduled task, power plan and settings
      file is backed up before it is changed; "Restore" puts it all back.
    - Nothing is uninstalled or deleted from Windows.

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
    'chrome', 'msedge', 'msedgewebview2', 'firefox', 'opera', 'brave', 'Discord',
    'Spotify', 'steamwebhelper', 'EpicGamesLauncher', 'OneDrive', 'Teams', 'ms-teams',
    'Telegram', 'WhatsApp', 'obs64', 'MedalEncoder', 'Medal', 'Widgets', 'PhoneExperienceHost'
)

# GTA V graphics settings used by FiveM
$GtaSettingsFiles = @(
    (Join-Path $env:APPDATA 'CitizenFX\gta5_settings.xml'),
    (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Rockstar Games\GTA V\settings.xml')
)

# ---------------------------------------------------------------- helpers ---

function Write-Title($text) {
    Write-Host ''
    Write-Host ('=' * 64) -ForegroundColor DarkCyan
    Write-Host "  $text" -ForegroundColor Cyan
    Write-Host ('=' * 64) -ForegroundColor DarkCyan
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

function Test-FiveMRunning {
    return [bool](Get-Process | Where-Object { $_.ProcessName -match '^FiveM' })
}

# ---------------------------------------------------------- native helpers ---
# CpuSets : which logical processors are P-cores / E-cores (Intel 12th-14th gen)
# Native  : timer resolution, standby-list purge, working-set trim

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

public static class Native {
    [DllImport("ntdll.dll")]
    static extern int NtSetTimerResolution(uint desired,
        [MarshalAs(UnmanagedType.U1)] bool set, out uint current);
    [DllImport("ntdll.dll")]
    static extern int NtQueryTimerResolution(out uint coarsest, out uint finest, out uint current);
    [DllImport("ntdll.dll")]
    static extern int RtlAdjustPrivilege(int privilege, [MarshalAs(UnmanagedType.U1)] bool enable,
        [MarshalAs(UnmanagedType.U1)] bool currentThread, [MarshalAs(UnmanagedType.U1)] out bool wasEnabled);
    [DllImport("ntdll.dll")]
    static extern int NtSetSystemInformation(int infoClass, ref int info, int length);
    [DllImport("psapi.dll")]
    static extern bool EmptyWorkingSet(IntPtr process);

    // Request a 0.5 ms system timer (in 100 ns units). Returns the active resolution.
    public static uint SetTimer(bool enable) {
        uint coarsest, finest, current;
        NtQueryTimerResolution(out coarsest, out finest, out current);
        NtSetTimerResolution(Math.Max(finest, 5000u), enable, out current);
        return current;
    }

    // Same as ISLC / RAMMap "Empty Standby List"
    public static bool PurgeStandbyList() {
        bool was;
        RtlAdjustPrivilege(13, true, false, out was);   // SeProfileSingleProcessPrivilege
        int command = 4;                                  // MemoryPurgeStandbyList
        return NtSetSystemInformation(80, ref command, 4) == 0;
    }

    public static bool Trim(IntPtr process) {
        return EmptyWorkingSet(process);
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
# One backup file holds the ORIGINAL state of everything this tool touched.
# An item is recorded only the first time it is changed, so running the
# optimizer twice never overwrites the original values.

function Get-Backup {
    $b = $null
    if (Test-Path $BackupFile) {
        try { $b = Get-Content $BackupFile -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $b = $null }
    }
    if (-not $b) {
        $b = [pscustomobject]@{ Created = (Get-Date).ToString('s') }
    }
    foreach ($prop in 'PowerPlan', 'OurPlan', 'Registry', 'Tasks', 'Files', 'Exclusions') {
        if (-not ($b.PSObject.Properties.Name -contains $prop)) {
            $b | Add-Member -NotePropertyName $prop -NotePropertyValue $null
        }
    }
    foreach ($prop in 'Registry', 'Tasks', 'Files', 'Exclusions') {
        $b.$prop = @($b.$prop | Where-Object { $_ })
    }
    return $b
}

function Save-Backup {
    New-Item -ItemType Directory -Path $DataDir -Force -ErrorAction Stop | Out-Null
    $script:Backup | ConvertTo-Json -Depth 6 | Set-Content $BackupFile -Encoding UTF8 -ErrorAction Stop
}

function Get-RegState($path, $name) {
    $state = [ordered]@{ Path = $path; Name = $name; Exists = $false; Value = $null; Kind = $null }
    if (Test-Path $path) {
        $key = Get-Item $path
        if ($key.GetValueNames() -contains $name) {
            $state.Exists = $true
            $state.Value  = $key.GetValue($name, $null, 'DoNotExpandEnvironmentNames')
            $state.Kind   = $key.GetValueKind($name).ToString()
        }
    }
    return [pscustomobject]$state
}

function Backup-Reg($path, $name) {
    $known = $script:Backup.Registry | Where-Object { $_.Path -eq $path -and $_.Name -eq $name }
    if (-not $known) {
        $script:Backup.Registry = @($script:Backup.Registry) + (Get-RegState $path $name)
        Save-Backup
    }
}

function Set-Reg($path, $name, $value, $type) {
    Backup-Reg $path $name
    if (-not (Test-Path $path)) { New-Item -Path $path -Force -ErrorAction Stop | Out-Null }
    New-ItemProperty -Path $path -Name $name -Value $value -PropertyType $type -Force -ErrorAction Stop | Out-Null
}

function Remove-Reg($path, $name) {
    Backup-Reg $path $name
    Remove-ItemProperty -Path $path -Name $name -ErrorAction Stop
}

function Backup-File($path) {
    $known = $script:Backup.Files | Where-Object { $_.Original -eq $path }
    if ($known) { return }
    $copy = $null
    if (Test-Path $path) {
        $copy = Join-Path $DataDir ('{0}-{1}' -f [guid]::NewGuid().ToString('N').Substring(0, 8), (Split-Path $path -Leaf))
        New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
        Copy-Item $path $copy -Force -ErrorAction Stop
    }
    $script:Backup.Files = @($script:Backup.Files) + [pscustomobject]@{ Original = $path; Copy = $copy }
    Save-Backup
}

# ------------------------------------------------------------- tweak lists ---

# Registry tweaks: Path, Name, Value, Type, Description
$Tweaks = @(
    @('HKCU:\System\GameConfigStore', 'GameDVR_Enabled', 0, 'DWord',
      'Xbox Game DVR background recording off'),
    @('HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR', 'AppCaptureEnabled', 0, 'DWord',
      'Game Bar capture off'),
    @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR', 'AllowGameDVR', 0, 'DWord',
      'Game DVR blocked by policy'),
    @('HKCU:\Software\Microsoft\GameBar', 'AutoGameModeEnabled', 1, 'DWord',
      'Windows Game Mode on'),
    @('HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications', 'GlobalUserDisabled', 1, 'DWord',
      'Store apps can no longer run in the background'),
    @('HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile', 'SystemResponsiveness', 10, 'DWord',
      'Multimedia scheduler favours games'),
    @('HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games', 'GPU Priority', 8, 'DWord',
      'Games task: GPU priority 8'),
    @('HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games', 'Priority', 6, 'DWord',
      'Games task: CPU priority 6'),
    @('HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games', 'Scheduling Category', 'High', 'String',
      'Games task: scheduling category High'),
    @('HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers', 'HwSchMode', 2, 'DWord',
      'Hardware-accelerated GPU scheduling on'),
    @('HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl', 'Win32PrioritySeparation', 38, 'DWord',
      'CPU time favours the foreground game'),
    @('HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling', 'PowerThrottlingOff', 1, 'DWord',
      'Power throttling off (no forced E-core / low clock for apps)'),
    @('HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel', 'GlobalTimerResolutionRequests', 1, 'DWord',
      'Allow the booster 0.5 ms timer to apply system-wide (Win11)'),
    @('HKLM:\SOFTWARE\Policies\Microsoft\Dsh', 'AllowNewsAndInterests', 0, 'DWord',
      'Widgets off (saves ~300 MB RAM)'),
    @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize', 'EnableTransparency', 0, 'DWord',
      'Transparency effects off'),
    @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced', 'TaskbarAnimations', 0, 'DWord',
      'Taskbar animations off'),
    @('HKCU:\Control Panel\Desktop\WindowMetrics', 'MinAnimate', '0', 'String',
      'Window minimize/maximize animations off')
)

# Services a lite Windows build removes - here they are only disabled (Start = 4)
$Services = [ordered]@{
    'DiagTrack'        = 'Telemetry (Connected User Experiences)'
    'dmwappushservice' = 'Telemetry WAP push'
    'SysMain'          = 'SysMain / Superfetch (disk + CPU spikes)'
    'WSearch'          = 'Windows Search indexer (CPU spikes; finding apps in Start still works)'
    'MapsBroker'       = 'Downloaded maps manager'
    'lfsvc'            = 'Geolocation'
    'RetailDemo'       = 'Retail demo'
    'Fax'              = 'Fax'
    'WerSvc'           = 'Windows Error Reporting'
    'TrkWks'           = 'Distributed link tracking'
    'WMPNetworkSvc'    = 'Media Player network sharing'
    'wisvc'            = 'Windows Insider'
    'PcaSvc'           = 'Program Compatibility Assistant'
}
$XboxServices = [ordered]@{
    'XblAuthManager' = 'Xbox Live auth'
    'XblGameSave'    = 'Xbox Live game save'
    'XboxNetApiSvc'  = 'Xbox Live networking'
}

# Telemetry scheduled tasks
$TelemetryTasks = @(
    @('\Microsoft\Windows\Application Experience\', 'Microsoft Compatibility Appraiser'),
    @('\Microsoft\Windows\Application Experience\', 'ProgramDataUpdater'),
    @('\Microsoft\Windows\Application Experience\', 'StartupAppTask'),
    @('\Microsoft\Windows\Customer Experience Improvement Program\', 'Consolidator'),
    @('\Microsoft\Windows\Customer Experience Improvement Program\', 'UsbCeip'),
    @('\Microsoft\Windows\DiskDiagnostic\', 'Microsoft-Windows-DiskDiagnosticDataCollector'),
    @('\Microsoft\Windows\Feedback\Siuf\', 'DmClient'),
    @('\Microsoft\Windows\Feedback\Siuf\', 'DmClientOnScenarioDownload'),
    @('\Microsoft\Windows\Windows Error Reporting\', 'QueueReporting')
)

# GTA V settings that cost CPU time, not GPU time (the GPU is idle anyway).
# Balanced keeps the game looking normal; MaxFps strips everything that adds
# CPU draw calls / simulation (population, distance, shadows, reflections).
$BalancedPreset = [ordered]@{
    'CityDensity'              = '0.400000'
    'PedVarietyMultiplier'     = '0.500000'
    'VehicleVarietyMultiplier' = '0.500000'
    'LodScale'                 = '0.700000'
    'MaxLodScale'              = '0.000000'
    'Shadow_Distance'          = '1.000000'
    'Shadow_LongShadows'       = 'false'
    'UltraShadows_Enabled'     = 'false'
    'HdStreamingInFlight'      = 'false'
    'GrassQuality'             = '0'
}

$MaxFpsPreset = [ordered]@{
    'CityDensity'              = '0.000000'
    'PedVarietyMultiplier'     = '0.000000'
    'VehicleVarietyMultiplier' = '0.000000'
    'LodScale'                 = '0.000000'
    'MaxLodScale'              = '0.000000'
    'PedLodBias'               = '0.000000'
    'VehicleLodBias'           = '0.000000'
    'Shadow_Distance'          = '1.000000'
    'Shadow_LongShadows'       = 'false'
    'UltraShadows_Enabled'     = 'false'
    'Shadow_ParticleShadows'   = 'false'
    'HdStreamingInFlight'      = 'false'
    'GrassQuality'             = '0'
    'ShadowQuality'            = '1'
    'ReflectionQuality'        = '0'
    'ReflectionMSAA'           = '0'
    'ParticleQuality'          = '0'
    'WaterQuality'             = '0'
    'Tessellation'             = '0'
    'Lighting_FogVolumes'      = 'false'
    'MotionBlurStrength'       = '0.000000'
}

# ---------------------------------------------------------------- diagnose ---

function Invoke-Diagnose {
    Write-Title 'System diagnosis'

    $os = Get-CimInstance Win32_OperatingSystem
    $build = [int]$os.BuildNumber
    $isWin11 = $build -ge 22000
    Write-Info ("Windows : {0} (build {1})" -f $os.Caption, $build)

    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $masks = Get-CoreMasks
    Write-Info ("CPU     : {0}  ({1} cores / {2} threads)" -f $cpu.Name.Trim(), $cpu.NumberOfCores, $cpu.NumberOfLogicalProcessors)
    if ($masks.Hybrid) {
        Write-Info ("          {0} P-core threads + {1} E-cores" -f $masks.PCount, $masks.ECount)
        if (-not $isWin11) {
            Write-Bad 'Windows 10 on a hybrid Intel CPU puts game threads on E-cores. Use Windows 11.'
        }
    }

    $bios = Get-CimInstance Win32_BIOS
    Write-Info ("BIOS    : {0} ({1:yyyy-MM-dd})" -f $bios.SMBIOSBIOSVersion, $bios.ReleaseDate)
    if ($cpu.Name -match '1[34]\d{2}' -and $bios.ReleaseDate -lt (Get-Date '2024-09-01')) {
        Write-Warn 'BIOS is older than Sept 2024 - update it (Intel 13th/14th gen microcode fix).'
    }

    # Memory Integrity / VBS - the single biggest hidden FPS cost on Windows 11
    $dg = Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard -ErrorAction SilentlyContinue
    if ($dg -and $dg.VirtualizationBasedSecurityStatus -eq 2) {
        if (@($dg.SecurityServicesRunning) -contains 2) {
            Write-Bad 'Memory Integrity (HVCI) is ON - typically costs 5-15% FPS in CPU-bound games.'
        } else {
            Write-Warn 'Virtualization-based security is running (some FPS cost).'
        }
        Write-Warn 'Option 3 turns it off. Friends with the same PC but more FPS often have it off.'
    } elseif ($dg) {
        Write-Ok 'Memory Integrity / VBS is off.'
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
        Write-Bad 'Only ONE RAM stick = single channel. FiveM loses 20-40% FPS. Use 2 matching sticks.'
    }
    $slowest = ($mods | Measure-Object ConfiguredClockSpeed -Minimum).Minimum
    $isDdr5 = @($mods | Where-Object { $_.SMBIOSMemoryType -eq 34 }).Count -gt 0
    if (($isDdr5 -and $slowest -le 4800) -or (-not $isDdr5 -and $slowest -le 2666)) {
        Write-Bad 'RAM runs at base speed. Enable XMP in BIOS - big win for CPU-bound FiveM.'
    }
    if ($usedPct -ge 75) {
        Write-Bad "RAM is already $usedPct% used - use option 7 (close apps) and the booster RAM cleaner."
    }

    $pf = @(Get-CimInstance Win32_PageFileUsage)
    if ($pf.Count -eq 0) {
        Write-Bad 'No page file! FiveM stutters/crashes without one. Set it to "System managed".'
    }

    foreach ($g in Get-CimInstance Win32_VideoController) {
        Write-Info ("GPU     : {0}  driver {1} ({2:yyyy-MM-dd})" -f $g.Name, $g.DriverVersion, $g.DriverDate)
    }

    $active = Invoke-PowerCfg /getactivescheme
    Write-Info ("Power   : {0}" -f ($active -replace '^.*\(|\)\s*$', ''))
    if ($active -notmatch [regex]::Escape($PlanName)) {
        Write-Warn 'Not on the FiveM Optimizer power plan (option 2).'
    }

    $dvr = Get-RegState 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled'
    if (-not $dvr.Exists -or $dvr.Value -ne 0) { Write-Warn 'Xbox Game DVR recording is ON (option 2).' }

    $running = @($Services.Keys | Where-Object {
        (Get-Service $_ -ErrorAction SilentlyContinue).Status -eq 'Running' })
    if ($running.Count) { Write-Warn ("Background services running: {0} (option 2)" -f ($running -join ', ')) }

    $c = Get-PSDrive C -ErrorAction SilentlyContinue
    if ($c -and $c.Free -lt 30GB) { Write-Warn ("Only {0:N0} GB free on C: - keep 30 GB free." -f ($c.Free / 1GB)) }

    foreach ($file in $GtaSettingsFiles) {
        if (-not (Test-Path $file)) { continue }
        Write-Info "Settings: $file"
        try {
            [xml]$doc = Get-Content $file -Raw
            foreach ($key in 'CityDensity', 'LodScale', 'MaxLodScale', 'Shadow_LongShadows', 'HdStreamingInFlight') {
                $node = $doc.SelectSingleNode("//$key")
                if ($node) { Write-Info ("          {0,-22} {1}" -f $key, $node.value) }
            }
        } catch { Write-Warn "Could not read $file" }
    }

    $startup = @(Get-StartupEntries)
    Write-Info ("Startup : {0} apps start with Windows (option 6)" -f $startup.Count)

    Write-Host ''
    Write-Host '  Top 10 processes by RAM:' -ForegroundColor Cyan
    Get-Process | Group-Object ProcessName | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; RAM = ($_.Group | Measure-Object WorkingSet64 -Sum).Sum }
    } | Sort-Object RAM -Descending | Select-Object -First 10 | ForEach-Object {
        Write-Host ("     {0,-28} {1,10}" -f $_.Name, (Format-Size $_.RAM))
    }
}

# ---------------------------------------------------------- full optimize ---

function Invoke-Optimize {
    Write-Title 'Optimize Windows (lite-Windows level, fully reversible)'

    # Power plan ------------------------------------------------------------
    if (-not $script:Backup.PowerPlan) {
        $current = Invoke-PowerCfg /getactivescheme
        if ($current -match '([0-9a-fA-F-]{36})') { $script:Backup.PowerPlan = $Matches[1] }
    }
    $ourPlan = $script:Backup.OurPlan
    if (-not ($ourPlan -and (Invoke-PowerCfg /list) -match $ourPlan)) {
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
    $script:Backup.OurPlan = $ourPlan
    Save-Backup
    if ($ourPlan) {
        $settings = @(
            'CPMINCORES 100', 'CPMINCORES1 100',      # no core parking (P and E)
            'PROCTHROTTLEMIN 100', 'PROCTHROTTLEMIN1 100',
            'PERFEPP 0', 'PERFEPP1 0',                # max performance preference
            'SCHEDPOLICY 2', 'SHORTSCHEDPOLICY 2'     # prefer P-cores for busy threads
        )
        foreach ($s in $settings) {
            $parts = $s -split ' '
            Invoke-PowerCfg -setacvalueindex $ourPlan SUB_PROCESSOR $parts[0] $parts[1] | Out-Null
        }
        Invoke-PowerCfg -setactive $ourPlan | Out-Null
        Write-Ok "Power plan '$PlanName' (no core parking, max clocks, prefer P-cores)"
    }

    # Registry --------------------------------------------------------------
    foreach ($t in $Tweaks) {
        try { Set-Reg $t[0] $t[1] $t[2] $t[3]; Write-Ok $t[4] }
        catch { Write-Bad "$($t[4]): $($_.Exception.Message)" }
    }

    # Services --------------------------------------------------------------
    $list = [ordered]@{}
    foreach ($k in $Services.Keys) { $list[$k] = $Services[$k] }
    if (-not (Read-YesNo 'Do you use the Xbox app / Game Pass / Xbox sign-in?')) {
        foreach ($k in $XboxServices.Keys) { $list[$k] = $XboxServices[$k] }
    }
    foreach ($svc in $list.Keys) {
        $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$svc"
        if (-not (Test-Path $key)) { continue }
        try {
            Set-Reg $key 'Start' 4 'DWord'
            Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
            Write-Ok "Service off: $($list[$svc])"
        } catch {
            Write-Bad "Service $svc : $($_.Exception.Message)"
        }
    }

    # Telemetry tasks -------------------------------------------------------
    foreach ($t in $TelemetryTasks) {
        $task = Get-ScheduledTask -TaskPath $t[0] -TaskName $t[1] -ErrorAction SilentlyContinue
        if (-not $task) { continue }
        $known = $script:Backup.Tasks | Where-Object { $_.Path -eq $t[0] -and $_.Name -eq $t[1] }
        if (-not $known) {
            $script:Backup.Tasks = @($script:Backup.Tasks) +
                [pscustomobject]@{ Path = $t[0]; Name = $t[1]; Enabled = ($task.State -ne 'Disabled') }
            Save-Backup
        }
        Disable-ScheduledTask -TaskPath $t[0] -TaskName $t[1] -ErrorAction SilentlyContinue | Out-Null
    }
    Write-Ok 'Telemetry scheduled tasks off'

    Add-DefenderExclusions

    Write-Host ''
    Write-Ok "Original settings saved in $BackupFile"
    Write-Warn 'Restart Windows once to apply everything.'
}

# ---------------------------------------------------- defender exclusions ---
# Defender scanning FiveM's cache while assets stream in = CPU spikes / stutter.

function Add-DefenderExclusions {
    $pref = Get-MpPreference -ErrorAction SilentlyContinue
    if (-not $pref) { Write-Info 'Microsoft Defender not active - skipping exclusions.'; return }

    $paths = @("$env:LOCALAPPDATA\FiveM", "$env:APPDATA\CitizenFX")
    $installKeys = @(
        @('HKLM:\SOFTWARE\WOW6432Node\Rockstar Games\Grand Theft Auto V', 'InstallFolder'),
        @('HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Steam App 271590', 'InstallLocation')
    )
    foreach ($k in $installKeys) {
        $dir = (Get-RegState $k[0] $k[1]).Value
        if ($dir) { $paths += ([string]$dir).TrimEnd('\') }
    }

    $existing = @($pref.ExclusionPath)
    foreach ($path in ($paths | Where-Object { Test-Path $_ } | Select-Object -Unique)) {
        if ($existing -contains $path) { continue }
        try {
            Add-MpPreference -ExclusionPath $path -ErrorAction Stop
            $script:Backup.Exclusions = @($script:Backup.Exclusions) + $path
            Save-Backup
            Write-Ok "Defender stops scanning $path"
        } catch {
            Write-Warn "Could not add Defender exclusion for $path"
        }
    }
}

# -------------------------------------------------------- memory integrity ---

function Invoke-DisableVbs {
    Write-Title 'Turn off Memory Integrity / VBS'
    Write-Info 'Memory Integrity (Core isolation) runs Windows under a hypervisor.'
    Write-Info 'On Windows 11 it is on by default and costs ~5-15% FPS in CPU-bound games.'
    Write-Warn 'Trade-off: slightly less protection against malicious drivers.'
    Write-Warn 'Some anti-cheats (Valorant/FACEIT) may ask you to turn it back on - option 9 turns it back on.'
    if (-not (Read-YesNo 'Turn it off?')) { return }

    try {
        Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' 'Enabled' 0 'DWord'
        Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' 'EnableVirtualizationBasedSecurity' 0 'DWord'
        $policy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceGuard'
        if ((Get-RegState $policy 'EnableVirtualizationBasedSecurity').Exists) {
            Set-Reg $policy 'EnableVirtualizationBasedSecurity' 0 'DWord'
        }
        Write-Ok 'Memory Integrity / VBS off.'
        Write-Warn 'Restart Windows. Then run option 1 to confirm it shows as off.'
    } catch {
        Write-Bad $_.Exception.Message
    }
}

# --------------------------------------------------------- FiveM settings ---

function Invoke-GtaPreset($mode) {
    Write-Title 'FiveM graphics preset'
    Write-Info 'Only CPU-heavy settings are changed. Textures / resolution / AA stay as they are,'
    Write-Info 'so the game stays sharp - your GPU has plenty of headroom for those.'
    if (Test-FiveMRunning) { Write-Bad 'Close FiveM first.'; return }
    if (-not $mode) {
        Write-Host '   1) Balanced  - fewer cars/people, shorter draw distance, game looks normal'
        Write-Host '   2) MAX FPS   - everything that costs CPU at minimum (biggest FPS gain)'
        $mode = if ((Read-Host '  Choose') -eq '2') { 'max' } else { 'balanced' }
    }
    $preset = if ($mode -eq 'max') { $MaxFpsPreset } else { $BalancedPreset }

    $files = @($GtaSettingsFiles | Where-Object { Test-Path $_ })
    if ($files.Count -eq 0) {
        Write-Bad 'No GTA V settings file found. Start FiveM once, change any setting, then retry.'
        return
    }
    foreach ($file in $files) {
        try {
            Backup-File $file
            [xml]$doc = Get-Content $file -Raw -ErrorAction Stop
            Write-Info $file
            foreach ($key in $preset.Keys) {
                $node = $doc.SelectSingleNode("//$key")
                if (-not $node -or -not $node.Attributes['value']) { continue }
                $old = $node.value
                $node.value = $preset[$key]
                Write-Ok ("{0,-26} {1,-10} -> {2}" -f $key, $old, $preset[$key])
            }
            $doc.Save($file)
        } catch {
            Write-Bad "$file : $($_.Exception.Message)"
        }
    }
}

function Invoke-ImportSettings {
    Write-Title "Import a friend's FiveM graphics settings"
    Write-Info 'Your friend sends you this file from their PC:'
    Write-Info '   %APPDATA%\CitizenFX\gta5_settings.xml'
    Write-Info 'Your own resolution, monitor and GPU entries are kept.'
    if (Test-FiveMRunning) { Write-Bad 'Close FiveM first.'; return }

    $src = (Read-Host '  Drag the file into this window and press Enter').Trim().Trim('"')
    if (-not (Test-Path $src)) { Write-Bad 'File not found.'; return }
    try {
        [xml]$friend = Get-Content $src -Raw -ErrorAction Stop
        if (-not $friend.SelectSingleNode('//graphics')) { Write-Bad 'This is not a GTA V settings file.'; return }
    } catch { Write-Bad 'This is not a valid XML file.'; return }

    $targets = @($GtaSettingsFiles | Where-Object { Test-Path $_ })
    if ($targets.Count -eq 0) { $targets = @($GtaSettingsFiles[0]) }

    foreach ($file in $targets) {
        try {
            Backup-File $file
            [xml]$doc = $friend.OuterXml
            if (Test-Path $file) {
                [xml]$mine = Get-Content $file -Raw
                foreach ($key in 'VideoCardDescription', 'AdapterIndex', 'OutputIndex',
                                 'ScreenWidth', 'ScreenHeight', 'RefreshRate', 'Windowed') {
                    $theirs = $doc.SelectSingleNode("//$key")
                    $own    = $mine.SelectSingleNode("//$key")
                    if (-not $theirs -or -not $own) { continue }
                    $theirs.InnerXml = $own.InnerXml
                    foreach ($a in $own.Attributes) { $theirs.SetAttribute($a.Name, $a.Value) }
                }
            } else {
                New-Item -ItemType Directory -Path (Split-Path $file) -Force | Out-Null
            }
            $doc.Save($file)
            Write-Ok "Imported into $file"
        } catch {
            Write-Bad "$file : $($_.Exception.Message)"
        }
    }
}

# ------------------------------------------------------------ startup apps ---

$RunKeys = @(
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
)

function Get-StartupEntries {
    foreach ($key in $RunKeys) {
        if (-not (Test-Path $key)) { continue }
        $item = Get-Item $key
        foreach ($name in $item.GetValueNames()) {
            if (-not $name) { continue }
            [pscustomobject]@{ Key = $key; Name = $name; Command = [string]$item.GetValue($name) }
        }
    }
}

function Invoke-Startup {
    Write-Title 'Startup apps'
    $entries = @(Get-StartupEntries)
    if ($entries.Count -eq 0) { Write-Ok 'Nothing starts with Windows.'; return }
    for ($i = 0; $i -lt $entries.Count; $i++) {
        $cmd = $entries[$i].Command
        if ($cmd.Length -gt 45) { $cmd = $cmd.Substring(0, 42) + '...' }
        Write-Host ("  {0,2}) {1,-28} {2}" -f ($i + 1), $entries[$i].Name, $cmd)
    }
    Write-Info 'Keep your audio / GPU / mouse software. Discord, Steam, Epic, OneDrive, Spotify can go.'
    $pick = Read-Host '  Numbers to stop starting with Windows (e.g. 1,3) or Enter to skip'
    foreach ($n in ($pick -split '[,\s]+' | Where-Object { $_ -match '^\d+$' })) {
        $idx = [int]$n - 1
        if ($idx -lt 0 -or $idx -ge $entries.Count) { continue }
        try {
            Remove-Reg $entries[$idx].Key $entries[$idx].Name
            Write-Ok "Removed from startup: $($entries[$idx].Name)"
        } catch {
            Write-Bad "$($entries[$idx].Name): $($_.Exception.Message)"
        }
    }
}

# ------------------------------------------------------------------ clean ---

function Invoke-Clean {
    Write-Title 'Clean FiveM cache and temp files'
    if (Test-FiveMRunning) { Write-Bad 'Close FiveM first.'; return }

    $targets = @(
        "$FiveMApp\data\cache",
        "$FiveMApp\data\server-cache",
        "$FiveMApp\data\server-cache-priv",
        "$FiveMApp\crashes",
        "$FiveMApp\logs",
        "$env:LOCALAPPDATA\NVIDIA\DXCache",
        "$env:LOCALAPPDATA\D3DSCache",
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
    Write-Ok ("Freed {0}. First join / first minutes rebuild caches (a bit slower once)." -f (Format-Size $freed))
}

# --------------------------------------------------------------- free RAM ---

function Invoke-FreeRam {
    Write-Title 'Close heavy apps before playing'
    $protected = 'System|Idle|Registry|smss|csrss|wininit|winlogon|services|lsass|svchost|' +
                 'dwm|explorer|fontdrvhost|Memory Compression|MsMpEng|audiodg|powershell|' +
                 'conhost|WindowsTerminal|nvcontainer|NVDisplay.Container|ctfmon|sihost|' +
                 'SearchHost|StartMenuExperienceHost|ShellExperienceHost|RuntimeBroker|FiveM'
    $list = @(Get-Process | Where-Object { $_.ProcessName -notmatch "^($protected)" } |
        Group-Object ProcessName | ForEach-Object {
            [pscustomobject]@{ Name = $_.Name; RAM = ($_.Group | Measure-Object WorkingSet64 -Sum).Sum }
        } | Sort-Object RAM -Descending | Select-Object -First 15)

    for ($i = 0; $i -lt $list.Count; $i++) {
        Write-Host ("  {0,2}) {1,-30} {2,10}" -f ($i + 1), $list[$i].Name, (Format-Size $list[$i].RAM))
    }
    $pick = Read-Host "`n  Numbers to close (e.g. 1,3,4) or Enter to skip"
    foreach ($n in ($pick -split '[,\s]+' | Where-Object { $_ -match '^\d+$' })) {
        $idx = [int]$n - 1
        if ($idx -lt 0 -or $idx -ge $list.Count) { continue }
        Get-Process -Name $list[$idx].Name -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Write-Ok "Closed $($list[$idx].Name) ($(Format-Size $list[$idx].RAM))"
    }
}

# ------------------------------------------------------------ game booster ---

function Get-MemoryLists {
    $m = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory -ErrorAction SilentlyContinue
    if (-not $m) { return $null }
    return @{
        Free    = [int64]$m.FreeAndZeroPageListBytes
        Standby = [int64]$m.StandbyCacheNormalPriorityBytes + [int64]$m.StandbyCacheReserveBytes +
                  [int64]$m.StandbyCacheCoreBytes
    }
}

function Invoke-Booster {
    Write-Title 'Game Booster (keep this window open while playing)'

    $masks  = Get-CoreMasks
    $pinGame = $false
    $pushBg  = $false
    if ($masks.Hybrid) {
        Write-Info ("Hybrid CPU: {0} P-core threads, {1} E-cores." -f $masks.PCount, $masks.ECount)
        $pinGame = Read-YesNo 'Lock FiveM to the P-cores only?'
        $pushBg  = Read-YesNo 'Move Discord / browsers / launchers to the E-cores?'
    }
    $ramSaver = Read-YesNo 'RAM saver: trim background apps + auto-clean standby memory (like ISLC)?'

    $timer = [Native]::SetTimer($true)
    Write-Ok ("Timer resolution {0:N2} ms (smoother frame pacing)" -f ($timer / 10000))
    Write-Info 'Waiting for FiveM... press Q to stop.'

    $boosted   = @{}
    $moved     = @{}
    $lastPurge = [datetime]::MinValue
    $tick      = 0
    try {
        while ($true) {
            foreach ($proc in Get-Process | Where-Object { $_.ProcessName -match $GamePattern }) {
                if ($boosted.ContainsKey($proc.Id)) { continue }
                try {
                    $proc.PriorityClass = [Diagnostics.ProcessPriorityClass]::High
                    if ($pinGame) { $proc.ProcessorAffinity = [IntPtr]$masks.P }
                    $where = if ($pinGame) { ', P-cores only' } else { '' }
                    Write-Ok ("{0} (PID {1}) -> High priority{2}" -f $proc.ProcessName, $proc.Id, $where)
                } catch {
                    Write-Bad "Could not boost $($proc.ProcessName): $($_.Exception.Message)"
                }
                $boosted[$proc.Id] = $true
            }

            if ($boosted.Count -gt 0) {
                foreach ($proc in Get-Process -Name $BackgroundApps -ErrorAction SilentlyContinue) {
                    if ($moved.ContainsKey($proc.Id)) { continue }
                    try {
                        $proc.PriorityClass = [Diagnostics.ProcessPriorityClass]::BelowNormal
                        if ($pushBg) { $proc.ProcessorAffinity = [IntPtr]$masks.E }
                        if ($ramSaver) { [Native]::Trim($proc.Handle) | Out-Null }
                        $moved[$proc.Id] = $proc
                    } catch {
                        $moved[$proc.Id] = $null
                    }
                }

                # Every ~6 s: empty the standby list when free RAM runs low
                if ($ramSaver -and ($tick % 2 -eq 0)) {
                    $mem = Get-MemoryLists
                    if ($mem -and $mem.Free -lt 1GB -and $mem.Standby -gt 1GB -and
                        ((Get-Date) - $lastPurge).TotalSeconds -gt 30) {
                        if ([Native]::PurgeStandbyList()) {
                            Write-Info ("{0:HH:mm:ss} cleaned {1} standby memory" -f (Get-Date), (Format-Size $mem.Standby))
                        }
                        $lastPurge = Get-Date
                    }
                }
            }

            foreach ($id in @($boosted.Keys)) {
                if (-not (Get-Process -Id $id -ErrorAction SilentlyContinue)) {
                    $boosted.Remove($id)
                    Write-Info "Game process $id closed. Waiting for FiveM..."
                }
            }

            $tick++
            for ($i = 0; $i -lt 30; $i++) {
                if ([Console]::KeyAvailable -and [Console]::ReadKey($true).Key -eq 'Q') { return }
                Start-Sleep -Milliseconds 100
            }
        }
    } finally {
        [Native]::SetTimer($false) | Out-Null
        foreach ($proc in $moved.Values) {
            if (-not $proc -or $proc.HasExited) { continue }
            try {
                $proc.PriorityClass = [Diagnostics.ProcessPriorityClass]::Normal
                $proc.ProcessorAffinity = [IntPtr]$masks.All
            } catch { }
        }
        Write-Info 'Booster stopped, background apps back to normal.'
    }
}

# ------------------------------------------------------------- all-in-one ---

function Invoke-AllInOne {
    Write-Title 'ALL-IN-ONE: maximum FPS'
    if (Test-FiveMRunning) { Write-Bad 'Close FiveM first.'; return }
    Invoke-Optimize
    Invoke-DisableVbs
    Invoke-GtaPreset 'max'
    Invoke-Clean
    Invoke-Startup
    Write-Title 'Done'
    Write-Ok 'Everything applied. Option 9 undoes all of it.'
    Write-Warn 'Restart, then start the GAME BOOSTER (B) before every session.'
    if (Read-YesNo 'Restart now?') { Restart-Computer -Force }
}

# ---------------------------------------------------------------- restore ---

function Invoke-Restore {
    Write-Title 'Restore original settings'
    if (-not (Test-Path $BackupFile)) { Write-Warn 'No backup found - nothing to restore.'; return }
    if (-not (Read-YesNo 'Put every setting this tool changed back to the original?')) { return }

    foreach ($r in $script:Backup.Registry) {
        try {
            if ($r.Exists) {
                if (-not (Test-Path $r.Path)) { New-Item -Path $r.Path -Force -ErrorAction Stop | Out-Null }
                $value = $r.Value
                if ($r.Kind -eq 'Binary')      { $value = [byte[]]@($value) }
                if ($r.Kind -eq 'MultiString') { $value = [string[]]@($value) }
                New-ItemProperty -Path $r.Path -Name $r.Name -Value $value -PropertyType $r.Kind -Force -ErrorAction Stop | Out-Null
            } elseif (Test-Path $r.Path) {
                Remove-ItemProperty -Path $r.Path -Name $r.Name -ErrorAction SilentlyContinue
            }
        } catch {
            Write-Bad "$($r.Path)\$($r.Name): $($_.Exception.Message)"
        }
    }
    Write-Ok ("{0} registry values / services restored" -f @($script:Backup.Registry).Count)

    foreach ($t in $script:Backup.Tasks) {
        if ($t.Enabled) {
            Enable-ScheduledTask -TaskPath $t.Path -TaskName $t.Name -ErrorAction SilentlyContinue | Out-Null
        }
    }
    Write-Ok 'Scheduled tasks restored'

    foreach ($path in $script:Backup.Exclusions) {
        Remove-MpPreference -ExclusionPath $path -ErrorAction SilentlyContinue
    }
    if (@($script:Backup.Exclusions).Count) { Write-Ok 'Defender exclusions removed' }

    foreach ($f in $script:Backup.Files) {
        try {
            if ($f.Copy -and (Test-Path $f.Copy)) {
                Copy-Item $f.Copy $f.Original -Force -ErrorAction Stop
                Remove-Item $f.Copy -Force
            } elseif (-not $f.Copy -and (Test-Path $f.Original)) {
                Remove-Item $f.Original -Force
            }
            Write-Ok "Restored $($f.Original)"
        } catch {
            Write-Bad "$($f.Original): $($_.Exception.Message)"
        }
    }

    if ($script:Backup.PowerPlan) {
        Invoke-PowerCfg -setactive $script:Backup.PowerPlan | Out-Null
        Write-Ok 'Original power plan re-activated'
    }
    if ($script:Backup.OurPlan) {
        Invoke-PowerCfg -delete $script:Backup.OurPlan | Out-Null
        Write-Ok "Removed '$PlanName' power plan"
    }

    Remove-Item $BackupFile -Force
    $script:Backup = Get-Backup
    Write-Warn 'Restart Windows to finish restoring.'
}

# -------------------------------------------------------------------- menu ---

if (-not (Test-Admin)) {
    Write-Bad 'Run this as Administrator (use Start-Optimizer.bat).'
    Read-Host '  Press Enter to exit'
    exit 1
}

$script:Backup = Get-Backup

while ($true) {
    Write-Title 'FiveM Optimizer'
    Write-Host '   A) ALL-IN-ONE MAX FPS                     (does 2, 3, 4-max, 8, 6)' -ForegroundColor Green
    Write-Host '   B) GAME BOOSTER - run while playing' -ForegroundColor Green
    Write-Host ''
    Write-Host '   1) Diagnose my PC'
    Write-Host '   2) Optimize Windows                       (power, services, telemetry, scheduler)'
    Write-Host '   3) Turn off Memory Integrity / VBS        (big FPS win on Windows 11)'
    Write-Host '   4) FiveM graphics preset (Balanced / MAX FPS)'
    Write-Host "   5) Import a friend's FiveM settings file"
    Write-Host '   6) Startup apps'
    Write-Host '   7) Close heavy apps (free RAM now)'
    Write-Host '   8) Clean FiveM cache + temp + shader cache'
    Write-Host '   9) Restore everything to original'
    Write-Host '   0) Exit'
    $choice = Read-Host "`n  Choose"
    try {
        switch ($choice) {
            'a' { Invoke-AllInOne }
            '1' { Invoke-Diagnose }
            '2' { Invoke-Optimize }
            '3' { Invoke-DisableVbs }
            '4' { Invoke-GtaPreset }
            '5' { Invoke-ImportSettings }
            '6' { Invoke-Startup }
            '7' { Invoke-FreeRam }
            '8' { Invoke-Clean }
            'b' { Invoke-Booster }
            '9' { Invoke-Restore }
            '0' { exit 0 }
            default { Write-Warn 'Unknown option.' }
        }
    } catch {
        Write-Bad $_.Exception.Message
    }
    Read-Host "`n  Press Enter to go back to the menu"
}
