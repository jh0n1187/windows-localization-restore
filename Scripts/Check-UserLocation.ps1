#Requires -Version 5.1
<#
.SYNOPSIS
  Diagnostico SOMENTE LEITURA da permissao de localizacao do USUARIO LOGADO.
  Rode SEM administrador (PowerShell normal), pois le o HKCU do usuario atual.
  powershell -ExecutionPolicy Bypass -File C:\Restore-Location\Scripts\Check-UserLocation.ps1
#>
$ErrorActionPreference = 'Continue'
$out = Join-Path (Split-Path $PSScriptRoot -Parent) ("Logs\Check-UserLocation-{0}-{1}.log" -f $env:USERNAME, (Get-Date -Format 'yyyyMMdd-HHmmss'))
Start-Transcript -Path $out | Out-Null
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$adm = ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
"Usuario: $($id.Name)  SID: $($id.User)  Elevado: $adm"
if ($adm) { 'AVISO: rodando elevado - rode num PowerShell NORMAL para ler o usuario logado.' }

'--- HKLM ConsentStore\location (dispositivo)'
& reg.exe query 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location' 2>&1
'--- HKCU ConsentStore\location (usuario, com subchaves)'
& reg.exe query 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location' /s 2>&1
'--- Politicas (HKLM/HKCU)'
foreach ($k in 'HKLM\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors','HKCU\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors','HKLM\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy') { "## $k"; & reg.exe query $k 2>&1 | Out-String }
'--- Politicas do Chrome/Edge relacionadas a localizacao'
foreach ($k in 'HKLM\SOFTWARE\Policies\Google\Chrome','HKCU\SOFTWARE\Policies\Google\Chrome','HKLM\SOFTWARE\Policies\Microsoft\Edge','HKCU\SOFTWARE\Policies\Microsoft\Edge') {
  $r = & reg.exe query $k 2>&1 | Select-String -Pattern 'Geolocation|Location'
  "## $k : $(if ($r) { ($r | ForEach-Object { $_.Line.Trim() }) -join ' ; ' } else { '(nenhuma)' })"
}
'--- Servicos'
Get-Service lfsvc, camsvc -ErrorAction SilentlyContinue | Format-Table Name, Status, StartType -AutoSize | Out-String

'--- WinRT Geolocator.RequestAccessAsync (o que apps/navegadores recebem do Windows)'
try {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $null = [Windows.Devices.Geolocation.Geolocator, Windows.Devices.Geolocation, ContentType = WindowsRuntime]
    $asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } | Select-Object -First 1
    $op = [Windows.Devices.Geolocation.Geolocator]::RequestAccessAsync()
    $t = $asTask.MakeGenericMethod([Windows.Devices.Geolocation.GeolocationAccessStatus]).Invoke($null, @($op))
    try { $null = $t.Wait(15000); "GeolocationAccessStatus = $($t.Result)   (Allowed = liberado; Denied = bloqueado pelo Windows)" }
    catch {
        $ie = $_.Exception; while ($ie.InnerException) { $ie = $ie.InnerException }
        "RequestAccessAsync FALHOU: {0} | HRESULT=0x{1:X8} | {2}" -f $ie.GetType().FullName, $ie.HResult, $ie.Message
    }
    try { $g = New-Object Windows.Devices.Geolocation.Geolocator; "Geolocator.LocationStatus = $($g.LocationStatus)" }
    catch { $ie = $_.Exception; while ($ie.InnerException) { $ie = $ie.InnerException }; "new Geolocator FALHOU: HRESULT=0x{0:X8} {1}" -f $ie.HResult, $ie.Message }
} catch { $ie = $_.Exception; while ($ie.InnerException) { $ie = $ie.InnerException }; "ERRO WinRT: HRESULT=0x{0:X8} {1}" -f $ie.HResult, $ie.Message }

'--- Componentes da pagina Configuracoes / CapabilityAccessManager'
foreach ($f in 'CapabilityAccessHandlers.dll','SettingsHandlers_CapabilityAccess.dll','CapabilityAccessManager.dll','CapabilityAccessManagerClient.dll','Geolocation.dll','Geocommon.dll','SettingsHandlers_Geolocation.dll') {
    $fp = Join-Path $env:SystemRoot "System32\$f"
    "{0,-40} {1}" -f $f, $(if (Test-Path $fp) { 'PRESENTE v' + (Get-Item $fp).VersionInfo.FileVersion } else { 'AUSENTE' })
}
'## Capabilities\location (definicao da capability)'
& reg.exe query 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\Capabilities\location' /s 2>&1
'## CLSID do Location Capability Handler {0d9948a9-...}'
& reg.exe query 'HKLM\SOFTWARE\Classes\CLSID\{0d9948a9-e79f-4a06-8784-c32583d034f2}' /s 2>&1
'## SettingId da pagina (CapabilityAccess_Location_*)'
foreach ($n in 'SystemSettings_CapabilityAccess_Location_SystemGlobal','SystemSettings_CapabilityAccess_Location_UserGlobal','SystemSettings_CapabilityAccess_Location_ClassicGlobal','SystemSettings_Privacy_LocationEnabledUser') {
    "{0,-60} {1}" -f $n, $(if (Test-Path "HKLM:\SOFTWARE\Microsoft\SystemSettings\SettingId\$n") { 'PRESENTE' } else { 'AUSENTE' })
}
'## WinRT Windows.Devices.Geolocation.* registradas'
Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\WindowsRuntime\ActivatableClassId' -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -like 'Windows.Devices.Geolocation*' } | ForEach-Object { '{0}  -> {1}' -f $_.PSChildName, (Get-ItemProperty $_.PSPath).DllPath }

'--- .NET GeoCoordinateWatcher (Location API classica)'
try {
    Add-Type -AssemblyName System.Device
    $w = New-Object System.Device.Location.GeoCoordinateWatcher
    $null = $w.TryStart($false, [TimeSpan]::FromSeconds(5)); Start-Sleep 3
    "Status=$($w.Status) Permission=$($w.Permission)"; $w.Stop()
} catch { "ERRO: $($_.Exception.Message)" }
Stop-Transcript | Out-Null
"Log salvo em: $out"
