# Instala o revierte un boot.hvp modificado en la instalación de Microsoft Store.
# Uso:
#   powershell -ExecutionPolicy Bypass -File tools\swap_boot.ps1 install build\boot_probe.hvp
#   powershell -ExecutionPolicy Bypass -File tools\swap_boot.ps1 restore
param(
    [Parameter(Mandatory = $true)][ValidateSet('install', 'restore')][string]$Action,
    [string]$Package
)
$ErrorActionPreference = 'Stop'
$Game = 'C:\XboxGames\Brotato\Content'
$Root = Split-Path -Parent $PSScriptRoot
$Backup = Join-Path $Root 'backup\boot.hvp.orig'
$Target = Join-Path $Game 'boot.hvp'

if (Get-Process -Name Brotato -ErrorAction SilentlyContinue) { throw 'Cerrá Brotato antes de continuar.' }
if (-not (Test-Path $Backup)) { throw "No existe el backup $Backup" }

if ($Action -eq 'install') {
    if (-not $Package) { throw 'Falta la ruta del paquete a instalar.' }
    Copy-Item -LiteralPath (Resolve-Path $Package) -Destination $Target -Force
    Write-Output "Instalado: $Package -> $Target"
} else {
    Copy-Item -LiteralPath $Backup -Destination $Target -Force
    Write-Output 'Restaurado boot.hvp original.'
}
(Get-FileHash $Target -Algorithm SHA256).Hash
