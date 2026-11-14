#!/usr/bin/env pwsh

# ===========================================================
#                    FLASHOS MANAGER (PowerShell)
# ===========================================================
#
# Version: 0.4.0-ps
#
# GitHub:
# https://github.com/1xcoding/flashos
#
# SINGLE FILE EDITION (PowerShell for Windows)
#
# Works on Windows PowerShell 5.1 and PowerShell 7+.
#
# IMPORTANT: keep this file saved as "UTF-8 with BOM".
# Windows PowerShell 5.1 reads a BOM-less file as ANSI, which turns the
# emoji / Cyrillic strings into garbage and breaks parsing.
#
# ===========================================================
# FEATURES
# ===========================================================
#
# - USB detection (Windows WMI/Get-PhysicalDisk)
# - FlashOS detection
# - FlashOS installation
# - exFAT formatting (Format-Volume)
# - Main encrypted storage (gocryptfs equivalent via WinFsp/EncFS)
# - Main FlashOS password
# - Vault Mode
# - Vault passwords
# - Backup (SHA-256 verified)
# - Diagnostics
# - Settings
# - GitHub Latest Release updater
# - Release notes
# - FlashOS removal
# - Keyboard interface (Console.ReadKey)
# - Auto-lock on inactivity + instant lock key (L)
# - Event log
# - Recovery: key backup, key restore, storage check (fsck)
# - Password change (main storage and Vault)
# - Vault management (rename, size, delete)
# - Verified backups (SHA-256), restore, delete
# - Files: search, import, disk usage
# - Several FlashOS drives, working "Switch USB", safe eject
# - Update notification, manager rollback
# - Command line options (--help)
#
# ===========================================================

$AppName = "FlashOS Manager"
$FlashOSVersion = "0.4.0-ps"
$GitHubRepo = "1xcoding/flashos"
$GitHubApi = "https://api.github.com/repos/$GitHubRepo/releases/latest"

$RuntimeBase = "$env:TEMP\flashos-$([int]$env:USERNAME.GetHashCode())"
$MainMount = "$RuntimeBase\main"
$VaultMount = "$RuntimeBase\vault"
$NoticeFile = "$RuntimeBase\lock.notice"
$ChecksumFile = ".flashos-checksums.sha256"
$LogMaxBytes = 262144
$UpdateCheckInterval = 86400

$Device = ""
$DeviceMount = ""
$FlashOSDir = ""
$CurrentVault = ""
$FoundDevices = @()
$FoundMounts = @()
$ChosenItem = ""
$EjectOnStart = ""

New-Item -ItemType Directory -Force -Path $RuntimeBase | Out-Null

# ===========================================================
# COLORS & UI HELPERS
# ===========================================================

function Write-TTY([string]$Text, [string]$Color = "Cyan") {
    $prev = [Console]::ForegroundColor
    switch ($Color) {
        "Red" { [Console]::ForegroundColor = [ConsoleColor]::Red }
        "Green" { [Console]::ForegroundColor = [ConsoleColor]::Green }
        "Yellow" { [Console]::ForegroundColor = [ConsoleColor]::Yellow }
        "Blue" { [Console]::ForegroundColor = [ConsoleColor]::Blue }
        "Magenta" { [Console]::ForegroundColor = [ConsoleColor]::Magenta }
        "Cyan" { [Console]::ForegroundColor = [ConsoleColor]::Cyan }
        "White" { [Console]::ForegroundColor = [ConsoleColor]::White }
        "DarkGray" { [Console]::ForegroundColor = [ConsoleColor]::DarkGray }
        "Gray" { [Console]::ForegroundColor = [ConsoleColor]::Gray }
    }
    Write-Host $Text
    [Console]::ForegroundColor = $prev
}

function Clear-Screen {
    Clear-Host
}

function Info($Text) { Write-TTY "ℹ $Text" "Blue" }
function Success($Text) { Write-TTY "✅ $Text" "Green" }
function Warn($Text) { Write-TTY "⚠ $Text" "Yellow" }
function ErrorMsg($Text) { Write-TTY "❌ $Text" "Red" }

function Pause-Screen {
    $timeout = Get-IdleTimeoutSeconds
    Write-Host ""
    Write-Host "Нажми Enter для продолжения..." -NoNewline
    
    if ($timeout -gt 0) {
        $start = [DateTime]::Now
        while ($true) {
            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                if ($key.Key -eq "Enter") {
                    Write-Host ""
                    return
                }
            }
            if ([DateTime]::Now - $start).TotalSeconds -ge $timeout) {
                if (End-Session "idle") {
                    Clear-Screen
                    return
                }
                # Storage busy - lock deferred, continue waiting
                $start = [DateTime]::Now
            }
            Start-Sleep -Milliseconds 100
        }
    } else {
        Read-Host "" | Out-Null
        Write-Host ""
    }
}

function Ask([ref]$Variable, [string]$Prompt) {
    $timeout = Get-IdleTimeoutSeconds
    Write-Host $Prompt -NoNewline
    
    if ($timeout -gt 0) {
        $input = ""
        $start = [DateTime]::Now
        while ($true) {
            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                if ($key.Key -eq "Enter") {
                    Write-Host ""
                    $Variable.Value = $input
                    return $true
                } elseif ($key.Key -eq "Backspace") {
                    if ($input.Length -gt 0) {
                        $input = $input.Substring(0, $input.Length - 1)
                        Write-Host "`b \b" -NoNewline
                    }
                } elseif ($key.KeyChar -ne "`0") {
                    $input += $key.KeyChar
                    Write-Host $key.KeyChar -NoNewline
                }
            }
            if ([DateTime]::Now - $start).TotalSeconds -ge $timeout) {
                if (End-Session "idle") {
                    Clear-Screen
                    return $false
                }
                $start = [DateTime]::Now
            }
            Start-Sleep -Milliseconds 50
        }
    } else {
        $input = Read-Host ""
        $Variable.Value = $input
        return $true
    }
}

function Header {
    Clear-Screen
    Write-Host "╔══════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║ $($AppName.PadRight(52)) ║" -ForegroundColor Cyan
    Write-Host "╠══════════════════════════════════════════════════════╣" -ForegroundColor Cyan
    Write-Host ("║ {0,-52} ║" -f ("Version: $FlashOSVersion")).PadRight(54) -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
}

# ===========================================================
# KEYBOARD MENU
# ===========================================================

function Show-Menu([string]$Title, [string[]]$Options, [switch]$ShowLockHint) {
    $Selected = 0
    $wasActive = (Test-SessionActive)
    while ($true) {
        Header
        Write-Host $Title -ForegroundColor Cyan
        Write-Host ""
        
        for ($i = 0; $i -lt $Options.Count; $i++) {
            if ($i -eq $Selected) {
                Write-Host "  ❯ $($Options[$i])" -ForegroundColor Cyan
            } else {
                Write-Host "    $($Options[$i])"
            }
        }
        
        Write-Host ""
        $hint = "↑ ↓ выбор   Enter открыть   Esc назад"
        if (Test-SessionActive) {
            $hint += "   L блокировка"
        }
        Write-Host $hint -ForegroundColor DarkGray
        
        $timeout = Get-IdleTimeoutSeconds
        $key = $null
        
        if ($timeout -gt 0) {
            $start = [DateTime]::Now
            while (-not [Console]::KeyAvailable) {
                if ([DateTime]::Now - $start).TotalSeconds -ge $timeout) {
                    if (End-Session "idle") {
                        return 255
                    }
                    $start = [DateTime]::Now
                }
                Start-Sleep -Milliseconds 50
            }
            $key = [Console]::ReadKey($true)
        } else {
            $key = [Console]::ReadKey($true)
        }
        
        if ((-not $wasActive) -and (-not (Test-SessionActive))) {
            return 255
        }
        
        switch ($key.Key) {
            "UpArrow" { $Selected = ($Selected - 1 + $Options.Count) % $Options.Count }
            "DownArrow" { $Selected = ($Selected + 1) % $Options.Count }
            "Enter" { return $Selected }
            "Escape" { return 255 }
            "Q" { return 255 }
            "q" { return 255 }
            "L" { if (Test-SessionActive -and (End-Session "hotkey")) { return 255 } }
            "l" { if (Test-SessionActive -and (End-Session "hotkey")) { return 255 } }
        }
    }
}

# ===========================================================
# DEPENDENCIES
# ===========================================================

function Check-Dependencies {
    $Missing = @()
    $RequiredCommands = @("Get-Disk", "Get-Partition", "Format-Volume", "Invoke-RestMethod", "Get-Volume")
    
    foreach ($Cmd in $RequiredCommands) {
        if (-not (Get-Command $Cmd -ErrorAction SilentlyContinue)) {
            $Missing += $Cmd
        }
    }
    
    # Check for gocryptfs/WinFsp
    $hasGocryptfs = Get-Command "gocryptfs" -ErrorAction SilentlyContinue
    $hasWinFsp = Test-Path "C:\Program Files (x86)\WinFsp\bin\gocryptfs.exe" -or (Test-Path "C:\Program Files\WinFsp\bin\gocryptfs.exe")
    if (-not $hasGocryptfs -and -not $hasWinFsp) {
        $Missing += "gocryptfs (WinFsp)"
    }
    
    if ($Missing.Count -gt 0) {
        Header
        ErrorMsg "Не хватает зависимостей."
        Write-Host ""
        foreach ($M in $Missing) { Write-Host "  - $M" }
        Write-Host ""
        Write-Host "Для Windows требуется PowerShell 5.1+, права администратора и WinFsp с gocryptfs."
        Write-Host "Установите WinFsp: https://winfsp.dev/"
        Write-Host ""
        exit 1
    }
}

# ===========================================================
# USB DETECTION
# ===========================================================

function Get-UsbPartitions {
    $Partitions = @()
    $Disks = Get-Disk -ErrorAction SilentlyContinue | Where-Object { $_.BusType -eq 'USB' }
    foreach ($Disk in $Disks) {
        $Parts = Get-Partition -DiskNumber $Disk.Number -ErrorAction SilentlyContinue
        foreach ($P in $Parts) {
            $Letter = "$($P.DriveLetter)"
            if ($Letter -match '^[A-Za-z]$') {
                $Partitions += "${Letter}:"
            }
        }
    }
    return $Partitions
}

function Is-RemovablePartition([string]$DriveLetter) {
    $vol = Get-Volume -DriveLetter $DriveLetter.TrimEnd(':') -ErrorAction SilentlyContinue
    if (-not $vol) { return $false }
    $disk = Get-Disk -Number $vol.DiskNumber -ErrorAction SilentlyContinue
    return $disk.BusType -eq 'USB'
}

function Mount-Usb([string]$DriveLetter) {
    $Path = "$DriveLetter\"
    if (Test-Path $Path) {
        return $Path
    }
    return ""
}

function Get-UsbDeviceInfo([string]$DriveLetter) {
    $vol = Get-Volume -DriveLetter $DriveLetter.TrimEnd(':') -ErrorAction SilentlyContinue
    if (-not $vol) { return @{} }
    $disk = Get-Disk -Number $vol.DiskNumber -ErrorAction SilentlyContinue
    $part = Get-Partition -DriveLetter $DriveLetter.TrimEnd(':') -ErrorAction SilentlyContinue | Select-Object -First 1
    return @{
        Size = $disk.Size
        Model = $disk.Model
        Firmware = $disk.FirmwareVersion
        SerialNumber = $disk.SerialNumber
        FileSystem = $vol.FileSystem
        FileSystemLabel = $vol.FileSystemLabel
        DriveLetter = $vol.DriveLetter
        PartitionNumber = $part.PartitionNumber
    }
}

# ===========================================================
# FLASHOS DETECTION
# ===========================================================

function Find-FlashOSDevices {
    $global:FoundDevices = @()
    $global:FoundMounts = @()
    $Drives = Get-UsbPartitions
    foreach ($Drive in $Drives) {
        if (-not (Is-RemovablePartition $Drive)) { continue }
        $Mount = Mount-Usb $Drive
        if ($Mount -ne "") {
            $ManifestPath = Join-Path $Mount ".flashos\manifest"
            if (Test-Path $ManifestPath) {
                $global:FoundDevices += $Drive
                $global:FoundMounts += $Mount
            }
        }
    }
}

function Detect-FlashOS {
    $global:Device = ""
    $global:DeviceMount = ""
    $global:FlashOSDir = ""
    
    Find-FlashOSDevices
    $count = $global:FoundDevices.Count
    
    if ($count -eq 0) { return 1 }
    
    if ($count -gt 1) {
        $options = @()
        for ($i = 0; $i -lt $count; $i++) {
            $manifest = Join-Path $global:FoundMounts[$i] ".flashos\manifest"
            $name = Get-ManifestValue $manifest "DEVICE_NAME"
            $version = Get-ManifestValue $manifest "FLASHOS_VERSION"
            $options += "💾 $name | ${global:FoundDevices[$i]} | $version"
        }
        $options += "⬅ Назад"
        $index = Show-Menu "💾 НАЙДЕНО НЕСКОЛЬКО FLASHOS — ВЫБЕРИ" $options
        if ($index -eq 255 -or $index -ge $count) { return 2 }
        $global:Device = $global:FoundDevices[$index]
        $global:DeviceMount = $global:FoundMounts[$index]
    } else {
        $global:Device = $global:FoundDevices[0]
        $global:DeviceMount = $global:FoundMounts[0]
    }
    
    $global:FlashOSDir = Join-Path $global:DeviceMount ".flashos"
    return 0
}

function Get-ManifestValue([string]$ManifestPath, [string]$Key) {
    if (Test-Path $ManifestPath) {
        $Content = Get-Content $ManifestPath
        foreach ($Line in $Content) {
            if ($Line -match "^$Key=(.*)") {
                return $Matches[1]
            }
        }
    }
    return ""
}

function Get-Manifest([string]$Key) {
    $ManifestPath = Join-Path $global:FlashOSDir "manifest"
    return Get-ManifestValue $ManifestPath $Key
}

function Write-Manifest([string]$Name, [string]$Version) {
    $ManifestPath = Join-Path $global:FlashOSDir "manifest"
    $Content = @(
        "FLASHOS_FORMAT=FlashOS",
        "FLASHOS_VERSION=$Version",
        "DEVICE_NAME=$Name",
        "FILESYSTEM=exFAT",
        "SECURITY=gocryptfs",
        "MANAGER=flashos.ps1",
        "GITHUB_REPO=$GitHubRepo",
        "UPDATED=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    )
    $Content | Set-Content -Path $ManifestPath -Force -Encoding UTF8
}

# ===========================================================
# SETTINGS
# ===========================================================

function Get-Setting([string]$Key, [string]$Default = "") {
    $file = Join-Path $global:FlashOSDir "system\settings"
    if (Test-Path $file) {
        $value = Get-ManifestValue $file $Key
        if ($value -ne "") { return $value }
    }
    return $Default
}

function Set-Setting([string]$Key, [string]$Value) {
    $file = Join-Path $global:FlashOSDir "system\settings"
    New-Item -ItemType Directory -Force -Path (Split-Path $file) | Out-Null
    $lines = @()
    if (Test-Path $file) {
        $lines = Get-Content $file | Where-Object { $_ -notmatch "^$Key=" }
    }
    $lines += "$Key=$Value"
    $lines | Set-Content -Path $file -Force -Encoding UTF8
}

function Toggle-Setting([string]$Key, [string]$Default = "1") {
    if ((Get-Setting $Key $Default) -eq "1") {
        Set-Setting $Key "0"
    } else {
        Set-Setting $Key "1"
    }
}

function On-Off([string]$Value) {
    if ($Value -eq "1") { return "вкл" } else { return "выкл" }
}

# ===========================================================
# EVENT LOG
# ===========================================================

function Log-Event([string[]]$Args) {
    if (-not $global:FlashOSDir -or -not (Test-Path $global:FlashOSDir)) { return }
    if ((Get-Setting "LOG_ENABLED" "1") -ne "1") { return }
    $file = Join-Path $global:FlashOSDir "logs\flashos.log"
    New-Item -ItemType Directory -Force -Path (Split-Path $file) | Out-Null
    $entry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | $($Args -join ' ')"
    Add-Content -Path $file -Value $entry -Encoding UTF8
    $size = (Get-Item $file -ErrorAction SilentlyContinue).Length
    if ($size -gt $LogMaxBytes) {
        Move-Item -Path $file -Destination "$file.1" -Force -ErrorAction SilentlyContinue
    }
}

function Count-FailedUnlocks {
    $file = Join-Path $global:FlashOSDir "logs\flashos.log"
    if (-not (Test-Path $file)) { return 0 }
    $content = Get-Content $file
    $failed = 0
    foreach ($line in $content) {
        if ($line -match "UNLOCK_OK") { $failed = 0 }
        elseif ($line -match "UNLOCK_FAIL") { $failed++ }
    }
    return $failed
}

function Show-Log {
    $file = Join-Path $global:FlashOSDir "logs\flashos.log"
    Header
    Write-Host "📜 ЖУРНАЛ СОБЫТИЙ" -ForegroundColor White
    Write-Host ""
    if ((Get-Setting "LOG_ENABLED" "1") -ne "1") {
        Warn "Журнал выключен в настройках."
    }
    if (Test-Path $file) {
        Get-Content $file -Tail 40 | ForEach-Object { Write-Host $_ }
        Write-Host ""
        Write-Host "Показаны последние записи. Файл: $file"
    } else {
        Write-Host "Журнал пуст."
    }
    Pause-Screen
}

# ===========================================================
# FORMAT CONFIRMATION
# ===========================================================

function Confirm-Format([string]$Target) {
    $info = Get-UsbDeviceInfo $Target
    Header
    Write-Host "⚠ ОПАСНАЯ ОПЕРАЦИЯ" -ForegroundColor Red
    Write-Host ""
    Write-Host "Раздел:      $Target"
    Write-Host "Диск:        $($info.Model)"
    Write-Host "Размер:      $([math]::Round($info.Size / 1GB, 1)) GB"
    Write-Host "Модель:      $($info.Model)"
    Write-Host "FS сейчас:   $($info.FileSystem)"
    Write-Host "Label:       $($info.FileSystemLabel)"
    Write-Host ""
    Write-Host "ВСЕ ДАННЫЕ НА ЭТОМ РАЗДЕЛЕ БУДУТ УДАЛЕНЫ." -ForegroundColor Red
    Write-Host ""
    $answer = Read-Host "Введи FORMAT"
    if ($answer -ne "FORMAT") { return $false }
    Write-Host ""
    $answer2 = Read-Host "Введи FLASHOS-YES"
    return $answer2 -eq "FLASHOS-YES"
}

# ===========================================================
# FORMAT USB
# ===========================================================

function Format-Usb([string]$Target, [string]$Label) {
    Header
    Write-Host "💿 FORMAT USB" -ForegroundColor White
    Write-Host ""
    Info "Размонтирую $Target..."
    
    $vol = Get-Volume -DriveLetter $Target.TrimEnd(':') -ErrorAction SilentlyContinue
    if ($vol) {
        Dismount-DiskImage -ImagePath $vol.Path -ErrorAction SilentlyContinue
        $vol | Dismount-Volume -Force -ErrorAction SilentlyContinue
    }
    
    Start-Sleep -Seconds 1
    
    $vol = Get-Volume -DriveLetter $Target.TrimEnd(':') -ErrorAction SilentlyContinue
    if ($vol) {
        ErrorMsg "Не удалось размонтировать $Target."
        return $false
    }
    
    Write-Host ""
    Write-Host "Форматирование в exFAT..."
    Write-Host ""
    
    try {
        Format-Volume -DriveLetter $Target.TrimEnd(':') -FileSystem exFAT -NewFileSystemLabel $Label -Force -Confirm:$false -ErrorAction Stop
        Write-Host ""
        Success "Форматирование завершено."
        return $true
    } catch {
        ErrorMsg "Форматирование не удалось: $($_.Exception.Message)"
        return $false
    }
}

# ===========================================================
# INSTALL FLASHOS
# ===========================================================

function Install-FlashOS {
    Header
    Write-Host "🚀 УСТАНОВКА FLASHOS" -ForegroundColor White
    Write-Host ""
    
    $devices = Get-UsbPartitions
    if ($devices.Count -eq 0) {
        ErrorMsg "USB-флешка не найдена."
        Pause-Screen
        return
    }
    
    $options = @()
    foreach ($dev in $devices) {
        $info = Get-UsbDeviceInfo $dev
        $size = if ($info.Size) { "[math]::Round($info.Size / 1GB, 1) GB" } else { "?" }
        $label = if ($info.FileSystemLabel) { $info.FileSystemLabel } else { "no-label" }
        $fs = if ($info.FileSystem) { $info.FileSystem } else { "unknown" }
        $model = if ($info.Model) { $info.Model } else { "USB" }
        $options += "$dev | $size | $label | $fs | $model"
    }
    $options += "Отмена"
    
    $selected = Show-Menu "💾 ВЫБЕРИ ФЛЕШКУ" $options
    if ($selected -eq 255 -or $selected -ge $devices.Count) { return }
    
    $global:Device = $devices[$selected]
    
    if (-not (Confirm-Format $global:Device)) {
        Warn "Установка отменена."
        Pause-Screen
        return
    }
    
    Header
    $deviceName = ""
    Ask ([ref]$deviceName) "Имя FlashOS [FLASHOS]: "
    if (-not $deviceName) { $deviceName = "FLASHOS" }
    $deviceName = $deviceName.Replace("/", "_").Substring(0, [math]::Min(15, $deviceName.Length))
    if (-not $deviceName) { $deviceName = "FLASHOS" }
    
    if (-not (Format-Usb $global:Device $deviceName)) {
        Pause-Screen
        return
    }
    
    Info "Подключаю новую файловую систему..."
    Start-Sleep -Seconds 2
    $global:DeviceMount = Mount-Usb $global:Device
    if (-not $global:DeviceMount) {
        ErrorMsg "Не удалось подключить флешку."
        Pause-Screen
        return
    }
    
    $global:FlashOSDir = Join-Path $global:DeviceMount ".flashos"
    
    Header
    Write-Host "TRANSFORMATION OF USB" -ForegroundColor Cyan
    Write-Host ""
    
    $steps = @(
        "System",
        "Packages",
        "Recovery",
        "Logs",
        "Vaults",
        "Encrypted storage",
        "Main password",
        "Manifest + Manager"
    )
    
    for ($i = 0; $i -lt $steps.Count; $i++) {
        Write-Host "[$($i+1)/8] $($steps[$i])"
        switch ($i) {
            0 { New-Item -ItemType Directory -Force -Path "$global:FlashOSDir\system" | Out-Null }
            1 { 
                New-Item -ItemType Directory -Force -Path "$global:FlashOSDir\packages\installed" | Out-Null
                New-Item -ItemType Directory -Force -Path "$global:FlashOSDir\packages\cache" | Out-Null
                New-Item -ItemType Directory -Force -Path "$global:FlashOSDir\packages\repository" | Out-Null
            }
            2 { New-Item -ItemType Directory -Force -Path "$global:FlashOSDir\recovery" | Out-Null }
            3 { New-Item -ItemType Directory -Force -Path "$global:FlashOSDir\logs" | Out-Null }
            4 { New-Item -ItemType Directory -Force -Path "$global:FlashOSDir\vaults" | Out-Null }
            5 { New-Item -ItemType Directory -Force -Path "$global:FlashOSDir\data" | Out-Null }
            6 {
                Write-Host ""
                Write-Host "🔐 СОЗДАНИЕ ГЛАВНОГО ПАРОЛЯ FLASHOS" -ForegroundColor Yellow
                Write-Host ""
                Write-Host "Этот пароль понадобится на других компьютерах."
                Write-Host ""
                $dataDir = "$global:FlashOSDir\data"
                if (-not (Invoke-GocryptfsInit $dataDir)) {
                    ErrorMsg "Не удалось создать зашифрованное хранилище."
                    Pause-Screen
                    return
                }
            }
            7 {
                Write-Manifest $deviceName $FlashOSVersion
                Backup-Keys
                Log-Event "INSTALL $FlashOSVersion"
                Copy-Item -Path $PSCommandPath -Destination "$global:FlashOSDir\flashos.ps1" -Force
                $readme = @"
FlashOS
=======

Device: $deviceName
Version: $FlashOSVersion

GitHub:
https://github.com/$GitHubRepo

Use FlashOS Manager.

Do not modify .flashos manually.
"@
                $readme | Set-Content -Path "$global:FlashOSDir\readme.txt" -Force -Encoding UTF8
            }
        }
    }
    
    Write-Host ""
    Success "FlashOS установлен."
    Write-Host "Имя:        $deviceName"
    Write-Host "Версия:     $FlashOSVersion"
    Write-Host "Filesystem: exFAT"
    Write-Host "Security:   gocryptfs"
    Pause-Screen
}

function Invoke-GocryptfsInit([string]$DataDir) {
    $gocryptfs = Get-GocryptfsPath
    if (-not $gocryptfs) { return $false }
    $env:GOCRYPTFS_FASTPASS = "1"
    try {
        & $gocryptfs -init $DataDir
        return $LASTEXITCODE -eq 0
    } catch {
        return $false
    }
}

function Get-GocryptfsPath {
    $paths = @(
        "gocryptfs",
        "C:\Program Files (x86)\WinFsp\bin\gocryptfs.exe",
        "C:\Program Files\WinFsp\bin\gocryptfs.exe",
        "$env:USERPROFILE\scoop\shims\gocryptfs.exe",
        "$env:USERPROFILE\.cargo\bin\gocryptfs.exe"
    )
    foreach ($p in $paths) {
        if (Get-Command $p -ErrorAction SilentlyContinue) { return $p }
    }
    return $null
}

# ===========================================================
# UNLOCK / LOCK
# ===========================================================

function Unlock-FlashOS {
    New-Item -ItemType Directory -Force -Path $global:MainMount | Out-Null
    
    if (Test-Path "$global:MainMount" -PathType Container) {
        $mounted = Get-Volume | Where-Object { $_.MountPoint -eq $global:MainMount }
        if ($mounted) { return $true }
    }
    
    $dataDir = "$global:FlashOSDir\data"
    if (-not (Test-Path "$dataDir\gocryptfs.conf")) {
        ErrorMsg "Главное хранилище FlashOS не найдено."
        if (Test-Path "$global:FlashOSDir\recovery\keys\gocryptfs.conf") {
            Info "Есть копия ключей: 🛟 Recovery → Восстановить ключи из копии."
        }
        return $false
    }
    
    Header
    Write-Host "🔐 FLASHOS LOCKED" -ForegroundColor White
    Write-Host ""
    Write-Host "FlashOS: $(Get-Manifest DEVICE_NAME)"
    Write-Host ""
    Write-Host "Для показа содержимого нужен пароль."
    Write-Host ""
    
    $gocryptfs = Get-GocryptfsPath
    $env:GOCRYPTFS_FASTPASS = "1"
    $exitCode = & $gocryptfs $dataDir $global:MainMount
    
    if ($LASTEXITCODE -eq 0) {
        $failed = Count-FailedUnlocks
        Log-Event "UNLOCK_OK"
        Backup-Keys
        Success "FlashOS разблокирован."
        if ($failed -gt 0) {
            Warn "Неудачных попыток ввода пароля с прошлого входа: $failed"
            Pause-Screen
        }
        return $true
    }
    
    if ($LASTEXITCODE -eq 12) {
        Log-Event "UNLOCK_FAIL"
    } else {
        Log-Event "UNLOCK_ERROR code=$LASTEXITCODE"
    }
    
    ErrorMsg "Неверный пароль или ошибка хранилища."
    return $false
}

function Test-SessionActive {
    $mounted = Get-Volume | Where-Object { $_.MountPoint -eq $global:MainMount }
    return $mounted -ne $null
}

function Get-IdleTimeoutSeconds {
    if (-not (Test-SessionActive)) { return 0 }
    $seconds = Get-Setting "AUTOLOCK_SECONDS" "0"
    if ($seconds -match "^\d{1,6}$") { return [int]$seconds }
    return 0
}

function Unmount-Point([string]$Target, [string]$Mode = "") {
    $vol = Get-Volume | Where-Object { $_.MountPoint -eq $Target }
    if (-not $vol) { return 0 }
    
    try {
        Dismount-Volume -DriveLetter $vol.DriveLetter -Force -ErrorAction Stop
        Start-Sleep -Milliseconds 500
        $vol = Get-Volume | Where-Object { $_.MountPoint -eq $Target }
        if (-not $vol) { return 0 }
    } catch {}
    
    if ($Mode -eq "force") {
        try {
            $vol | Dismount-Volume -Force -ErrorAction Stop
            Start-Sleep -Milliseconds 500
            $vol = Get-Volume | Where-Object { $_.MountPoint -eq $Target }
            if (-not $vol) { return 2 }
        } catch {}
        return 1
    }
    return 1
}

function Remove-MountDir([string]$Target) {
    if (-not (Test-Path $Target -PathType Container)) { return 0 }
    $vol = Get-Volume | Where-Object { $_.MountPoint -eq $Target }
    if ($vol) { return 1 }
    Remove-Item $Target -Force -ErrorAction SilentlyContinue
    return 0
}

function Lock-FlashOS([string]$Mode = "") {
    $result = 0
    $status = Unmount-Point $global:VaultMount $Mode
    if ($status -eq 1) { return 1 }
    if ($status -eq 2) { $result = 2 }
    Remove-MountDir $global:VaultMount
    
    $status = Unmount-Point $global:MainMount $Mode
    if ($status -eq 1) { return 1 }
    if ($status -eq 2) { $result = 2 }
    Remove-MountDir $global:MainMount
    
    $global:CurrentVault = ""
    return $result
}

function End-Session([string]$Reason) {
    $mode = "force"
    if ($Reason -eq "idle") { $mode = "" }
    $status = Lock-FlashOS $mode
    if ($status -eq 1) { return $false }
    
    if ($Reason -eq "idle") {
        Log-Event "AUTOLOCK"
        "idle" | Set-Content -Path $NoticeFile -Force
    } elseif ($status -eq 2) {
        Log-Event "LOCK forced"
        "forced" | Set-Content -Path $NoticeFile -Force
    } else {
        Log-Event "LOCK"
    }
    return $true
}

function Show-LockNotice {
    if (-not (Test-Path $NoticeFile)) { return }
    $notice = Get-Content $NoticeFile | Select-Object -First 1
    Remove-Item $NoticeFile -Force -ErrorAction SilentlyContinue
    Header
    switch ($notice) {
        "idle" {
            Info "🔒 FlashOS заблокирован из-за бездействия."
        }
        "forced" {
            Warn "Хранилище было занято и отключено принудительно."
            Write-Host ""
            Write-Host "Закрой программы, которые работали с файлами FlashOS, прежде чем вынимать флешку."
        }
    }
    Pause-Screen
}

# ===========================================================
# RECOVERY
# ===========================================================

$KeyFiles = @("gocryptfs.conf", "gocryptfs.diriv")

function Backup-Keys {
    $source = "$global:FlashOSDir\data"
    $target = "$global:FlashOSDir\recovery\keys"
    if (-not (Test-Path "$source\gocryptfs.conf")) { return $false }
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    foreach ($name in $KeyFiles) {
        if (-not (Test-Path "$source\$name")) { continue }
        if (Test-Path "$target\$name") {
            if ((Compare-Object (Get-FileHash "$source\$name").Hash (Get-FileHash "$target\$name").Hash) -eq $null) {
                continue
            }
        }
        Copy-Item "$source\$name" "$target\$name.tmp" -Force
        Move-Item "$target\$name.tmp" "$target\$name" -Force
    }
    return $true
}

function Get-KeysBackupState {
    $source = "$global:FlashOSDir\data"
    $target = "$global:FlashOSDir\recovery\keys"
    if (-not (Test-Path "$target\gocryptfs.conf")) { return "missing" }
    foreach ($name in $KeyFiles) {
        if (-not (Test-Path "$target\$name")) { continue }
        if ((Compare-Object (Get-FileHash "$source\$name").Hash (Get-FileHash "$target\$name").Hash) -ne $null) {
            return "differs"
        }
    }
    return "ok"
}

function Get-KeysBackupLabel {
    switch (Get-KeysBackupState) {
        "ok" { return "актуальна" }
        "missing" { return "отсутствует" }
        default { return "отличается от ключей хранилища" }
    }
}

function Show-KeysStatus {
    $target = "$global:FlashOSDir\recovery\keys"
    Header
    Write-Host "🔑 КОПИЯ КЛЮЧЕЙ ШИФРОВАНИЯ" -ForegroundColor White
    Write-Host ""
    Write-Host "Состояние: $(Get-KeysBackupLabel)"
    Write-Host "Папка:     $target"
    if (Test-Path "$target\gocryptfs.conf") {
        Write-Host "Создана:   $(Get-Item "$target\gocryptfs.conf").LastWriteTime"
    }
    Write-Host ""
    Write-Host "Копия обновляется сама после каждого удачного входа и после смены главного пароля."
    Write-Host "Она зашифрована тем же паролем и не позволяет открыть данные без него."
    if ((Get-KeysBackupState) -eq "missing") {
        Write-Host ""
        Info "Копия появится после первого удачного входа."
    }
    Pause-Screen
}

function Restore-Keys {
    $source = "$global:FlashOSDir\recovery\keys"
    $target = "$global:FlashOSDir\data"
    
    Header
    Write-Host "♻ ВОССТАНОВЛЕНИЕ КЛЮЧЕЙ" -ForegroundColor White
    Write-Host ""
    
    if (Test-SessionActive) {
        ErrorMsg "Сначала заблокируй FlashOS."
        Pause-Screen
        return
    }
    
    switch (Get-KeysBackupState) {
        "missing" {
            ErrorMsg "Копия ключей не найдена."
            Pause-Screen
            return
        }
        "ok" {
            Success "Ключи хранилища совпадают с копией."
            Write-Host ""
            Write-Host "Восстановление не требуется."
            Pause-Screen
            return
        }
    }
    
    Warn "Ключи хранилища отличаются от сохранённой копии."
    Write-Host ""
    Write-Host "Так бывает, если файл ключей повреждён или удалён."
    Write-Host "После восстановления будет действовать пароль, который был у FlashOS в момент создания копии."
    Write-Host ""
    Write-Host "Текущие файлы ключей не удаляются — они будут отложены в папку recovery/keys/damaged-*."
    Write-Host ""
    $answer = Read-Host "Введи RESTORE-KEYS"
    if ($answer -ne "RESTORE-KEYS") {
        Warn "Восстановление отменено."
        Pause-Screen
        return
    }
    
    $damaged = "$source\damaged-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    New-Item -ItemType Directory -Force -Path $damaged | Out-Null
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    
    foreach ($name in $KeyFiles) {
        if (-not (Test-Path "$target\$name")) { continue }
        if (Test-Path "$source\$name") {
            Move-Item "$source\$name" "$damaged\$name" -Force
        }
        Copy-Item "$source\$name" "$target\$name" -Force
    }
    
    Remove-Item $damaged -Force -ErrorAction SilentlyContinue
    
    Log-Event "KEYS_RESTORED"
    Success "Ключи восстановлены из копии."
    Write-Host ""
    Write-Host "Теперь попробуй открыть FlashOS своим паролем."
    Pause-Screen
}

function Fsck-Storage {
    Header
    Write-Host "🧪 ПРОВЕРКА ШИФРОВАННОГО ХРАНИЛИЩА" -ForegroundColor White
    Write-Host ""
    
    if (-not (Test-Path "$global:FlashOSDir\data\gocryptfs.conf")) {
        ErrorMsg "Главное хранилище FlashOS не найдено."
        Pause-Screen
        return
    }
    
    Write-Host "gocryptfs прочитает все файлы и проверит их целостность."
    Write-Host "Данные не изменяются. Понадобится главный пароль."
    Write-Host ""
    
    $gocryptfs = Get-GocryptfsPath
    $exitCode = & $gocryptfs -fsck "$global:FlashOSDir\data"
    
    Write-Host ""
    Log-Event "FSCK code=$LASTEXITCODE"
    
    switch ($LASTEXITCODE) {
        0 { Success "Повреждений не найдено." }
        26 { ErrorMsg "Найдены повреждённые файлы (список выше)." }
        12 { ErrorMsg "Неверный пароль — проверка не выполнена." }
        default { ErrorMsg "Проверка не выполнена (код gocryptfs: $LASTEXITCODE)." }
    }
    Pause-Screen
}

function Get-ScriptVersion([string]$File) {
    if (Test-Path $File) {
        $content = Get-Content $File
        foreach ($line in $content) {
            if ($line -match 'FLASHOS_VERSION="([^"]+)"') {
                return $Matches[1]
            }
        }
    }
    return ""
}

function Rollback-Manager {
    $backupDir = "$global:FlashOSDir\recovery\manager-backups"
    $files = Get-ChildItem "$backupDir\flashos-*.ps1" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
    if ($files.Count -eq 0) {
        Header
        Warn "Сохранённых версий менеджера нет."
        Write-Host ""
        Write-Host "Они появляются после обновления FlashOS."
        Pause-Screen
        return
    }
    
    $options = @()
    foreach ($f in $files) {
        $ver = Get-ScriptVersion $f.FullName
        $options += "${ver:-?}  ($($f.Name))"
    }
    $options += "⬅ Назад"
    
    $index = Show-Menu "⏪ ОТКАТ МЕНЕДЖЕРА — ВЫБЕРИ ВЕРСИЮ" $options
    if ($index -eq 255 -or $index -ge $files.Count) { return }
    
    $file = $files[$index]
    $version = Get-ScriptVersion $file.FullName
    
    Header
    if (-not $version -or -not (Test-ScriptSyntax $file.FullName)) {
        ErrorMsg "Сохранённый файл повреждён — откат отменён."
        Pause-Screen
        return
    }
    
    $currentVersion = Get-Manifest FLASHOS_VERSION
    $confirm = Show-Menu "⏪ ОТКАТ ${currentVersion:-?} → $version" @("⏪ Откатить менеджер", "❌ Отмена")
    if ($confirm -ne 0) { return }
    
    Header
    if (Test-Path "$global:FlashOSDir\flashos.ps1") {
        Copy-Item "$global:FlashOSDir\flashos.ps1" "$backupDir\flashos-${currentVersion:-unknown}-$(Get-Date -Format 'yyyyMMdd-HHmmss').ps1" -Force
    }
    
    Copy-Item $file.FullName "$global:FlashOSDir\flashos.ps1.tmp" -Force
    Move-Item "$global:FlashOSDir\flashos.ps1.tmp" "$global:FlashOSDir\flashos.ps1" -Force
    
    Write-Manifest (Get-Manifest DEVICE_NAME) $version
    Remove-Item "$global:FlashOSDir\system\update-check" -Force -ErrorAction SilentlyContinue
    
    Log-Event "ROLLBACK ${currentVersion:-?} -> $version"
    Success "Менеджер на флешке возвращён к версии $version."
    Write-Host ""
    Write-Host "Данные, Vault и Backup не изменялись."
    Pause-Screen
    
    $restart = Show-Menu "ROLLBACK COMPLETE" @("🔄 Запустить версию $version", "✅ Остаться")
    if ($restart -eq 0) {
        & pwsh "$global:FlashOSDir\flashos.ps1"
        exit
    }
}

function Test-ScriptSyntax([string]$File) {
    try {
        [System.Management.Automation.PSParser]::Tokenize((Get-Content $File -Raw), [ref]$null)
        return $true
    } catch {
        return $false
    }
}

function Recovery-Menu {
    while ($true) {
        $selected = Show-Menu "🛟 RECOVERY" @(
            "🔑 Копия ключей: $(Get-KeysBackupLabel)",
            "♻ Восстановить ключи из копии",
            "🧪 Проверить шифрованное хранилище (fsck)",
            "⏪ Откатить менеджер на прошлую версию",
            "⬅ Назад"
        )
        switch ($selected) {
            0 { Show-KeysStatus }
            1 { Restore-Keys }
            2 { Fsck-Storage }
            3 { Rollback-Manager }
            4 { return }
            255 { return }
        }
    }
}

# ===========================================================
# FILES
# ===========================================================

function Test-PathContainsStorage([string]$Path) {
    $path = Resolve-Path $Path -ErrorAction SilentlyContinue
    if (-not $path) { return $false }
    $path = $path.Path
    if ($path -eq "/") { return $true }
    $guarded = @($RuntimeBase, $global:MainMount, $global:FlashOSDir)
    foreach ($g in $guarded) {
        if ($g -and $path.StartsWith($g)) { return $true }
    }
    return $false
}

function Test-HasFreeSpace([string]$Source) {
    $need = (Get-ChildItem $Source -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    $available = (Get-PSDrive -Name ($global:DeviceMount[0]).ToString()).Free
    if ($need -ge $available) {
        ErrorMsg "Недостаточно места: нужно $([math]::Round($need/1MB,1)) MB, свободно $([math]::Round($available/1MB,1)) MB."
        return $false
    }
    return $true
}

function Files-Search {
    $query = ""
    Header
    Write-Host "🔎 ПОИСК ПО ИМЕНИ" -ForegroundColor White
    Write-Host ""
    Ask ([ref]$query) "Что искать (часть имени): "
    if (-not $query) { return }
    
    $results = Get-ChildItem $global:MainMount -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "*$query*" -and $_.FullName -notlike "$global:MainMount\vaults*" } |
        Select-Object -ExpandProperty FullName |
        ForEach-Object { $_.Substring($global:MainMount.Length + 1) } |
        Sort-Object
    
    Write-Host ""
    if (-not $results) {
        Warn "Ничего не найдено."
        Pause-Screen
        return
    }
    
    $count = $results.Count
    $results | Select-Object -First 200 | ForEach-Object { Write-Host $_ }
    Write-Host ""
    if ($count -gt 200) {
        Write-Host "Найдено: $count (показаны первые 200)"
    } else {
        Write-Host "Найдено: $count"
    }
    Pause-Screen
}

function Files-Import {
    $source = ""
    Header
    Write-Host "📥 ИМПОРТ В ХРАНИЛИЩЕ" -ForegroundColor White
    Write-Host ""
    Ask ([ref]$source) "Путь к файлу или папке: "
    if (-not $source) { return }
    
    $source = Resolve-Path $source -ErrorAction SilentlyContinue
    if (-not $source) {
        ErrorMsg "Файл или папка не найдены."
        Pause-Screen
        return
    }
    $source = $source.Path
    
    if (Test-PathContainsStorage $source) {
        ErrorMsg "Этот путь нельзя импортировать: он содержит саму флешку FlashOS."
        Pause-Screen
        return
    }
    
    $target = Join-Path $global:MainMount (Split-Path $source -Leaf)
    if (Test-Path $target) {
        ErrorMsg "В хранилище уже есть «$(Split-Path $source -Leaf)»."
        Pause-Screen
        return
    }
    
    if (-not (Test-HasFreeSpace $source)) {
        Pause-Screen
        return
    }
    
    Write-Host ""
    Write-Host "📦 Копирую и шифрую..."
    try {
        Copy-Item $source $target -Recurse -Force -ErrorAction Stop
        Success "Импорт завершён."
        Write-Host ""
        Write-Host "Оригинал остался на месте — удали его сам, если он больше не нужен."
        Log-Event "IMPORT"
    } catch {
        ErrorMsg "Ошибка копирования: $($_.Exception.Message)"
        Log-Event "IMPORT_FAIL"
    }
    Pause-Screen
}

function Files-Usage {
    Header
    Write-Host "📊 ЧТО ЗАНИМАЕТ МЕСТО" -ForegroundColor White
    Write-Host ""
    
    $items = Get-ChildItem $global:MainMount -Force -ErrorAction SilentlyContinue
    foreach ($item in $items) {
        $size = (Get-ChildItem $item.FullName -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
        Write-Host "$([math]::Round($size/1MB,1)) MB  $($item.Name)"
    }
    Write-Host ""
    Get-PSDrive -Name ($global:DeviceMount[0]).ToString() | Select-Object Used,Free,Provider | Format-Table -AutoSize | Out-Host
    Pause-Screen
}

function Files-Menu {
    while ($true) {
        if (-not (Test-SessionActive)) { return }
        $selected = Show-Menu "📁 FILES" @(
            "📂 Открыть хранилище",
            "📄 Показать содержимое",
            "🔎 Поиск по имени",
            "📥 Импорт файла или папки",
            "📊 Что занимает место",
            "⬅ Назад"
        )
        switch ($selected) {
            0 { 
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = "explorer.exe"
                $psi.Arguments = $global:MainMount
                $psi.UseShellExecute = $true
                [System.Diagnostics.Process]::Start($psi) | Out-Null
            }
            1 {
                Header
                Write-Host "📁 FLASHOS STORAGE" -ForegroundColor White
                Write-Host ""
                Get-ChildItem $global:MainMount -Recurse -Depth 2 -Force -ErrorAction SilentlyContinue | ForEach-Object { Write-Host $_.FullName }
                Pause-Screen
            }
            2 { Files-Search }
            3 { Files-Import }
            4 { Files-Usage }
            5 { return }
            255 { return }
        }
    }
}

# ===========================================================
# VAULT
# ===========================================================

function List-Vaults {
    $vaultDir = "$global:MainMount\vaults"
    if (-not (Test-Path $vaultDir)) { return @() }
    Get-ChildItem "$vaultDir\*.vault" -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.BaseName }
}

function Close-Vault {
    $status = Unmount-Point $global:VaultMount "force"
    if ($status -ne 1) { Remove-MountDir $global:VaultMount }
    return $status
}

function Create-Vault {
    Header
    Write-Host "🔐 CREATE VAULT" -ForegroundColor White
    Write-Host ""
    
    $name = ""
    Ask ([ref]$name) "Название Vault: "
    $name = $name.Replace(" ", "_").Replace("/", "_")
    while ($name.StartsWith(".")) { $name = $name.Substring(1) }
    if (-not $name) { return }
    
    $cipher = "$global:MainMount\vaults\$name.vault"
    New-Item -ItemType Directory -Force -Path "$global:MainMount\vaults" | Out-Null
    
    if (Test-Path $cipher) {
        ErrorMsg "Такой Vault уже существует."
        Pause-Screen
        return
    }
    
    New-Item -ItemType Directory -Force -Path $cipher | Out-Null
    
    Write-Host ""
    Write-Host "Создай пароль Vault."
    Write-Host ""
    
    $gocryptfs = Get-GocryptfsPath
    $env:GOCRYPTFS_FASTPASS = "1"
    $exitCode = & $gocryptfs -init $cipher
    
    if ($LASTEXITCODE -ne 0) {
        ErrorMsg "Не удалось создать Vault."
        Remove-Item $cipher -Recurse -Force
        Pause-Screen
        return
    }
    
    Log-Event "VAULT_CREATE"
    Success "Vault создан."
    Write-Host ""
    
    $source = ""
    Ask ([ref]$source) "Папка для переноса (Enter = пропустить): "
    if ($source) {
        $source = Resolve-Path $source -ErrorAction SilentlyContinue
        if (-not $source -or -not (Test-Path $source -PathType Container)) {
            ErrorMsg "Папка не найдена."
            Pause-Screen
            return
        }
        $source = $source.Path
        
        if (Test-PathContainsStorage $source) {
            ErrorMsg "Эту папку нельзя копировать: она содержит саму флешку FlashOS."
            Pause-Screen
            return
        }
        
        if (-not (Test-HasFreeSpace $source)) {
            Pause-Screen
            return
        }
        
        Close-Vault
        if ($LASTEXITCODE -eq 1) {
            ErrorMsg "Не удалось закрыть ранее открытый Vault: он занят."
            Pause-Screen
            return
        }
        
        New-Item -ItemType Directory -Force -Path $global:VaultMount | Out-Null
        $env:GOCRYPTFS_FASTPASS = "1"
        $exitCode = & $gocryptfs $cipher $global:VaultMount
        if ($LASTEXITCODE -eq 0) {
            Write-Host "📦 Копирую данные..."
            try {
                Copy-Item $source "$global:VaultMount\" -Recurse -Force -ErrorAction Stop
                Success "Папка скопирована и зашифрована."
            } catch {
                ErrorMsg "Ошибка копирования."
            }
            Close-Vault
            if ($LASTEXITCODE -eq 1) {
                Warn "Vault занят и остался открытым."
            }
        } else {
            ErrorMsg "Не удалось открыть Vault."
            Remove-MountDir $global:VaultMount
        }
    }
    Pause-Screen
}

function Open-Vault {
    $vaults = List-Vaults
    if ($vaults.Count -eq 0) {
        Warn "Vault пока нет."
        Pause-Screen
        return
    }
    
    $options = @()
    foreach ($v in $vaults) { $options += "🔐 $v" }
    $options += "⬅ Назад"
    
    $selected = Show-Menu "🔐 VAULTS" $options
    if ($selected -eq 255 -or $selected -ge $vaults.Count) { return }
    
    $selectedVault = $vaults[$selected]
    $cipher = "$global:MainMount\vaults\$selectedVault.vault"
    
    Close-Vault
    if ($LASTEXITCODE -eq 1) {
        ErrorMsg "Не удалось закрыть ранее открытый Vault: он занят."
        Pause-Screen
        return
    }
    
    New-Item -ItemType Directory -Force -Path $global:VaultMount | Out-Null
    Header
    Write-Host "🔐 Vault: $selectedVault"
    Write-Host ""
    
    $gocryptfs = Get-GocryptfsPath
    $env:GOCRYPTFS_FASTPASS = "1"
    $exitCode = & $gocryptfs $cipher $global:VaultMount
    
    if ($LASTEXITCODE -ne 0) {
        if ($LASTEXITCODE -eq 12) { Log-Event "VAULT_OPEN_FAIL" }
        else { Log-Event "VAULT_OPEN_ERROR code=$LASTEXITCODE" }
        ErrorMsg "Неверный пароль или повреждённый Vault."
        Remove-MountDir $global:VaultMount
        Pause-Screen
        return
    }
    
    Log-Event "VAULT_OPEN"
    Success "Vault открыт."
    $global:CurrentVault = $selectedVault
    
    while ($true) {
        if (-not (Test-Path $global:VaultMount -PathType Container)) { return }
        $action = Show-Menu "🔐 VAULT: $selectedVault" @(
            "📂 Открыть",
            "📄 Показать содержимое",
            "🔒 Закрыть Vault"
        )
        switch ($action) {
            0 {
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = "explorer.exe"
                $psi.Arguments = $global:VaultMount
                $psi.UseShellExecute = $true
                [System.Diagnostics.Process]::Start($psi) | Out-Null
            }
            1 {
                Header
                Get-ChildItem $global:VaultMount -Recurse -Depth 2 -Force -ErrorAction SilentlyContinue | ForEach-Object { Write-Host $_.FullName }
                Pause-Screen
            }
            2 {
                if (-not (Test-Path $global:VaultMount -PathType Container)) { return }
                $status = Close-Vault
                switch ($status) {
                    0 { Success "Vault закрыт." }
                    2 { Warn "Vault был занят и отключён принудительно."; Write-Host "Закрой программы, которые работали с его файлами." }
                    default { ErrorMsg "Не удалось закрыть Vault: он занят."; Pause-Screen; continue }
                }
                Pause-Screen
                return
            }
            255 {
                if (-not (Test-Path $global:VaultMount -PathType Container)) { return }
                $status = Close-Vault
                switch ($status) {
                    0 { Success "Vault закрыт." }
                    2 { Warn "Vault был занят и отключён принудительно."; Write-Host "Закрой программы, которые работали с его файлами." }
                    default { ErrorMsg "Не удалось закрыть Vault: он занят."; Pause-Screen; continue }
                }
                Pause-Screen
                return
            }
        }
    }
}

function Manage-Vault {
    $vaults = List-Vaults
    if ($vaults.Count -eq 0) {
        Warn "Vault пока нет."
        Pause-Screen
        return
    }
    
    $index = Show-Menu "🛠 УПРАВЛЕНИЕ VAULT — ВЫБЕРИ" ($vaults + "⬅ Назад")
    if ($index -eq 255 -or $index -ge $vaults.Count) { return }
    
    $name = $vaults[$index]
    $cipher = "$global:MainMount\vaults\$name.vault"
    
    while ($true) {
        if (-not (Test-SessionActive)) { return }
        $action = Show-Menu "🛠 VAULT: $name" @(
            "✏ Переименовать",
            "🔑 Сменить пароль",
            "📊 Размер",
            "🗑 Удалить Vault",
            "⬅ Назад"
        )
        switch ($action) {
            0 {
                Header
                $newName = ""
                Ask ([ref]$newName) "Новое название Vault: "
                $newName = $newName.Replace(" ", "_").Replace("/", "_")
                while ($newName.StartsWith(".")) { $newName = $newName.Substring(1) }
                if (-not $newName) { continue }
                if (Test-Path "$global:MainMount\vaults\$newName.vault") {
                    ErrorMsg "Такой Vault уже существует."
                } elseif (Move-Item $cipher "$global:MainMount\vaults\$newName.vault" -Force) {
                    $name = $newName
                    $cipher = "$global:MainMount\vaults\$name.vault"
                    Log-Event "VAULT_RENAME"
                    Success "Vault переименован в $name."
                } else {
                    ErrorMsg "Не удалось переименовать Vault."
                }
                Pause-Screen
            }
            1 {
                Header
                Write-Host "🔑 Смена пароля Vault: $name"
                Write-Host ""
                Write-Host "Сначала введи текущий пароль, затем новый."
                Write-Host ""
                $gocryptfs = Get-GocryptfsPath
                $env:GOCRYPTFS_FASTPASS = "1"
                $exitCode = & $gocryptfs -passwd $cipher
                if ($LASTEXITCODE -eq 0) {
                    Sync
                    Log-Event "VAULT_PASSWD"
                    Success "Пароль Vault изменён."
                } else {
                    ErrorMsg "Пароль не изменён."
                }
                Pause-Screen
            }
            2 {
                Header
                Write-Host "📊 Vault: $name"
                Write-Host ""
                $size = (Get-ChildItem $cipher -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
                $files = (Get-ChildItem $cipher -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer -and $_.Name -notmatch '^(gocryptfs\.conf|gocryptfs\.diriv|\.name)$' }).Count
                Write-Host "Размер: $([math]::Round($size/1MB,1)) MB"
                Write-Host "Файлов: $files"
                Pause-Screen
            }
            3 {
                Header
                Write-Host "🗑 УДАЛЕНИЕ VAULT: $name" -ForegroundColor Red
                Write-Host ""
                Write-Host "Все файлы внутри Vault будут удалены без возможности восстановления."
                Write-Host ""
                $typed = ""
                Ask ([ref]$typed) "Для подтверждения введи название Vault: "
                if ($typed -ne $name) {
                    Warn "Удаление отменено."
                    Pause-Screen
                    continue
                }
                if (Remove-Item $cipher -Recurse -Force -ErrorAction SilentlyContinue) {
                    Sync
                    Log-Event "VAULT_DELETE"
                    Success "Vault удалён."
                    Pause-Screen
                    return
                }
                ErrorMsg "Не удалось удалить Vault."
                Pause-Screen
            }
            4 { return }
            255 { return }
        }
    }
}

function Vault-Menu {
    while ($true) {
        if (-not (Test-SessionActive)) { return }
        $selected = Show-Menu "🔐 VAULT MODE" @(
            "Создать Vault",
            "Открыть Vault",
            "Управление Vault",
            "Назад"
        )
        switch ($selected) {
            0 { Create-Vault }
            1 { Open-Vault }
            2 { Manage-Vault }
            3 { return }
            255 { return }
        }
    }
}

# ===========================================================
# BACKUP
# ===========================================================

function List-Backups {
    $backupDir = "$global:MainMount\Backups"
    if (-not (Test-Path $backupDir)) { return @() }
    Get-ChildItem $backupDir -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | ForEach-Object { $_.Name }
}

function Choose-Backup([string]$Title) {
    $backups = List-Backups
    if ($backups.Count -eq 0) {
        Header
        Warn "Backup пока нет."
        Pause-Screen
        return $false
    }
    $options = $backups + "⬅ Назад"
    $index = Show-Menu $Title $options
    if ($index -eq 255 -or $index -ge $backups.Count) { return $false }
    $global:ChosenItem = $backups[$index]
    return $true
}

function Write-BackupChecksums([string]$Source, [string]$Destination) {
    $parent = Split-Path $Source
    $base = Split-Path $Source -Leaf
    $checksums = @()
    Get-ChildItem $Source -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
        $hash = (Get-FileHash $_.FullName -Algorithm SHA256).Hash
        $rel = $_.FullName.Substring($parent.Length + 1)
        $checksums += "$hash  $rel"
    }
    $checksums | Set-Content -Path "$Destination\$ChecksumFile" -Force -Encoding UTF8
}

function Verify-Checksums([string]$Dir) {
    $checksumFile = "$Dir\$ChecksumFile"
    if (-not (Test-Path $checksumFile)) { return 2 }
    if ((Get-Item $checksumFile).Length -eq 0) { return 0 }
    
    $currentDir = Get-Location
    Set-Location $Dir
    try {
        $content = Get-Content $checksumFile
        $allOk = $true
        foreach ($line in $content) {
            if ($line -match "^([a-f0-9]{64})\s+(.+)$") {
                $expectedHash = $Matches[1]
                $file = $Matches[2]
                if (Test-Path $file) {
                    $actualHash = (Get-FileHash $file -Algorithm SHA256).Hash
                    if ($actualHash -ne $expectedHash) {
                        Write-Host "FAILED: $file" -ForegroundColor Red
                        $allOk = $false
                    }
                } else {
                    Write-Host "MISSING: $file" -ForegroundColor Red
                    $allOk = $false
                }
            }
        }
        Set-Location $currentDir
        return if ($allOk) { 0 } else { 1 }
    } catch {
        Set-Location $currentDir
        return 1
    }
}

function Backup-Create {
    $source = ""
    Header
    Write-Host "💾 СОЗДАНИЕ BACKUP" -ForegroundColor White
    Write-Host ""
    Ask ([ref]$source) "Путь к папке: "
    if (-not $source) { return }
    
    $source = Resolve-Path $source -ErrorAction SilentlyContinue
    if (-not $source -or -not (Test-Path $source -PathType Container)) {
        ErrorMsg "Папка не найдена."
        Pause-Screen
        return
    }
    $source = $source.Path
    
    if (Test-PathContainsStorage $source -or $source.StartsWith("$global:MainMount\Backups\")) {
        ErrorMsg "Эту папку нельзя копировать: она содержит саму флешку FlashOS или её Backup."
        Pause-Screen
        return
    }
    
    if (-not (Test-HasFreeSpace $source)) {
        Pause-Screen
        return
    }
    
    $timestamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
    $destination = "$global:MainMount\Backups\$timestamp"
    New-Item -ItemType Directory -Force -Path $destination | Out-Null
    
    Write-Host ""
    Write-Host "📦 Создание Backup..."
    $copied = $true
    try {
        Copy-Item "$source\*" $destination -Recurse -Force -ErrorAction Stop
    } catch { $copied = $false }
    
    Write-Host "🧮 Проверка копии по SHA-256..."
    Write-BackupChecksums $source $destination
    $verified = Verify-Checksums $destination
    
    Write-Host ""
    switch ($verified) {
        1 {
            ErrorMsg "Backup неполный: перечисленные выше файлы не совпадают с оригиналом."
            Log-Event "BACKUP_FAIL"
        }
        2 {
            ErrorMsg "Ошибка Backup: копию не удалось проверить."
            Log-Event "BACKUP_FAIL"
        }
        default {
            if (-not $copied) {
                Warn "Все файлы скопированы и проверены, но cp сообщил об ошибках."
                Write-Host "Обычно это ссылки или права доступа, которые exFAT не хранит."
                Log-Event "BACKUP_CREATE"
            } else {
                Success "Backup создан и проверен: $timestamp"
                Log-Event "BACKUP_CREATE"
            }
        }
    }
    Pause-Screen
}

function Backup-List {
    Header
    Write-Host "💾 СПИСОК BACKUP" -ForegroundColor White
    Write-Host ""
    $found = $false
    foreach ($backup in List-Backups) {
        $found = $true
        $dir = "$global:MainMount\Backups\$backup"
        $mark = if (Test-Path "$dir\$ChecksumFile") { "SHA-256" } else { "без контрольных сумм" }
        $size = (Get-ChildItem $dir -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
        Write-Host "$backup  $([math]::Round($size/1MB,1)) MB  $mark"
        Get-ChildItem $dir -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne $ChecksumFile } | ForEach-Object { Write-Host "    └ $($_.Name)" }
    }
    if (-not $found) { Write-Host "Backup пока нет." }
    Pause-Screen
}

function Backup-Verify {
    if (-not (Choose-Backup "🧮 ПРОВЕРИТЬ BACKUP")) { return }
    $name = $global:ChosenItem
    Header
    Write-Host "🧮 Проверка Backup $name по SHA-256..."
    Write-Host ""
    $result = Verify-Checksums "$global:MainMount\Backups\$name"
    switch ($result) {
        0 {
            Success "Backup цел: все файлы совпадают с контрольными суммами."
            Log-Event "BACKUP_VERIFY ok"
        }
        2 { Warn "У этого Backup нет контрольных сумм (он создан старой версией)." }
        default {
            Write-Host ""
            ErrorMsg "Backup повреждён: перечисленные выше файлы не совпадают."
            Log-Event "BACKUP_VERIFY failed"
        }
    }
    Pause-Screen
}

function Backup-Restore {
    if (-not (Choose-Backup "♻ ВОССТАНОВИТЬ BACKUP")) { return }
    $name = $global:ChosenItem
    $source = "$global:MainMount\Backups\$name"
    $defaultTarget = "$env:USERPROFILE\FlashOS-Restore"
    $target = ""
    Header
    Write-Host "♻ Восстановление Backup $name"
    Write-Host ""
    Write-Host "Файлы будут скопированы в новую папку <куда>/$name."
    Write-Host "Существующие файлы на компьютере не перезаписываются."
    Write-Host ""
    Ask ([ref]$target) "Куда восстановить [$defaultTarget]: "
    if (-not $target) { $target = $defaultTarget }
    $target = Resolve-Path $target -ErrorAction SilentlyContinue
    if (-not $target) {
        New-Item -ItemType Directory -Force -Path $defaultTarget | Out-Null
        $target = $defaultTarget
    } else { $target = $target.Path }
    $target = Join-Path $target $name
    
    if ($target.StartsWith("$global:MainMount\Backups\")) {
        ErrorMsg "Нельзя восстанавливать Backup внутрь папки Backups."
        Pause-Screen
        return
    }
    
    if (Test-Path $target) {
        ErrorMsg "Папка $target уже существует."
        Pause-Screen
        return
    }
    
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    
    Write-Host ""
    Write-Host "📦 Копирую..."
    $copied = $true
    try {
        Copy-Item "$source\*" $target -Recurse -Force -ErrorAction Stop
    } catch { $copied = $false }
    
    $verified = Verify-Checksums $target
    switch ($verified) {
        0 {
            Success "Backup восстановлен и проверен."
            Log-Event "BACKUP_RESTORE"
        }
        2 {
            if ($copied) {
                Success "Backup восстановлен (без проверки: у него нет контрольных сумм)."
                Log-Event "BACKUP_RESTORE"
            } else {
                ErrorMsg "Ошибка копирования."
                Log-Event "BACKUP_RESTORE_FAIL"
            }
        }
        default {
            ErrorMsg "Восстановленные файлы не совпадают с контрольными суммами."
            Log-Event "BACKUP_RESTORE_FAIL"
        }
    }
    Remove-Item "$target\$ChecksumFile" -Force -ErrorAction SilentlyContinue
    Write-Host ""
    Write-Host "Папка: $target"
    Pause-Screen
}

function Backup-Delete {
    if (-not (Choose-Backup "🗑 УДАЛИТЬ BACKUP")) { return }
    $name = $global:ChosenItem
    $dir = "$global:MainMount\Backups\$name"
    Header
    Write-Host "🗑 УДАЛЕНИЕ BACKUP: $name" -ForegroundColor Red
    Write-Host ""
    Write-Host "Размер: $((Get-ChildItem $dir -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1MB) MB"
    Write-Host ""
    $answer = Read-Host "Введи DELETE"
    if ($answer -ne "DELETE") {
        Warn "Удаление отменено."
        Pause-Screen
        return
    }
    if (Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue) {
        Sync
        Log-Event "BACKUP_DELETE"
        Success "Backup удалён."
    } else {
        ErrorMsg "Не удалось удалить Backup."
    }
    Pause-Screen
}

function Backup-Menu {
    New-Item -ItemType Directory -Force -Path "$global:MainMount\Backups" | Out-Null
    while ($true) {
        if (-not (Test-SessionActive)) { return }
        $selected = Show-Menu "💾 BACKUP" @(
            "Создать Backup",
            "Показать Backup",
            "Проверить Backup (SHA-256)",
            "Восстановить Backup",
            "Удалить Backup",
            "Назад"
        )
        switch ($selected) {
            0 { Backup-Create }
            1 { Backup-List }
            2 { Backup-Verify }
            3 { Backup-Restore }
            4 { Backup-Delete }
            5 { return }
            255 { return }
        }
    }
}

# ===========================================================
# DIAGNOSTICS
# ===========================================================

function Diagnostics-Menu {
    while ($true) {
        if (-not (Test-SessionActive)) { return }
        $selected = Show-Menu "🩺 DIAGNOSTICS" @(
            "Информация об устройстве",
            "Проверить структуру FlashOS",
            "Показать место",
            "📜 Журнал событий",
            "🧪 Проверить шифрованное хранилище (fsck)",
            "Назад"
        )
        switch ($selected) {
            0 {
                Header
                $info = Get-UsbDeviceInfo $global:Device
                Write-Host "Device:      $global:Device"
                Write-Host "Mount:       $global:DeviceMount"
                Write-Host ""
                Write-Host "Size:        $([math]::Round($info.Size/1GB,1)) GB"
                Write-Host "Filesystem:  $($info.FileSystem)"
                Write-Host "Label:       $($info.FileSystemLabel)"
                Write-Host "Model:       $($info.Model)"
                Write-Host ""
                Write-Host "FlashOS:     $(Get-Manifest DEVICE_NAME)"
                Write-Host "Version:     $(Get-Manifest FLASHOS_VERSION)"
                Write-Host "Security:    $(Get-Manifest SECURITY)"
                Pause-Screen
            }
            1 {
                Header
                $required = @(
                    "$global:FlashOSDir\manifest",
                    "$global:FlashOSDir\system",
                    "$global:FlashOSDir\packages",
                    "$global:FlashOSDir\recovery",
                    "$global:FlashOSDir\logs",
                    "$global:FlashOSDir\vaults",
                    "$global:FlashOSDir\data",
                    "$global:FlashOSDir\flashos.ps1"
                )
                foreach ($p in $required) {
                    if (Test-Path $p) { Success $p } else { ErrorMsg "Missing: $p" }
                }
                Pause-Screen
            }
            2 {
                Header
                Get-PSDrive -Name ($global:DeviceMount[0]).ToString() | Select-Object Used,Free,Provider | Format-Table -AutoSize | Out-Host
                Write-Host ""
                $size = (Get-ChildItem $global:FlashOSDir -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
                Write-Host "FlashOS dir: $([math]::Round($size/1MB,1)) MB"
                Pause-Screen
            }
            3 { Show-Log }
            4 { Fsck-Storage }
            5 { return }
            255 { return }
        }
    }
}

# ===========================================================
# SETTINGS
# ===========================================================

function Get-AutolockLabel {
    $seconds = Get-Setting "AUTOLOCK_SECONDS" "0"
    if (-not ($seconds -match "^\d{1,6}$")) { $seconds = 0 }
    $seconds = [int]$seconds
    if ($seconds -eq 0) { return "выкл" }
    if ($seconds % 60 -eq 0) { return "$($seconds/60) мин" }
    return "$seconds сек"
}

function Autolock-Settings {
    $selected = Show-Menu "⏱ АВТОБЛОКИРОВКА ПРИ БЕЗДЕЙСТВИИ" @(
        "Выключена",
        "1 минута",
        "5 минут",
        "10 минут",
        "30 минут",
        "⬅ Назад"
    )
    switch ($selected) {
        0 { Set-Setting "AUTOLOCK_SECONDS" "0" }
        1 { Set-Setting "AUTOLOCK_SECONDS" "60" }
        2 { Set-Setting "AUTOLOCK_SECONDS" "300" }
        3 { Set-Setting "AUTOLOCK_SECONDS" "600" }
        4 { Set-Setting "AUTOLOCK_SECONDS" "1800" }
    }
}

function Change-MainPassword {
    Header
    Write-Host "🔑 СМЕНА ГЛАВНОГО ПАРОЛЯ FLASHOS" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Сначала введи текущий пароль, затем новый."
    Write-Host "Файлы не перешифровываются — это занимает секунды."
    Write-Host ""
    $gocryptfs = Get-GocryptfsPath
    $env:GOCRYPTFS_FASTPASS = "1"
    $exitCode = & $gocryptfs -passwd "$global:FlashOSDir\data"
    if ($LASTEXITCODE -eq 0) {
        Backup-Keys
        Sync
        Log-Event "PASSWD_MAIN"
        Success "Главный пароль изменён, копия ключей обновлена."
    } else {
        ErrorMsg "Пароль не изменён."
    }
    Pause-Screen
}

function Settings-Menu {
    while ($true) {
        if (-not (Test-SessionActive)) { return }
        $selected = Show-Menu "⚙ SETTINGS" @(
            "Изменить имя FlashOS",
            "Показать manifest",
            "⏱ Автоблокировка: $(Get-AutolockLabel)",
            "🔑 Сменить главный пароль",
            "📜 Журнал событий: $(On-Off (Get-Setting "LOG_ENABLED" "1"))",
            "🧹 Очистить журнал",
            "🔔 Проверка обновлений при запуске: $(On-Off (Get-Setting "UPDATE_CHECK" "1"))",
            "Назад"
        )
        switch ($selected) {
            0 {
                Header
                $newName = ""
                Ask ([ref]$newName) "Новое имя: "
                if ($newName) {
                    $newName = $newName.Replace("/", "_").Substring(0, [math]::Min(15, $newName.Length))
                    Write-Manifest $newName (Get-Manifest FLASHOS_VERSION)
                    Success "Имя изменено на $newName."
                }
                Pause-Screen
            }
            1 {
                Header
                Get-Content "$global:FlashOSDir\manifest" | ForEach-Object { Write-Host $_ }
                Pause-Screen
            }
            2 { Autolock-Settings }
            3 { Change-MainPassword }
            4 {
                if ((Get-Setting "LOG_ENABLED" "1") -eq "1") { Log-Event "LOG_DISABLED" }
                Toggle-Setting "LOG_ENABLED" "1"
            }
            5 {
                Remove-Item "$global:FlashOSDir\logs\flashos.log" -Force -ErrorAction SilentlyContinue
                Remove-Item "$global:FlashOSDir\logs\flashos.log.1" -Force -ErrorAction SilentlyContinue
                Log-Event "LOG_CLEARED"
                Header
                Success "Журнал очищен."
                Pause-Screen
            }
            6 { Toggle-Setting "UPDATE_CHECK" "1" }
            7 { return }
            255 { return }
        }
    }
}

# ===========================================================
# GITHUB RELEASE HELPERS
# ===========================================================

function Get-LatestReleaseJson {
    try {
        $headers = @{
            "Accept" = "application/vnd.github+json"
            "X-GitHub-Api-Version" = "2022-11-28"
        }
        return Invoke-RestMethod -Uri $GitHubApi -Headers $headers -TimeoutSec 30 -ErrorAction Stop
    } catch {
        return $null
    }
}

function Get-ReleaseTag($Json) { return $Json.tag_name }
function Get-ReleaseName($Json) { return $Json.name }
function Get-ReleaseDate($Json) { return $Json.published_at }
function Get-ReleaseUrl($Json) { return $Json.html_url }
function Get-ReleaseBody($Json) { return $Json.body }

function Get-TagScriptUrl([string]$Tag) {
    return "https://raw.githubusercontent.com/$GitHubRepo/$Tag/flashos.ps1"
}

function Get-ScriptVersionFromFile([string]$File) {
    if (Test-Path $File) {
        $content = Get-Content $File
        foreach ($line in $content) {
            if ($line -match 'FLASHOS_VERSION="([^"]+)"') { return $Matches[1] }
        }
    }
    return ""
}

function Version-Is-Newer([string]$Remote, [string]$Local) {
    if ($Remote -eq $Local) { return $false }
    $newest = @($Remote, $Local) | Sort-Object { [Version]::new($_) } | Select-Object -Last 1
    return $newest -eq $Remote
}

function Show-ReleaseNotes($Json) {
    $name = Get-ReleaseName $Json
    $tag = Get-ReleaseTag $Json
    $published = Get-ReleaseDate $Json
    $url = Get-ReleaseUrl $Json
    $body = Get-ReleaseBody $Json
    
    Header
    Write-Host "📋 GITHUB LATEST RELEASE" -ForegroundColor White
    Write-Host ""
    Write-Host "Release:   $name"
    Write-Host "Tag:       $tag"
    if ($published) { Write-Host "Published: $published" }
    Write-Host ""
    Write-Host "Что нового:" -ForegroundColor White
    Write-Host ""
    if ($body) { Write-Host $body } else { Write-Host "Описание релиза отсутствует." }
    Write-Host ""
    if ($url) { Write-Host "GitHub: $url" }
    Pause-Screen
}

function Check-Update-Background {
    if (-not $global:FlashOSDir -or -not (Test-Path $global:FlashOSDir)) { return }
    if ((Get-Setting "UPDATE_CHECK" "1") -ne "1") { return }
    $cache = "$global:FlashOSDir\system\update-check"
    $now = [DateTimeOffset]::Now.ToUnixTimeSeconds()
    $last = 0
    if (Test-Path $cache) {
        $content = Get-Content $cache
        foreach ($line in $content) {
            if ($line -match "CHECKED=(\d+)") { $last = [long]$Matches[1] }
        }
    }
    if ($now - $last -lt $UpdateCheckInterval) { return }
    
    Start-Job -ScriptBlock {
        param($GitHubApi, $GitHubRepo, $cache, $now)
        try {
            $headers = @{
                "Accept" = "application/vnd.github+json"
                "X-GitHub-Api-Version" = "2022-11-28"
            }
            $json = Invoke-RestMethod -Uri $GitHubApi -Headers $headers -TimeoutSec 8
            $tag = $json.tag_name
            if (-not $tag) { return }
            $scriptUrl = "https://raw.githubusercontent.com/$GitHubRepo/$tag/flashos.ps1"
            $tempFile = "$env:TEMP\flashos-update-check.ps1"
            Invoke-WebRequest -Uri $scriptUrl -OutFile $tempFile -TimeoutSec 15
            $version = Get-ScriptVersionFromFile $tempFile
            Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
            if (-not $version) { return }
            New-Item -ItemType Directory -Force -Path (Split-Path $cache) | Out-Null
            "CHECKED=$now`nLATEST_VERSION=$version" | Set-Content -Path "$cache.tmp" -Force
            Move-Item "$cache.tmp" $cache -Force
        } catch {}
    } -ArgumentList $GitHubApi, $GitHubRepo, $cache, $now | Out-Null
}

function Get-AvailableUpdate {
    $cache = "$global:FlashOSDir\system\update-check"
    if (-not (Test-Path $cache)) { return "" }
    $content = Get-Content $cache
    $latest = ""
    foreach ($line in $content) {
        if ($line -match "LATEST_VERSION=([0-9.]+)") { $latest = $Matches[1] }
    }
    if (-not ($latest -match "^\d+(\.\d+)*$")) { return "" }
    $installed = Get-Manifest FLASHOS_VERSION
    if (-not $installed) { $installed = $FlashOSVersion }
    if (Version-Is-Newer $latest $installed) { return $latest }
    return ""
}

# ===========================================================
# UPDATE FLASHOS
# ===========================================================

function Update-FlashOS {
    Header
    Write-Host "🔄 FLASHOS UPDATE" -ForegroundColor White
    Write-Host ""
    Info "Проверяю GitHub Latest Release..."
    
    $json = Get-LatestReleaseJson
    if (-not $json) {
        ErrorMsg "Не удалось получить Latest Release."
        Pause-Screen
        return
    }
    
    $tag = Get-ReleaseTag $json
    $releaseName = Get-ReleaseName $json
    $releaseUrl = Get-ReleaseUrl $json
    
    if (-not $tag) {
        ErrorMsg "GitHub не вернул tag_name."
        Pause-Screen
        return
    }
    
    $latestUrl = Get-TagScriptUrl $tag
    $localVersion = Get-Manifest FLASHOS_VERSION
    if (-not $localVersion) { $localVersion = $FlashOSVersion }
    
    Write-Host "Installed: $localVersion"
    Write-Host "Release:   $releaseName"
    Write-Host "Tag:       $tag"
    Write-Host ""
    
    $tempFile = "$RuntimeBase\flashos-update.ps1"
    Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
    
    Write-Host "⬇ Скачиваю flashos.ps1 из Latest Release..."
    Write-Host ""
    try {
        Invoke-WebRequest -Uri $latestUrl -OutFile $tempFile -TimeoutSec 60
    } catch {
        ErrorMsg "Не удалось скачать flashos.ps1: $($_.Exception.Message)"
        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
        Pause-Screen
        return
    }
    
    Write-Host ""
    Write-Host "🧪 Проверка PowerShell syntax..."
    if (-not (Test-ScriptSyntax $tempFile)) {
        ErrorMsg "Скачанный файл содержит ошибку PowerShell syntax."
        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
        Pause-Screen
        return
    }
    
    $remoteVersion = Get-ScriptVersionFromFile $tempFile
    if (-not $remoteVersion) {
        ErrorMsg "Не найден FLASHOS_VERSION в скачанном файле."
        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
        Pause-Screen
        return
    }
    
    Write-Host ""
    Write-Host "Installed version: $localVersion"
    Write-Host "Release version:   $remoteVersion"
    Write-Host ""
    
    if ($localVersion -eq $remoteVersion) {
        Success "FlashOS уже последней версии."
        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
        $choice = Show-Menu "LATEST RELEASE" @("📋 Посмотреть изменения", "⬅ Назад")
        if ($choice -eq 0) { Show-ReleaseNotes $json }
        return
    }
    
    if (-not (Version-Is-Newer $remoteVersion $localVersion)) {
        Warn "Версия из Latest Release не новее установленной."
        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
        Pause-Screen
        return
    }
    
    Write-Host "⚡ Доступно обновление: $localVersion → $remoteVersion" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Обновляется только FlashOS Manager."
    Write-Host "Пользовательские данные НЕ заменяются."
    Write-Host "Vault НЕ заменяются."
    Write-Host "Backup НЕ заменяются."
    Write-Host ""
    
    $action = Show-Menu "🔄 UPDATE $localVersion → $remoteVersion" @(
        "🚀 Установить обновление",
        "📋 Посмотреть изменения",
        "❌ Отмена"
    )
    
    switch ($action) {
        1 { Show-ReleaseNotes $json; Remove-Item $tempFile -Force -ErrorAction SilentlyContinue; return }
        2 { Remove-Item $tempFile -Force -ErrorAction SilentlyContinue; return }
    }
    
    # Backup old manager
    $backupDir = "$global:FlashOSDir\recovery\manager-backups"
    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    if (Test-Path "$global:FlashOSDir\flashos.ps1") {
        Copy-Item "$global:FlashOSDir\flashos.ps1" "$backupDir\flashos-${localVersion}-$(Get-Date -Format 'yyyyMMdd-HHmmss').ps1" -Force
    }
    
    # Install new manager
    Move-Item $tempFile "$global:FlashOSDir\flashos.ps1" -Force
    Write-Manifest (Get-Manifest DEVICE_NAME) $remoteVersion
    Remove-Item "$global:FlashOSDir\system\update-check" -Force -ErrorAction SilentlyContinue
    Log-Event "UPDATE $localVersion -> $remoteVersion"
    Sync
    
    Write-Host ""
    Success "FlashOS обновлён до $remoteVersion."
    if ($releaseUrl) { Write-Host "Release: $releaseUrl" }
    Write-Host ""
    Write-Host "Старый manager сохранён в recovery."
    Pause-Screen
    
    $restart = Show-Menu "UPDATE COMPLETE" @("🔄 Запустить новую версию", "✅ Остаться")
    if ($restart -eq 0) {
        & pwsh "$global:FlashOSDir\flashos.ps1"
        exit
    }
}

# ===========================================================
# REMOVE FLASHOS
# ===========================================================

function Remove-FlashOS {
    Header
    Write-Host "🗑 REMOVE FLASHOS" -ForegroundColor Red
    Write-Host ""
    Write-Host "Устройство: $global:Device"
    Write-Host ""
    Write-Host "Будут удалены:"
    Write-Host "  • FlashOS"
    Write-Host "  • зашифрованное хранилище"
    Write-Host "  • Vault"
    Write-Host "  • Backup"
    Write-Host ""
    Write-Host "ВСЕ ДАННЫЕ БУДУТ УДАЛЕНЫ." -ForegroundColor Red
    Write-Host ""
    
    $first = Read-Host "Введи REMOVE FLASHOS"
    if ($first -ne "REMOVE FLASHOS") {
        Warn "Удаление отменено."
        Pause-Screen
        return
    }
    
    $second = Read-Host "Введи DELETE-ALL"
    if ($second -ne "DELETE-ALL") {
        Warn "Удаление отменено."
        Pause-Screen
        return
    }
    
    Lock-FlashOS
    if (-not (Format-Usb $global:Device "USB")) {
        Pause-Screen
        return
    }
    
    Success "FlashOS удалён."
    Success "Флешка очищена и отформатирована в exFAT."
    Pause-Screen
}

# ===========================================================
# INFO
# ===========================================================

function Show-FlashOSInfo {
    Header
    Write-Host "ℹ FLASHOS INFORMATION" -ForegroundColor White
    Write-Host ""
    Write-Host "Device:       $global:Device"
    Write-Host "Name:         $(Get-Manifest DEVICE_NAME)"
    Write-Host "FlashOS:      $(Get-Manifest FLASHOS_VERSION)"
    Write-Host "Filesystem:   $(Get-Manifest FILESYSTEM)"
    Write-Host "Security:     $(Get-Manifest SECURITY)"
    Write-Host "Manager:      $(Get-Manifest MANAGER)"
    Write-Host ""
    Write-Host "GitHub:       https://github.com/$GitHubRepo"
    Write-Host ""
    Get-PSDrive -Name ($global:DeviceMount[0]).ToString() | Select-Object Used,Free,Provider | Format-Table -AutoSize | Out-Host
    Pause-Screen
}

# ===========================================================
# SAFE EJECT
# ===========================================================

function Eject-Device([string]$Dev) {
    Sync
    $vol = Get-Volume -DriveLetter $Dev.TrimEnd(':') -ErrorAction SilentlyContinue
    if ($vol) {
        try {
            Dismount-Volume -DriveLetter $vol.DriveLetter -Force -ErrorAction Stop
        } catch {
            ErrorMsg "Не удалось размонтировать $Dev: флешка занята."
            Write-Host ""
            Write-Host "Закрой программы и окна, в которых открыты файлы с флешки, и повтори. Пока НЕ вынимай флешку."
            return $false
        }
    }
    
    $disk = Get-Disk | Where-Object { $_.Number -eq $vol.DiskNumber }
    if ($disk) {
        try {
            $disk | Set-Disk -IsOffline $true -ErrorAction Stop
            Success "Питание флешки отключено — её можно вынимать."
        } catch {
            Success "Флешка размонтирована — её можно вынимать."
        }
    } else {
        Success "Флешка размонтирована — её можно вынимать."
    }
    return $true
}

function Eject-FlashOS {
    Header
    Write-Host "⏏ БЕЗОПАСНОЕ ИЗВЛЕЧЕНИЕ" -ForegroundColor White
    Write-Host ""
    
    if (-not (Lock-FlashOS)) {
        ErrorMsg "Хранилище занято: какая-то программа работает с файлами FlashOS."
        Write-Host ""
        Write-Host "Закрой её и повтори. Пока НЕ вынимай флешку."
        Pause-Screen
        return $false
    }
    
    Log-Event "EJECT"
    
    if ($PWD.Path.StartsWith($global:DeviceMount)) {
        Set-Location /
    }
    
    $self = $PSCommandPath
    if ($self.StartsWith($global:DeviceMount)) {
        $copy = "$RuntimeBase\flashos-eject.ps1"
        Copy-Item $self $copy -Force
        & pwsh $copy -Eject $global:Device
        exit
    }
    
    Eject-Device $global:Device
    Pause-Screen
    return $true
}

# ===========================================================
# MAIN WORK MENU
# ===========================================================

function Work-Menu {
    if (-not (Unlock-FlashOS)) {
        Pause-Screen
        return
    }
    
    while ($true) {
        if (-not (Test-SessionActive)) { return }
        $name = Get-Manifest DEVICE_NAME
        $selected = Show-Menu "💾 FLASHOS: ${name:-FLASHOS}" @(
            "📁 Files",
            "🔐 Vault Mode",
            "💾 Backup",
            "🩺 Diagnostics",
            "⚙ Settings",
            "🔄 Update FlashOS",
            "🔒 Lock FlashOS"
        )
        switch ($selected) {
            0 { Files-Menu }
            1 { Vault-Menu }
            2 { Backup-Menu }
            3 { Diagnostics-Menu }
            4 { Settings-Menu }
            5 { Update-FlashOS }
            6 {
                if (Test-SessionActive -and -not (End-Session "manual")) {
                    Header
                    ErrorMsg "Не удалось заблокировать FlashOS: хранилище занято."
                    Pause-Screen
                    continue
                }
                return
            }
            255 {
                if (Test-SessionActive -and -not (End-Session "manual")) {
                    Header
                    ErrorMsg "Не удалось заблокировать FlashOS: хранилище занято."
                    Pause-Screen
                    continue
                }
                return
            }
        }
    }
}

# ===========================================================
# FLASHOS FOUND MENU
# ===========================================================

function FlashOS-Found-Menu {
    while ($true) {
        Show-LockNotice
        $name = Get-Manifest DEVICE_NAME
        $installedVersion = Get-Manifest FLASHOS_VERSION
        $title = "💾 FLASHOS: ${name:-FLASHOS} [$installedVersion]"
        $update = Get-AvailableUpdate
        if ($update) { $title += "   ⚡ доступно обновление $update" }
        
        $selected = Show-Menu $title @(
            "🚀 Работать с FlashOS",
            "🔄 Обновить до Latest Release",
            "📋 Посмотреть изменения Latest Release",
            "🛟 Recovery",
            "🗑 Удалить FlashOS",
            "ℹ Информация",
            "⏏ Безопасно извлечь",
            "🔌 Сменить USB",
            "❌ Выход"
        )
        
        switch ($selected) {
            0 { Work-Menu }
            1 { Update-FlashOS }
            2 {
                $json = Get-LatestReleaseJson
                if ($json) { Show-ReleaseNotes $json }
                else { ErrorMsg "Не удалось получить Latest Release."; Pause-Screen }
            }
            3 { Recovery-Menu }
            4 { Remove-FlashOS; return }
            5 { Show-FlashOSInfo }
            6 { if (Eject-FlashOS) { return } }
            7 {
                Header
                Write-Host "🔌 Подключи другую флешку FlashOS."
                Write-Host ""
                Write-Host "Если подключено несколько — после поиска можно будет выбрать."
                Pause-Screen
                return
            }
            8 { return }
            255 { return }
        }
    }
}

# ===========================================================
# CLEANUP
# ===========================================================

function Cleanup {
    $wasActive = (Test-SessionActive)
    Lock-FlashOS "force"
    $status = $LASTEXITCODE
    
    if ($wasActive -and $status -ne 1) { Log-Event "LOCK" }
    
    if ($status -eq 2) {
        Warn "Хранилище было занято и отключено принудительно: закрой программы, работавшие с файлами FlashOS."
    } elseif ($status -eq 1) {
        Warn "Хранилище FlashOS занято и осталось открытым: $global:MainMount"
    }
    
    Remove-Item $NoticeFile -Force -ErrorAction SilentlyContinue
    Remove-Item "$RuntimeBase\flashos-eject.ps1" -Force -ErrorAction SilentlyContinue
    Remove-Item "$RuntimeBase\flashos-update.ps1" -Force -ErrorAction SilentlyContinue
    Remove-Item $RuntimeBase -Recurse -Force -ErrorAction SilentlyContinue
}

# ===========================================================
# COMMAND LINE
# ===========================================================

function Show-Usage {
    @"
$AppName $FlashOSVersion

Использование:
  flashos.ps1 [параметры]

Без параметров запускается интерактивный менеджер.

Параметры:
  -h, --help       показать эту справку
  -V, --version    показать версию
      --status     найти подключённые флешки FlashOS и показать их состояние
                   (код возврата 0 — FlashOS найден, 1 — нет)
      --lock       немедленно заблокировать открытое хранилище и Vault
                   (можно вызвать из другого терминала или повесить на клавишу)
      --doctor     проверить зависимости и показать команду установки
      --no-color   без цветов
      --eject <DEVICE>  безопасное извлечение (внутренний параметр)

Клавиши в меню:
  ↑ ↓ выбор, Enter открыть, Esc или Q назад, L заблокировать FlashOS

https://github.com/$GitHubRepo
"@ | Write-Host
}

function Cli-Status {
    $unlockedSource = ""
    if (Test-SessionActive) {
        $vol = Get-Volume | Where-Object { $_.MountPoint -eq $global:MainMount }
        if ($vol) { $unlockedSource = "$($global:FlashOSDir)\data" }
    }
    
    $found = $false
    $any = $false
    $drives = Get-UsbPartitions
    foreach ($dev in $drives) {
        $any = $true
        $vol = Get-Volume -DriveLetter $dev.TrimEnd(':') -ErrorAction SilentlyContinue
        Write-Host $dev
        if (-not $vol) {
            Write-Host "  Состояние: не смонтирована"
            continue
        }
        Write-Host "  Mount:     $($vol.DriveLetter):\"
        $manifest = "$($vol.DriveLetter):\.flashos\manifest"
        if (-not (Test-Path $manifest)) {
            Write-Host "  FlashOS:   не установлен"
            continue
        }
        $found = $true
        Write-Host "  FlashOS:   $(Get-ManifestValue $manifest DEVICE_NAME)"
        Write-Host "  Версия:    $(Get-ManifestValue $manifest FLASHOS_VERSION)"
        if ($unlockedSource -eq "$($vol.DriveLetter):\.flashos\data") {
            Write-Host "  Состояние: разблокирован"
        } else {
            Write-Host "  Состояние: заблокирован"
        }
    }
    
    if (-not $any) { Write-Host "USB-накопители не найдены." }
    return if ($found) { 0 } else { 1 }
}

function Cli-Lock {
    if (-not (Test-SessionActive) -and -not (Test-Path $global:VaultMount -PathType Container)) {
        Write-Host "Открытых хранилищ FlashOS нет."
        return 0
    }
    Lock-FlashOS "force"
    switch ($LASTEXITCODE) {
        0 { Write-Host "FlashOS заблокирован." }
        2 { 
            Write-Host "FlashOS заблокирован принудительно: хранилище было занято."
            Write-Host "Закрой программы, которые работали с его файлами, прежде чем вынимать флешку."
        }
        default { 
            Write-Host "Не удалось заблокировать FlashOS: хранилище занято." 
            return 1 
        }
    }
    return 0
}

function Cli-Doctor {
    Write-Host "$AppName $FlashOSVersion"
    Write-Host ""
    $missing = 0
    $required = @("Get-Disk", "Get-Partition", "Format-Volume", "Invoke-RestMethod", "Get-Volume")
    foreach ($cmd in $required) {
        if (Get-Command $cmd -ErrorAction SilentlyContinue) {
            Write-Host "  [ok]  $cmd"
        } else {
            Write-Host "  [нет] $cmd"
            $missing = 1
        }
    }
    $gocryptfs = Get-GocryptfsPath
    if ($gocryptfs) { Write-Host "  [ok]  gocryptfs" } else { Write-Host "  [нет] gocryptfs (WinFsp)"; $missing = 1 }
    Write-Host ""
    if ($missing -eq 0) {
        Write-Host "Все зависимости на месте."
        return 0
    }
    Write-Host "Не хватает зависимостей. Установка:"
    Write-Host "Установите WinFsp: https://winfsp.dev/"
    return 1
}

function Handle-Cli {
    $action = ""
    while ($args.Count -gt 0) {
        switch ($args[0]) {
            "-h" { $action = "help"; break }
            "--help" { $action = "help"; break }
            "-V" { $action = "version"; break }
            "--version" { $action = "version"; break }
            "--status" { $action = "status"; break }
            "--lock" { $action = "lock"; break }
            "--doctor" { $action = "doctor"; break }
            "--no-color" { break }
            "--eject" { 
                $global:EjectOnStart = $args[1]
                $args = $args[1..($args.Count-1)]
                break 
            }
            default { 
                Write-Host "Неизвестный параметр: $($args[0])"
                Show-Usage
                exit 2
            }
        }
        $args = $args[1..($args.Count-1)]
    }
    
    if (-not $action) { return 0 }
    
    $status = 0
    switch ($action) {
        "help" { Show-Usage }
        "version" { Write-Host "$AppName $FlashOSVersion" }
        "status" { $status = Cli-Status }
        "lock" { $status = Cli-Lock }
        "doctor" { $status = Cli-Doctor }
    }
    
    Remove-Item $RuntimeBase -Recurse -Force -ErrorAction SilentlyContinue
    exit $status
}

# ===========================================================
# STARTUP
# ===========================================================

function Main {
    Handle-Cli $args
    
    Check-Dependencies
    
    if ($global:EjectOnStart) {
        Header
        Write-Host "⏏ БЕЗОПАСНОЕ ИЗВЛЕЧЕНИЕ" -ForegroundColor White
        Write-Host ""
        $vol = Get-Volume -DriveLetter $global:EjectOnStart.TrimEnd(':') -ErrorAction SilentlyContinue
        if ($vol -and (Get-Disk -Number $vol.DiskNumber).BusType -eq 'USB') {
            Eject-Device $global:EjectOnStart
        } else {
            ErrorMsg "$global:EjectOnStart — не раздел USB-накопителя."
        }
        Pause-Screen
        return
    }
    
    while ($true) {
        Header
        Write-Host "🔍 Поиск USB-устройств..." -ForegroundColor Cyan
        Start-Sleep -Milliseconds 500
        
        $status = Detect-FlashOS
        if ($status -eq 0) {
            Write-Host ""
            Success "Флешка найдена."
            Write-Host "Device:  $global:Device"
            Write-Host "Name:    $(Get-Manifest DEVICE_NAME)"
            Write-Host "Version: $(Get-Manifest FLASHOS_VERSION)"
            Write-Host ""
            Success "FlashOS найден."
            Start-Sleep -Milliseconds 600
            Check-Update-Background
            FlashOS-Found-Menu
            return
        }
        
        Write-Host ""
        if ($status -eq 2) {
            $notFoundTitle = "FLASHOS НЕ ВЫБРАН"
        } else {
            $notFoundTitle = "FLASHOS NOT FOUND"
            Warn "FlashOS на подключённой флешке не найден."
            Write-Host ""
        }
        
        $selected = Show-Menu $notFoundTitle @(
            "🚀 Установить FlashOS",
            "🔄 Повторить поиск",
            "❌ Выход"
        )
        
        switch ($selected) {
            0 { Install-FlashOS }
            1 { continue }
            2 { return }
            255 { return }
        }
    }
}

# Register cleanup on exit
$null = Register-ObjectEvent -InputObject ([System.AppDomain]::CurrentDomain) -EventName DomainUnload -Action { Cleanup }
$null = Register-ObjectEvent -InputObject ([System.AppDomain]::CurrentDomain) -EventName ProcessExit -Action { Cleanup }

# Handle Ctrl+C
[Console]::CancelKeyPress.Add({ exit 130 })

Main