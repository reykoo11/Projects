#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Откат всех изменений optimize.ps1 из %ProgramData%\GamingOptimizer\backup.json.
#>
$ErrorActionPreference = 'Stop'
$BackupFile = Join-Path $env:ProgramData 'GamingOptimizer\backup.json'

if (-not (Test-Path $BackupFile)) {
    Write-Host 'Резервная копия не найдена — откатывать нечего.' -ForegroundColor Yellow
    exit 1
}
$Backup = Get-Content $BackupFile -Raw | ConvertFrom-Json

foreach ($e in $Backup.Registry) {
    try {
        if ($e.Existed) {
            if (-not (Test-Path $e.Path)) { New-Item -Path $e.Path -Force | Out-Null }
            New-ItemProperty -Path $e.Path -Name $e.Name -PropertyType $e.Type -Value $e.Value -Force | Out-Null
        } elseif (Test-Path $e.Path) {
            Remove-ItemProperty -Path $e.Path -Name $e.Name -ErrorAction SilentlyContinue
        }
        Write-Host "  [OK] $($e.Path)\$($e.Name)" -ForegroundColor Green
    } catch {
        Write-Host "  [!]  $($e.Path)\$($e.Name): $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

if ($Backup.PowerScheme) {
    powercfg /setactive $Backup.PowerScheme
    Write-Host "  [OK] Схема питания возвращена ($($Backup.PowerScheme))" -ForegroundColor Green
}

Remove-Item $BackupFile -Force
Write-Host "`nГотово. Перезагрузи компьютер." -ForegroundColor Green
