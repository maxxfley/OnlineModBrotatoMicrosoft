# Lanza instancias de Brotato (Microsoft Store) para pruebas de red en una sola PC.
# Uso:
#   powershell -ExecutionPolicy Bypass -File tools/launch_instances.ps1 [-Count 2]
# La primera instancia se abre normal (activación de la app); las siguientes se
# ejecutan dentro del contexto del paquete con Invoke-CommandInDesktopPackage,
# porque la activación normal reutiliza la instancia abierta y el exe directo se cierra.
param([int]$Count = 2)
$ErrorActionPreference = 'Stop'
$Family = '19886SeavenStudio.Brotato_fahzzgrzfd3xc'
$Pkg = Get-AppxPackage -Name '19886SeavenStudio.Brotato'
if (-not $Pkg) { throw 'Brotato (Microsoft Store) no está instalado.' }
$Exe = Join-Path $Pkg.InstallLocation 'Brotato.exe'

$running = @(Get-Process Brotato -ErrorAction SilentlyContinue).Count
for ($i = $running; $i -lt $Count; $i++) {
    if ($i -eq 0) {
        Start-Process "shell:AppsFolder\$Family!Game"
    } else {
        Invoke-CommandInDesktopPackage -PackageFamilyName $Family -AppId 'Game' -Command $Exe -PreventBreakaway
    }
    Start-Sleep -Seconds 8
}
Get-Process Brotato | Select-Object Id, StartTime, MainWindowTitle | Format-Table -AutoSize
