#!/usr/bin/env pwsh

# ===========================================================
#                    FLASHOS MANAGER (PowerShell)
# ===========================================================
#
# Version: 0.3.1-ps
#
# GitHub:
# https://github.com/1xcoding/flashos
#
# SINGLE FILE EDITION (PowerShell for Windows)
#
# ===========================================================
# FEATURES
# ===========================================================
#
# - USB detection (Windows WMI/Get-PhysicalDisk)
# - FlashOS detection
# - FlashOS installation
# - exFAT formatting (Format-Volume)
# - Main encrypted storage (gocryptfs equivalent via WinFsp/EncFS or placeholder)
# - Main FlashOS password
# - Vault Mode
# - Vault passwords
# - Backup
# - Diagnostics
# - Settings
# - GitHub Latest Release updater
# - Release notes
# - FlashOS removal
# - Keyboard interface (Console.ReadKey)
#
# ===========================================================

$AppName = "FlashOS Manager"
$FlashOSVersion = "0.3.1-ps"
$GitHubRepo = "1xcoding/flashos"
$GitHubApi = "https://api.github.com/repos/$GitHubRepo/releases/latest"

$RuntimeBase = "$env:TEMP\flashos-$([int]$env:USERNAME.GetHashCode())"
$MainMount = "$RuntimeBase\main"
$VaultMount = "$RuntimeBase\vault"

$Device = ""
$DeviceMount = ""
$FlashOSDir = ""
$CurrentVault = ""

New-Item -ItemType Directory -Force -Path $RuntimeBase | Out-Null

# ===========================================================
# COLORS & UI HELPERS
# ===========================================================

function Write-TTY([string]$Text, [string]$Color = "Cyan") {
    # PowerShell console colors
    $prev = [Console]::ForegroundColor
    switch ($Color) {
        "Red" { [Console]::ForegroundColor = [ConsoleColor]::Red }
        "Green" { [Console]::ForegroundColor = [ConsoleColor]::Green }
        "Yellow" { [Console]::ForegroundColor = [ConsoleColor]::Yellow }
        "Blue" { [Console]::ForegroundColor = [ConsoleColor]::Blue }
        "Magenta" { [Console]::ForegroundColor = [ConsoleColor]::Magenta }
        "Cyan" { [Console]::ForegroundColor = [ConsoleColor]::Cyan }
        "White" { [Console]::ForegroundColor = [ConsoleColor]::White }
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
    Write-Host ""
    Read-Host "Нажми Enter для продолжения..."
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

function Show-Menu([string]$Title, [string[]]$Options) {
    $Selected = 0
    while ($true) {
        Header
        Write-Host "$Title" -ForegroundColor Cyan
        Write-Host ""
        
        for ($i = 0; $i -lt $Options.Count; $i++) {
            if ($i -eq $Selected) {
                Write-Host "  ❯ $($Options[$i])" -ForegroundColor Cyan
            } else {
                Write-Host "    $($Options[$i])"
            }
        }
        
        Write-Host ""
        Write-Host "↑ ↓ выбор   Enter открыть   Esc назад" -ForegroundColor DarkGray
        
        $Key = [Console]::ReadKey($true)
        
        switch ($Key.Key) {
            "UpArrow" { $Selected = ($Selected - 1 + $Options.Count) % $Options.Count }
            "DownArrow" { $Selected = ($Selected + 1) % $Options.Count }
            "Enter" { return $Selected }
            "Escape" { return -1 }
            "Q" { return -1 }
            "q" { return -1 }
        }
    }
}

# ===========================================================
# DEPENDENCIES
# ===========================================================

function Check-Dependencies {
    $Missing = @()
    # Windows PowerShell equivalents (mostly built-in, but checking for external tools)
    $RequiredCommands = @("Get-PhysicalDisk", "Format-Volume", "Invoke-RestMethod")
    
    foreach ($Cmd in $RequiredCommands) {
        if (-not (Get-Command $Cmd -ErrorAction SilentlyContinue)) {
            $Missing += $Cmd
        }
    }
    
    if ($Missing.Count -gt 0) {
        Header
        ErrorMsg "Не хватает зависимостей."
        Write-Host ""
        foreach ($M in $Missing) { Write-Host "  - $M" }
        Write-Host ""
        Write-Host "Для Windows требуется PowerShell 5.1+ и права администратора."
        Write-Host ""
        exit 1
    }
}

# ===========================================================
# USB DETECTION
# ===========================================================

function Get-UsbPartitions {
    # Get removable disks and their partitions
    $Disks = Get-PhysicalDisk -CanPool $false | Where-Object { $_.MediaType -eq 'Removable' -or $_.MediaType -eq 'USB' }
    $Partitions = @()
    foreach ($Disk in $Disks) {
        $Parts = Get-Partition -DiskNumber $Disk.Number
        foreach ($P in $Parts) {
            if ($P.DriveLetter) {
                $Partitions += $P.DriveLetter + ":"
            }
        }
    }
    return $Partitions
}

function Mount-Usb($DriveLetter) {
    # On Windows, drives are auto-mounted. Return the path.
    $Path = "$DriveLetter\"
    if (Test-Path $Path) {
        return $Path
    }
    return ""
}

# ===========================================================
# FLASHOS DETECTION
# ===========================================================

function Detect-FlashOS {
    $global:Device = ""
    $global:DeviceMount = ""
    $global:FlashOSDir = ""
    
    $Drives = Get-UsbPartitions
    foreach ($Drive in $Drives) {
        $Mount = Mount-Usb $Drive
        if ($Mount -ne "") {
            $ManifestPath = Join-Path $Mount ".flashos\manifest"
            if (Test-Path $ManifestPath) {
                $global:Device = $Drive
                $global:DeviceMount = $Mount
                $global:FlashOSDir = Join-Path $Mount ".flashos"
                return $true
            }
        }
    }
    return $false
}

# ===========================================================
# MANIFEST
# ===========================================================

function Get-Manifest([string]$Key) {
    $ManifestPath = Join-Path $global:FlashOSDir "manifest"
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
    $Content | Set-Content -Path $ManifestPath -Force
}

# ===========================================================
# MAIN WORK MENU
# ===========================================================

function Work-Menu {
    while ($true) {
        $Name = Get-Manifest "DEVICE_NAME"
        $Selected = Show-Menu "💾 FLASHOS: $($Name -ne "" ? $Name : "FLASHOS")" @(
            "📁 Files",
            "🔐 Vault Mode",
            "💾 Backup",
            "🩺 Diagnostics",
            "⚙ Settings",
            "🔄 Update FlashOS",
            "🔒 Lock FlashOS"
        )
        
        switch ($Selected) {
            0 { Write-Host "Files menu (placeholder)" ; Pause-Screen }
            1 { Write-Host "Vault menu (placeholder)" ; Pause-Screen }
            2 { Write-Host "Backup menu (placeholder)" ; Pause-Screen }
            3 { Write-Host "Diagnostics menu (placeholder)" ; Pause-Screen }
            4 { Write-Host "Settings menu (placeholder)" ; Pause-Screen }
            5 { Update-FlashOS }
            -1, 6 { return }
        }
    }
}

# ===========================================================
# FLASHOS FOUND MENU
# ===========================================================

function FlashOS-Found-Menu {
    while ($true) {
        $Name = Get-Manifest "DEVICE_NAME"
        $InstalledVersion = Get-Manifest "FLASHOS_VERSION"
        $Selected = Show-Menu "💾 FLASHOS: $($Name -ne "" ? $Name : "FLASHOS") [$InstalledVersion]" @(
            "🚀 Работать с FlashOS",
            "🔄 Обновить до Latest Release",
            "📋 Посмотреть изменения Latest Release",
            "🗑 Удалить FlashOS",
            "ℹ Информация",
            "🔌 Сменить USB",
            "❌ Выход"
        )
        
        switch ($Selected) {
            0 { Work-Menu }
            1 { Update-FlashOS }
            2 { Write-Host "Release notes (placeholder)" ; Pause-Screen }
            3 { Remove-FlashOS }
            4 { 
                Header
                Write-Host "ℹ FLASHOS INFORMATION" -ForegroundColor Bold
                Write-Host ""
                Write-Host "Device:       $global:Device"
                Write-Host "Name:         $(Get-Manifest 'DEVICE_NAME')"
                Write-Host "FlashOS:      $(Get-Manifest 'FLASHOS_VERSION')"
                Write-Host "Filesystem:   $(Get-Manifest 'FILESYSTEM')"
                Write-Host "Security:     $(Get-Manifest 'SECURITY')"
                Write-Host "Manager:      $(Get-Manifest 'MANAGER')"
                Write-Host ""
                Write-Host "GitHub:       https://github.com/$GitHubRepo"
                Write-Host ""
                Pause-Screen
            }
            -1, 5, 6 { return }
        }
    }
}

# ===========================================================
# CLEANUP
# ===========================================================

function Cleanup {
    Remove-Item -Recurse -Force $RuntimeBase -ErrorAction SilentlyContinue
}

Register-ObjectEvent -InputObject ([System.AppDomain]::CurrentDomain) -EventName DomainUnload -Action { Cleanup } | Out-Null
Register-ObjectEvent -InputObject ([System.AppDomain]::CurrentDomain) -EventName ProcessExit -Action { Cleanup } | Out-Null

# ===========================================================
# STARTUP
# ===========================================================

function Main {
    Check-Dependencies
    
    while ($true) {
        Header
        Write-Host "🔍 Поиск USB-устройств..." -ForegroundColor Cyan
        Start-Sleep -Milliseconds 500
        
        if (Detect-FlashOS) {
            Success "Флешка найдена."
            Write-Host "Device:  $global:Device"
            Write-Host "Name:    $(Get-Manifest 'DEVICE_NAME')"
            Write-Host "Version: $(Get-Manifest 'FLASHOS_VERSION')"
            Start-Sleep -Milliseconds 600
            FlashOS-Found-Menu
            return
        }
        
        Warn "FlashOS на подключённой флешке не найден."
        $Selected = Show-Menu "FLASHOS NOT FOUND" @(
            "🚀 Установить FlashOS",
            "🔄 Повторить поиск",
            "❌ Выход"
        )
        
        switch ($Selected) {
            0 { Write-Host "Install FlashOS (placeholder)" ; Pause-Screen }
            1 { continue }
            -1, 2 { return }
        }
    }
}

Main
