<#
    Сканирование локальной сети: IP + MAC + имя компьютера.

    Как работает: рассылает быстрые ping по всем адресам подсети (это наполняет
    ARP-таблицу), затем читает ARP-таблицу Windows и сопоставляет IP с MAC.
    Права администратора НЕ нужны.

    Запуск (своя подсеть определяется автоматически):
        powershell -ExecutionPolicy Bypass -File scan_net.ps1

    Конкретная подсеть:
        powershell -ExecutionPolicy Bypass -File scan_net.ps1 -Subnet 147.159.50

    Без разрешения имён (быстрее в 3-5 раз):
        powershell -ExecutionPolicy Bypass -File scan_net.ps1 -NoNames

    ВАЖНО: MAC-адреса видны только в своей подсети (ARP не проходит через
    маршрутизатор). Для других сетей запустите скрипт на ПК в той сети либо
    возьмите ARP-таблицу и аренды DHCP на шлюзе ICS.
#>

param(
    [string]$Subnet,                        # например 147.159.50 (без последнего октета)
    [string]$OutFile,
    [switch]$NoNames,
    [int]$TimeoutMs = 250
)

$ErrorActionPreference = "SilentlyContinue"

# ── определяем свою подсеть, если не задана ────────────────────────────────
if (-not $Subnet) {
    $ipcfg = Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.IPAddress -notmatch "^(127\.|169\.254\.)" -and $_.PrefixLength -ge 22 } |
        Sort-Object -Property SkipAsSource | Select-Object -First 1
    if (-not $ipcfg) { Write-Host "Не удалось определить подсеть. Укажите -Subnet" -ForegroundColor Red; exit 1 }
    $Subnet = ($ipcfg.IPAddress -split "\.")[0..2] -join "."
    Write-Host "Подсеть определена автоматически: $Subnet.0/24" -ForegroundColor Cyan
}

if (-not $OutFile) {
    $base = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    $OutFile = Join-Path $base ("scan_" + ($Subnet -replace "\.", "_") + ".csv")
}

# ── 1) массовый ping (асинхронно, наполняет ARP-таблицу) ───────────────────
Write-Host "Опрашиваю $Subnet.1-254 ..." -ForegroundColor Cyan
$pings = foreach ($i in 1..254) {
    $p = New-Object System.Net.NetworkInformation.Ping
    $p.SendPingAsync("$Subnet.$i", $TimeoutMs)
}
[System.Threading.Tasks.Task]::WaitAll($pings)

$alive = @{}
foreach ($t in $pings) {
    if ($t.Result -and $t.Result.Status -eq "Success") {
        $alive[$t.Result.Address.IPAddressToString] = $true
    }
}
Write-Host "Ответили на ping: $($alive.Count)" -ForegroundColor Green

# ── 2) читаем ARP-таблицу ──────────────────────────────────────────────────
$neighbors = Get-NetNeighbor -AddressFamily IPv4 |
    Where-Object {
        $_.IPAddress -like "$Subnet.*" -and
        $_.LinkLayerAddress -and
        $_.LinkLayerAddress -ne "00-00-00-00-00-00" -and
        $_.State -in @("Reachable", "Stale", "Delay", "Probe", "Permanent")
    }

if (-not $neighbors) {          # запасной путь для старых систем
    $neighbors = (arp -a) | ForEach-Object {
        if ($_ -match "^\s*($([regex]::Escape($Subnet))\.\d+)\s+([0-9a-f\-]{17})\s+(\w+)") {
            [PSCustomObject]@{ IPAddress = $matches[1]; LinkLayerAddress = $matches[2]; State = $matches[3] }
        }
    }
}

# ── 3) собираем результат ──────────────────────────────────────────────────
$result = foreach ($n in $neighbors) {
    $name = ""
    if (-not $NoNames) {
        $name = ([System.Net.Dns]::GetHostEntry($n.IPAddress)).HostName
    }
    [PSCustomObject]@{
        "IP"        = $n.IPAddress
        "MAC"       = ($n.LinkLayerAddress -replace "-", ":").ToUpper()
        "Имя"       = $name
        "Отвечает"  = if ($alive[$n.IPAddress]) { "да" } else { "нет" }
        "Состояние" = $n.State
    }
}

$result = $result | Sort-Object { [version]($_.IP) }

if (-not $result) {
    Write-Host "Ничего не найдено. Проверьте подсеть или брандмауэр." -ForegroundColor Yellow
    exit 1
}

$result | Format-Table -AutoSize
$result | Export-Csv -Path $OutFile -Encoding UTF8 -Delimiter ";" -NoTypeInformation
Write-Host ""
Write-Host "Найдено узлов: $($result.Count). Файл: $OutFile" -ForegroundColor Green
Write-Host "Открывается в Excel двойным кликом (разделитель — точка с запятой)." -ForegroundColor DarkGray
