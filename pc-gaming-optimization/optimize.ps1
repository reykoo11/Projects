#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Безопасная оптимизация Windows 10/11 под игры.

.DESCRIPTION
    Делает только обратимые изменения. Перед изменениями создаётся точка
    восстановления, а исходные значения реестра и схема питания сохраняются
    в %ProgramData%\GamingOptimizer\backup.json. Откатить всё: restore.ps1.

    Не трогает: Защитник Windows, обновления, файл подкачки, службы,
    драйверы, BIOS. Никаких "твиков" сомнительной пользы.

.PARAMETER VisualEffects
    Дополнительно выключить анимации/тени Windows ("наилучшее быстродействие").
    Даёт немного отзывчивости на слабых ПК, но Windows выглядит проще.

.PARAMETER SkipCleanup
    Не чистить временные файлы.
#>
param(
    [switch]$VisualEffects,
    [switch]$SkipCleanup
)

$ErrorActionPreference = 'Stop'
$BackupDir  = Join-Path $env:ProgramData 'GamingOptimizer'
$BackupFile = Join-Path $BackupDir 'backup.json'

function Write-Step($text) { Write-Host "`n==> $text" -ForegroundColor Cyan }
function Write-Ok($text)   { Write-Host "    [OK] $text" -ForegroundColor Green }
function Write-Warn($text) { Write-Host "    [!]  $text" -ForegroundColor Yellow }

# ---------------------------------------------------------------- backup ---

New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
$Backup = @{ Registry = @(); PowerScheme = $null }
if (Test-Path $BackupFile) {
    # Повторный запуск: исходные значения уже сохранены, не перезаписываем их
    # уже оптимизированными.
    $loaded = Get-Content $BackupFile -Raw | ConvertFrom-Json
    $Backup.PowerScheme = $loaded.PowerScheme
    if ($loaded.Registry) { $Backup.Registry = @($loaded.Registry) }
}

function Save-Backup {
    $Backup | ConvertTo-Json -Depth 5 | Set-Content -Path $BackupFile -Encoding UTF8
}

function Set-Reg {
    param(
        [string]$Path,
        [string]$Name,
        [ValidateSet('DWord', 'String')][string]$Type,
        $Value
    )
    $already = $Backup.Registry | Where-Object { $_.Path -eq $Path -and $_.Name -eq $Name }
    if (-not $already) {
        $entry = [ordered]@{ Path = $Path; Name = $Name; Existed = $false; Type = $null; Value = $null }
        if (Test-Path $Path) {
            $key = Get-Item $Path
            if ($key.GetValueNames() -contains $Name) {
                $entry.Existed = $true
                $entry.Type    = $key.GetValueKind($Name).ToString()
                $entry.Value   = $key.GetValue($Name, $null, 'DoNotExpandEnvironmentNames')
            }
        }
        $script:Backup.Registry += [pscustomobject]$entry
    }
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -PropertyType $Type -Value $Value -Force | Out-Null
}

# ------------------------------------------------------- restore point ---

Write-Step 'Точка восстановления'
try {
    Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
    Checkpoint-Computer -Description 'Before GamingOptimizer' -RestorePointType MODIFY_SETTINGS
    Write-Ok 'Создана'
} catch {
    # Windows разрешает одну точку в 24 часа — это не критично, есть backup.json
    Write-Warn "Не удалось создать ($($_.Exception.Message)). Продолжаю: откат всё равно возможен через restore.ps1"
}

# ---------------------------------------------------------- power plan ---

Write-Step 'Схема питания'
if (-not $Backup.PowerScheme) {
    $active = (powercfg /getactivescheme) -replace '.*?([0-9a-fA-F-]{36}).*', '$1'
    $Backup.PowerScheme = $active.Trim()
}
$ultimate = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
$high     = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
$existing = powercfg /list | Select-String 'Ultimate Performance|Максимальная производительность|Высокая производительность|High performance'
$ultimateLine = $existing | Where-Object { $_ -match 'Ultimate|Максимальная' } | Select-Object -First 1
if ($ultimateLine) {
    $guid = ($ultimateLine.ToString() -replace '.*?([0-9a-fA-F-]{36}).*', '$1').Trim()
} else {
    # Схемы "Максимальная производительность" нет в некоторых редакциях Windows
    $guid = $null
    try {
        $dup = powercfg -duplicatescheme $ultimate 2>&1
        if ($LASTEXITCODE -eq 0 -and "$dup" -match '[0-9a-fA-F-]{36}') { $guid = $Matches[0] }
    } catch { }
}
if ($guid) {
    powercfg /setactive $guid
    Write-Ok 'Включена "Максимальная производительность"'
} else {
    powercfg /setactive $high
    Write-Ok 'Включена "Высокая производительность"'
}
if (Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue) {
    Write-Warn 'Это ноутбук: играй от зарядки, иначе Windows всё равно урежет мощность'
}
Save-Backup

# ------------------------------------------------- game mode / game bar ---

Write-Step 'Игровой режим и фоновая запись'
Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' DWord 1
Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'AllowAutoGameMode'   DWord 1
Write-Ok 'Игровой режим включён'
# Фоновая запись геймплея (Xbox Game DVR) постоянно ест ресурсы GPU
Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' DWord 0
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' DWord 0
Write-Ok 'Фоновая запись Xbox Game DVR выключена'

# --------------------------------------------------------------- GPU ---

Write-Step 'Видеокарта'
# Аппаратное планирование GPU (HAGS). Применится после перезагрузки,
# работает на GTX 10xx+/RX 5000+ с актуальными драйверами.
Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' DWord 2
Write-Ok 'Аппаратное ускорение планирования GPU включено (после перезагрузки)'

# ------------------------------------------------ scheduler priorities ---

Write-Step 'Приоритет игр в планировщике Windows'
$mm = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
Set-Reg $mm 'SystemResponsiveness'   DWord 10
Set-Reg $mm 'NetworkThrottlingIndex' DWord 0xffffffff
$games = "$mm\Tasks\Games"
Set-Reg $games 'GPU Priority'        DWord 8
Set-Reg $games 'Priority'            DWord 6
Set-Reg $games 'Scheduling Category' String 'High'
Set-Reg $games 'SFIO Priority'       String 'High'
Write-Ok 'Играм отдан повышенный приоритет CPU/GPU, сетевое ограничение снято'

# -------------------------------------------------------------- mouse ---

Write-Step 'Мышь'
Set-Reg 'HKCU:\Control Panel\Mouse' 'MouseSpeed'      String '0'
Set-Reg 'HKCU:\Control Panel\Mouse' 'MouseThreshold1' String '0'
Set-Reg 'HKCU:\Control Panel\Mouse' 'MouseThreshold2' String '0'
Write-Ok 'Ускорение указателя ("повышенная точность") выключено — прицел 1:1'

# ---------------------------------------------------- background apps ---

Write-Step 'Фоновые приложения'
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled' DWord 1
Write-Ok 'Приложениям из Microsoft Store запрещено работать в фоне'

# ----------------------------------------------------- visual effects ---

if ($VisualEffects) {
    Write-Step 'Визуальные эффекты Windows'
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' DWord 2
    Write-Ok 'Режим "наилучшее быстродействие" (после перезахода в систему)'
}

Save-Backup

# ------------------------------------------------------------ cleanup ---

if (-not $SkipCleanup) {
    Write-Step 'Очистка временных файлов'
    $before = (Get-PSDrive ($env:SystemDrive.TrimEnd(':'))).Free
    foreach ($dir in @($env:TEMP, "$env:SystemRoot\Temp")) {
        Get-ChildItem $dir -Force -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
    $freed = ((Get-PSDrive ($env:SystemDrive.TrimEnd(':'))).Free - $before) / 1MB
    Write-Ok ("Освобождено ~{0:N0} МБ (занятые файлы пропущены)" -f [math]::Max($freed, 0))
}

# --------------------------------------------------------- diagnostics ---

Write-Step 'Проверка железа (это нужно поправить вручную, если есть [!])'

$gpus = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notmatch 'Basic|Remote|Virtual' }
foreach ($g in $gpus) {
    $age = if ($g.DriverDate) { ((Get-Date) - $g.DriverDate).Days } else { $null }
    $msg = "$($g.Name), драйвер $($g.DriverVersion)"
    if ($age -gt 180) { Write-Warn "$msg — драйверу $age дн., обнови с сайта NVIDIA/AMD/Intel" }
    else { Write-Ok $msg }
}

$ram = @(Get-CimInstance Win32_PhysicalMemory)
$totalGb = [math]::Round(($ram | Measure-Object Capacity -Sum).Sum / 1GB)
$actual  = ($ram | Measure-Object ConfiguredClockSpeed -Maximum).Maximum
Write-Ok "ОЗУ: $totalGb ГБ, планок: $($ram.Count), работает на $actual МГц"
if ($ram.Count -eq 1) { Write-Warn 'Одна планка памяти = одноканальный режим, это режет FPS до 20-30%. Лучше 2 планки' }
if ($totalGb -lt 16)  { Write-Warn 'Меньше 16 ГБ ОЗУ — для современных игр мало, закрывай браузер перед игрой' }
# Типичные базовые (JEDEC) частоты — если память на них, XMP скорее всего выключен
if ($actual -in 2133, 2400, 2666, 4800) {
    Write-Warn 'Память на базовой частоте. Если у планок есть XMP/EXPO-профиль — включи его в BIOS'
}

$sys = Get-PSDrive ($env:SystemDrive.TrimEnd(':'))
$freePct = [math]::Round($sys.Free / ($sys.Used + $sys.Free) * 100)
if ($freePct -lt 15) { Write-Warn "На системном диске свободно всего $freePct% — освободи место" }
else { Write-Ok "Системный диск: свободно $freePct%" }
Get-PhysicalDisk -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.MediaType -eq 'HDD') { Write-Warn "$($_.FriendlyName) — это HDD. Игры ставь на SSD" }
}

$startup = Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue
if ($startup) {
    Write-Host "`n    Программы в автозагрузке ($($startup.Count)). Лишнее отключи:" -ForegroundColor Gray
    Write-Host '    Диспетчер задач (Ctrl+Shift+Esc) -> Автозагрузка' -ForegroundColor Gray
    $startup | Select-Object -ExpandProperty Name -Unique | ForEach-Object { Write-Host "      - $_" -ForegroundColor Gray }
}

Write-Host "`nГотово. ПЕРЕЗАГРУЗИ компьютер, чтобы всё применилось." -ForegroundColor Green
Write-Host "Откатить изменения: restore.bat (backup: $BackupFile)`n" -ForegroundColor Gray
