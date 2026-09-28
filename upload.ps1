#Requires -Version 5.1
<#
.SYNOPSIS
  XR1710G: заливка образа в HTTP-рекавери U-Boot с ПК на Windows.
.DESCRIPTION
  Запускать, когда роутер уже в рекавери (http://192.168.255.1).
  По умолчанию заливает новый загрузчик (цель uboot).
.EXAMPLE
  .\upload.ps1
.EXAMPLE
  .\upload.ps1 -Target firmware -Layout 2.0 -File .\openwrt-xr1710g-sysupgrade.itb
#>
param(
    [string]$Address = "192.168.255.1",
    [ValidateSet("uboot", "firmware")][string]$Target = "uboot",
    [ValidateSet("2.0", "1.5", "1.0")][string]$Layout = "2.0",
    [string]$File = "",
    [int]$WaitSeconds = 180,
    [switch]$Yes
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$ScriptVersion = "1.0"
$SlotImage = "xr1710g-chainloader-slot.bin"
$SlotSha256 = "DEAEFED37C13F25EB551D60951CEC7077ADFD01C6964174D0AA938288D27BE30"
$SlotUrl = "https://github.com/akorshun/xr1710g-uboot-recovery/raw/main/firmware/xr1710g-chainloader-slot.bin"
$SlotMax = 1048576

function Write-Fail($message) {
    Write-Host "ОШИБКА: $message" -ForegroundColor Red
    exit 1
}

function Write-Warn($message) {
    Write-Host "ВНИМАНИЕ: $message" -ForegroundColor Yellow
}

function Confirm-Step($message) {
    if ($Yes) { return }
    $answer = Read-Host "$message [y/N]"
    if ($answer -notmatch '^(y|yes|да)$') { Write-Fail "отменено пользователем" }
}

function Get-Json($url, $timeout) {
    try {
        $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec $timeout
        return ($response.Content | ConvertFrom-Json)
    } catch {
        return $null
    }
}

Write-Host "=== XR1710G: заливка в HTTP-рекавери (upload.ps1 $ScriptVersion) ==="

# --- образ ------------------------------------------------------------------
$temp = $null
if ($File -eq "") {
    if ($Target -ne "uboot") { Write-Fail "для цели firmware укажите образ через -File" }
    $local = Join-Path (Join-Path $PSScriptRoot "firmware") $SlotImage
    if (Test-Path -LiteralPath $local) {
        $File = $local
    } else {
        $temp = Join-Path ([System.IO.Path]::GetTempPath()) $SlotImage
        Write-Host "Скачиваю $SlotImage ..."
        Invoke-WebRequest -Uri $SlotUrl -OutFile $temp -UseBasicParsing
        $File = $temp
    }
}
if (-not (Test-Path -LiteralPath $File)) { Write-Fail "файл $File не найден" }

$item = Get-Item -LiteralPath $File
$size = $item.Length
$hash = (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash
Write-Host "Образ:                 $($item.FullName)"
Write-Host "  размер:              $size байт"
Write-Host "  sha256:              $hash"

if ($Target -eq "uboot") {
    if ($size -gt $SlotMax) { Write-Fail "образ загрузчика больше 1 МиБ, рекавери его отвергнет" }
    $head = [System.IO.File]::ReadAllBytes($File)[0..3]
    $magic = ($head | ForEach-Object { $_.ToString("x2") }) -join ""
    if ($magic -ne "27051956") {
        Write-Fail "это не образ слота: нет legacy-заголовка uImage (magic $magic). Нужен $SlotImage, а не u-boot.bin или *.itb"
    }
    if ($hash -eq $SlotSha256) {
        Write-Host "  проверка:            совпадает с xr1710g_260805 из YYH2913/http-uboot"
    } else {
        Write-Warn "образ не совпадает с известным xr1710g_260805, убедитесь в его происхождении"
    }
} else {
    if ($size -lt 1048576) { Write-Fail "образ прошивки меньше 1 МиБ, это не sysupgrade.itb" }
    Write-Host "  раскладка UBI:       $Layout (должна совпадать с DTS образа!)"
}

# --- ожидание рекавери ------------------------------------------------------
Write-Host ""
Write-Host "Жду рекавери на http://$Address" -NoNewline
$about = $null
$waited = 0
while ($waited -lt $WaitSeconds) {
    $about = Get-Json "http://$Address/about" 3
    if ($about -ne $null) { break }
    Write-Host "." -NoNewline
    Start-Sleep -Seconds 2
    $waited += 2
}
Write-Host ""
if ($about -eq $null) {
    Write-Fail @"
рекавери не ответило за $WaitSeconds с.
       Проверьте: ПК в порту 10GbE, адрес получен по DHCP (192.168.255.2),
       роутер в рекавери (кнопка reset при включении или flash.sh на роутере)
"@
}

if ($about.u_boot) { Write-Host "Рекавери:              $($about.u_boot)" }
if ($about.detected_layout) { Write-Host "Текущая раскладка:     $($about.detected_layout)" }
$uiBuild = ""
if ($about.ui_build) {
    $uiBuild = $about.ui_build
    Write-Host "UI build:              $uiBuild"
}

# --- запрос подтверждения ---------------------------------------------------
if ($Target -eq "uboot") {
    Confirm-Step "Записать этот образ в слот загрузчика (1 МиБ) на $Address?"
} else {
    Confirm-Step "Перезаписать UBI ($Layout) прошивкой на $Address? Данные будут стёрты!"
}

# --- отправка ---------------------------------------------------------------
$url = "http://$Address/upload/$Target"
$sep = "?"
if ($uiBuild -ne "") {
    $url = "$url$sep" + "ui_build=" + [System.Uri]::EscapeDataString($uiBuild)
    $sep = "&"
}
if ($Target -eq "firmware") {
    $url = "$url$sep" + "layout=" + [System.Uri]::EscapeDataString($Layout)
}

Write-Host ""
Write-Host "POST $url"
try {
    $post = Invoke-WebRequest -Uri $url -Method Post -InFile $File `
        -ContentType "application/octet-stream" -UseBasicParsing -TimeoutSec 600
    Write-Host "Образ принят рекавери (HTTP $($post.StatusCode))."
} catch {
    Write-Fail "POST не удался: $($_.Exception.Message). Состояние смотрите на http://$Address"
}

# --- ход операции -----------------------------------------------------------
Write-Host ""
Write-Host "Ход операции:"
$last = ""
$generation = 0
for ($i = 0; $i -lt 300; $i++) {
    $st = Get-Json "http://$Address/status" 5
    if ($st -eq $null) { Start-Sleep -Seconds 2; continue }
    $line = "  стирание $($st.erase_done)/$($st.erase_total), запись $($st.write_done)/$($st.write_total)"
    if ($line -ne $last) {
        Write-Host $line
        $last = $line
    }
    if ($st.error -ne 0) {
        Write-Fail "рекавери вернуло ошибку (code $($st.error), stage '$($st.error_stage)', detail '$($st.validation_detail)')"
    }
    if ($st.ok -eq 1 -and $st.in_progress -eq 0) {
        if ($st.completion_generation) { $generation = $st.completion_generation }
        Write-Host "  готово"
        break
    }
    Start-Sleep -Seconds 2
}

if ($generation -gt 0) {
    Get-Json "http://$Address/status-ack/$generation" 5 | Out-Null
    Write-Host "Подтверждение отправлено, роутер перезагружается."
} else {
    Write-Host "Роутер перезагрузится сам."
}

if ($temp -ne $null -and (Test-Path -LiteralPath $temp)) {
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
}
