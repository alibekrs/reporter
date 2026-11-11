<#
    Сбор MAC-адресов для таблицы учётных записей.

    Запуск на рабочей станции (обычные права достаточно):
        powershell -ExecutionPolicy Bypass -File collect_mac.ps1
    Запись сразу в общую папку:
        powershell -ExecutionPolicy Bypass -File collect_mac.ps1 "\\server\share\mac_list.csv"

    Файл дополняется, поэтому один и тот же CSV можно наполнять с разных машин.
    Итог открывается в Excel: Компьютер, Пользователь, MAC, IP, Серийный номер.
#>

param([string]$OutFile)

$ErrorActionPreference = "SilentlyContinue"

if (-not $OutFile) {
    $base = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    $OutFile = Join-Path $base "mac_list.csv"
}

# только физические активные адаптеры: без виртуальных, VPN, Bluetooth
$adapters = Get-NetAdapter -Physical |
    Where-Object {
        $_.Status -eq "Up" -and
        $_.InterfaceDescription -notmatch "Virtual|VPN|Bluetooth|Loopback|TAP|Hyper-V|VMware|VirtualBox"
    }

if (-not $adapters) {
    $adapters = Get-NetAdapter -Physical | Where-Object { $_.Status -ne "Disabled" }
}

$serial = (Get-CimInstance Win32_BIOS).SerialNumber
$model  = (Get-CimInstance Win32_ComputerSystem).Model
$rows = @()

foreach ($a in $adapters) {
    $ip = (Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4).IPAddress -join ", "
    $rows += [PSCustomObject]@{
        "Дата"            = (Get-Date -Format "dd.MM.yyyy HH:mm")
        "Компьютер"       = $env:COMPUTERNAME
        "Пользователь"    = $env:USERNAME
        "Адаптер"         = $a.InterfaceDescription
        "MAC"             = ($a.MacAddress -replace "-", ":")
        "IP"              = $ip
        "Модель"          = $model
        "Серийный номер"  = $serial
    }
}

if (-not $rows) {
    Write-Host "Не найдено ни одного сетевого адаптера." -ForegroundColor Yellow
    exit 1
}

$exists = Test-Path $OutFile
$rows | Export-Csv -Path $OutFile -Encoding UTF8 -Delimiter ";" -NoTypeInformation -Append:$exists

Write-Host ""
Write-Host "Собрано с компьютера $env:COMPUTERNAME :" -ForegroundColor Green
$rows | Format-Table "Пользователь", "MAC", "IP", "Адаптер" -AutoSize
Write-Host "Записано в: $OutFile" -ForegroundColor Green
Write-Host ""
