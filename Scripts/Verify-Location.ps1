#Requires -Version 5.1
<#
.SYNOPSIS
  Verifica o reparo do Windows Location (lfsvc). SOMENTE LEITURA
  (exceto tentativa de iniciar o servico, que pode ser desativada com -NoStart).

.PARAMETER Functional
  Teste funcional via System.Device.Location.GeoCoordinateWatcher (Location API -> lfsvc).

.EXAMPLE
  .\Verify-Location.ps1
  .\Verify-Location.ps1 -Functional
#>
[CmdletBinding()]
param(
    [switch]$NoStart,
    [switch]$Functional,
    [int]$FunctionalTimeoutSec = 30,
    [string]$KitRoot = (Split-Path $PSScriptRoot -Parent)
)
$ErrorActionPreference = 'Continue'
$ts  = Get-Date -Format 'yyyyMMdd-HHmmss'
New-Item -ItemType Directory -Path (Join-Path $KitRoot 'Logs') -Force | Out-Null
$Log = Join-Path $KitRoot "Logs\Verify-$ts.log"
$res = [ordered]@{}
function L([string]$m, [string]$c = 'Gray') { Add-Content -Path $Log -Value $m -Encoding UTF8; Write-Host $m -ForegroundColor $c }
function Set-Res([string]$k, [string]$v, [string]$why) {
    $order = @{ 'PASS' = 0; 'WARN' = 1; 'FAIL' = 2 }
    if (-not $res.Contains($k) -or $order[$v] -gt $order[$res[$k]]) { $res[$k] = $v }
    $c = @{ 'PASS' = 'Green'; 'WARN' = 'Yellow'; 'FAIL' = 'Red' }[$v]
    L ("  [{0}] {1}: {2}" -f $v, $k, $why) $c
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Host 'ERRO: execute como Administrador.' -ForegroundColor Red; exit 2 }

# ---------------------------------------------------------------- sistema
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
L ("Windows: {0} {1} build {2}.{3} | {4} | UI {5} | {6}" -f $cv.ProductName, $cv.DisplayVersion, $cv.CurrentBuild, $cv.UBR, $env:PROCESSOR_ARCHITECTURE, (Get-UICulture).Name, (Get-Date -Format 's')) 'Cyan'
$b = [int]$cv.CurrentBuild
. (Join-Path $PSScriptRoot 'KitProfile.ps1')
$KP = Get-KitProfile -KitRoot $KitRoot
if ($KP) {
    Write-KitProfileBanner $KP
    $full = $KP.Features.Files -and $KP.Features.ServiceRegistry -and $KP.Features.ComRegistry
    Set-Res 'Platform' $(if ($full) { 'PASS' } else { 'WARN' }) ("perfil {0} (builds {1}-{2}){3}" -f $KP.Name, $KP.MinBuild, $KP.MaxBuild, $(if (-not $full) { ' - perfil PARCIAL: arquivos/registro apenas diagnosticados' }))
} else { Set-Res 'Platform' 'FAIL' "nenhum perfil em Profiles\ cobre o build $b" }
$KF = if ($KP) { $KP.Features } else { [pscustomobject]@{ Files = $false; ServiceRegistry = $false; ComRegistry = $false } }
# Em perfil parcial, divergencias de itens que o perfil nao restaura viram WARN (diagnostico), nao FAIL
function Lvl([bool]$ok, [bool]$supported) { if ($ok) { 'PASS' } elseif ($supported) { 'FAIL' } else { 'WARN' } }

# ---------------------------------------------------------------- arquivos
L ''; L 'Arquivos:'
$mf = if ($KP) { $KP.ManifestPath } else { '' }
if (-not $KF.Files) {
    # perfil sem binarios: confere apenas a presenca dos componentes principais no sistema
    foreach ($f in 'System32\lfsvc.dll','System32\LocationFramework.dll','System32\Geolocation.dll','System32\LocationApi.dll') {
        Set-Res 'Files' (Lvl (Test-Path (Join-Path $env:SystemRoot $f)) $false) ("{0} {1} (perfil sem binarios: somente diagnostico)" -f $f, $(if (Test-Path (Join-Path $env:SystemRoot $f)) { 'presente' } else { 'AUSENTE' }))
    }
} elseif (Test-Path $mf) {
    $unsigned = 0
    foreach ($m in (Import-Csv $mf)) {
        $d = Join-Path $env:SystemRoot $m.RelPath
        $req = $m.Required -eq 'Required'
        if ($m.RelPath -like '*\pt-BR\*' -and -not (Test-Path (Split-Path $d))) { L "  [SKIP] $($m.RelPath) (pt-BR nao instalado)"; continue }
        if (-not (Test-Path -LiteralPath $d)) { Set-Res 'Files' $(if ($req) { 'FAIL' } else { 'PASS' }) "$($m.RelPath) AUSENTE$(if (-not $req) {' (opcional)'})"; continue }
        $h   = (Get-FileHash -LiteralPath $d -Algorithm SHA256).Hash
        $v   = (Get-Item -LiteralPath $d).VersionInfo.FileVersion
        $sig = (Get-AuthenticodeSignature -LiteralPath $d).Status
        $pe  = ''
        if ($d -match '\.(dll|exe)$') {
            $bytes = [IO.File]::ReadAllBytes($d); $o = [BitConverter]::ToInt32($bytes, 0x3C)
            $mach = [BitConverter]::ToUInt16($bytes, $o + 4)
            $exp = if ($m.RelPath -like 'SysWOW64\*') { 0x14c } else { 0x8664 }
            if ($mach -ne $exp) { Set-Res 'Files' 'FAIL' "$($m.RelPath) arquitetura PE incorreta (0x$('{0:X}' -f $mach))"; continue }
        }
        $hashNote = if ($h -eq $m.SHA256) { 'hash=kit' } else { 'hash difere do kit (versao existente preservada)' }
        if ($sig -ne 'Valid' -and $d -match '\.(dll|exe|mui)$') { $unsigned++ }
        Set-Res 'Files' 'PASS' ("{0} v{1} sig={2} {3}" -f $m.RelPath, $v, $sig, $hashNote)
    }
    if ($unsigned) { L "  Obs.: $unsigned binario(s) sem assinatura reconhecida: o catalogo do pacote nao esta registrado (a etapa A registra os catalogos do perfil); a integridade e garantida pelo SHA256 do manifest." }
} else { Set-Res 'Files' 'FAIL' "manifest.csv nao encontrado ($mf)" }

# ---------------------------------------------------------------- registro lfsvc
L ''; L 'Registro lfsvc:'
$k = 'HKLM:\SYSTEM\CurrentControlSet\Services\lfsvc'
$s = Get-ItemProperty $k -ErrorAction SilentlyContinue
$p = Get-ItemProperty "$k\Parameters" -ErrorAction SilentlyContinue
if (-not $s) { Set-Res 'lfsvc registry' (Lvl $false ([bool]$KF.ServiceRegistry)) 'chave Services\lfsvc ausente' }
else {
    $chk = @(
        @('Type', ($s.Type -eq 32), $s.Type),
        @('ImagePath', ($s.ImagePath -match 'svchost\.exe -k netsvcs'), $s.ImagePath),
        @('ObjectName', ($s.ObjectName -eq 'LocalSystem'), $s.ObjectName),
        @('DependOnService', (@($s.DependOnService) -contains 'RpcSs'), (@($s.DependOnService) -join ',')),
        @('ServiceSidType', ($s.ServiceSidType -eq 1), $s.ServiceSidType),
        @('RequiredPrivileges', (@($s.RequiredPrivileges) -contains 'SeImpersonatePrivilege'), (@($s.RequiredPrivileges) -join ',')),
        @('Start (3=Manual; 4=Desativado pelo debloat -> rodar etapa B)', ($s.Start -eq 3 -or $s.Start -eq 2), $s.Start),
        @('TriggerInfo', (Test-Path "$k\TriggerInfo"), (Test-Path "$k\TriggerInfo")),
        @('Components', (Test-Path "$k\Components"), (Test-Path "$k\Components"))
    )
    foreach ($c in $chk) {
        # Start=4 (desativado) e corrigido pela etapa B (Consent), disponivel tambem no perfil Win11
        $sup = [bool]$KF.ServiceRegistry -or ($c[0] -like 'Start*' -and [bool]$KF.Consent)
        Set-Res 'lfsvc registry' (Lvl ([bool]$c[1]) $sup) ("{0} = {1}" -f $c[0], $c[2])
    }
    $dll = if ($p) { [Environment]::ExpandEnvironmentVariables([string]$p.ServiceDll) } else { '' }
    if ($dll -and (Test-Path $dll) -and $dll -match 'lfsvc\.dll$') { Set-Res 'ServiceDll' 'PASS' "$($p.ServiceDll) -> existe" } else { Set-Res 'ServiceDll' (Lvl $false ([bool]$KF.ServiceRegistry)) "ServiceDll invalido/ausente: '$($p.ServiceDll)'" }
    if ($p.ServiceMain -eq 'ServiceMain') { Set-Res 'ServiceDll' 'PASS' 'ServiceMain = ServiceMain' } else { Set-Res 'ServiceDll' 'WARN' "ServiceMain = '$($p.ServiceMain)'" }
}

# ---------------------------------------------------------------- netsvcs
$grp = Get-LfsvcSvchostGroup
$gname = if ($grp) { $grp.Group } else { 'netsvcs' }
$ns = if ($grp) { $grp.Members } else { @((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Svchost' -Name netsvcs -ErrorAction SilentlyContinue).netsvcs) }
if ($ns | Where-Object { $_ -ieq 'lfsvc' }) { Set-Res 'netsvcs' 'PASS' "Svchost\$gname contem lfsvc ($($ns.Count) entradas)" } else { Set-Res 'netsvcs' (Lvl $false ([bool]$KF.ServiceRegistry -or [bool]$KF.Consent)) "lfsvc ausente do Svchost\$gname (grupo do ImagePath) -> rodar etapa B e reiniciar" }

# ---------------------------------------------------------------- COM (componentes do framework)
L ''; L 'COM / WinRT:'
$comData = if ($KP) { Join-Path $KP.RegistryRoot 'location-registry.json' } else { '' }
if (-not $KF.ComRegistry) {
    # perfil sem dados COM: confere a classe COM "lfsvc" (ponte WinRT -> servico), presente em Win10 e Win11
    $c = Test-Path 'HKLM:\SOFTWARE\Classes\CLSID\{08D9DFDF-C6F7-404A-A20F-66EEC0A609CD}'
    $a = Test-Path 'HKLM:\SOFTWARE\Classes\AppID\{020FB939-2C8B-4DB7-9E90-9527966E38E5}'
    Set-Res 'COM registry' (Lvl ($c -and $a) $false) ("classe COM lfsvc {0} / AppID {1} (perfil sem dados COM: somente diagnostico)" -f $(if ($c) { 'presente' } else { 'AUSENTE' }), $(if ($a) { 'presente' } else { 'AUSENTE' }))
} elseif (Test-Path $comData) {
    $entries = Get-Content $comData -Raw -Encoding UTF8 | ConvertFrom-Json
    $hklm = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', 'Registry64')
    $stat = @{}; $missing = @()
    foreach ($e in $entries) {
        $g = $e.Group; if (-not $stat[$g]) { $stat[$g] = @{ ok = 0; miss = 0; na = 0 } }
        if ($e.RequiresFile -and -not (Test-Path (Join-Path $env:SystemRoot $e.RequiresFile))) { $stat[$g].na++; continue }
        $bad = $false
        foreach ($kk in $e.Keys) {
            $sk = $null; try { $sk = $hklm.OpenSubKey($kk.Path) } catch { continue }   # existe, mas sem permissao de leitura
            if (-not $sk) { $bad = $true; break }
            foreach ($v in @($kk.Values)) { if ($null -eq $sk.GetValue($v.Name, $null, 'DoNotExpandEnvironmentNames')) { $bad = $true } }
            $sk.Close(); if ($bad) { break }
        }
        if ($bad) { $stat[$g].miss++; $missing += $e.Root } else { $stat[$g].ok++ }
    }
    foreach ($g in $stat.Keys) {
        $t = "{0}: {1} OK, {2} faltando, {3} N/A (arquivo opcional ausente){4}" -f $g, $stat[$g].ok, $stat[$g].miss, $stat[$g].na, $(if ($g -eq 'SystemSettings' -and $stat[$g].miss) { ' - botoes da pagina Localizacao em branco; rodar etapa A' })
        # COM-* e WinRT sao o caminho dos apps ate o servico (FAIL); SystemSettings e Sistema (notificacoes, BackgroundModel,
        # log de eventos, definicoes) nao impedem a localizacao de funcionar (WARN)
        $lvl = if (-not $stat[$g].miss) { 'PASS' } elseif ($g -in 'SystemSettings', 'Sistema') { 'WARN' } else { 'FAIL' }
        Set-Res $(switch ($g) { 'SystemSettings' { 'Settings UI registry' } 'Sistema' { 'System registry' } default { 'COM registry' } }) $lvl $t
    }
    if ($missing) { L ('    faltando: ' + (($missing | Select-Object -First 10) -join ' ; ') + $(if ($missing.Count -gt 10) { ' ...' })) }
} else { Set-Res 'COM registry' 'WARN' "location-registry.json nao encontrado ($comData)" }
$rt = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\WindowsRuntime\ActivatableClassId\Windows.Devices.Geolocation.Geolocator' -ErrorAction SilentlyContinue
if ($rt -and $rt.DllPath -and (Test-Path ([Environment]::ExpandEnvironmentVariables($rt.DllPath)))) { Set-Res 'WinRT' 'PASS' "WinRT Geolocator -> $($rt.DllPath)" } else { Set-Res 'WinRT' 'WARN' 'WinRT Windows.Devices.Geolocation.Geolocator nao registrado/DLL ausente' }
$rt32 = Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\WindowsRuntime\ActivatableClassId\Windows.Devices.Geolocation.Geolocator' -ErrorAction SilentlyContinue
if ($rt32 -and $rt32.DllPath -and (Test-Path ([Environment]::ExpandEnvironmentVariables($rt32.DllPath)))) { Set-Res 'WinRT' 'PASS' "WinRT Geolocator (apps 32-bit) -> $($rt32.DllPath)" } else { Set-Res 'WinRT' 'WARN' 'WinRT Geolocator para apps 32-bit nao registrado/DLL ausente (SysWOW64\Geolocation.dll)' }

# ---------------------------------------------------------------- tarefas agendadas / catalogos de assinatura
$taskSt = @(Get-KitTaskState $KP); $catSt = @(Get-KitCatalogState $KP)
if ($taskSt.Count -or $catSt.Count) { L ''; L 'Tarefas agendadas e assinatura:' }
foreach ($tk in $taskSt) {
    $tn = "$($tk.TaskPath)$($tk.TaskName)"
    if ($tk.Ok) { Set-Res 'Scheduled tasks' 'PASS' "$tn registrada" }
    elseif (-not $tk.Applicable) { L "  [SKIP] $tn ($($tk.RequiresFile) ausente)" }
    else { Set-Res 'Scheduled tasks' 'WARN' "$tn AUSENTE - rodar etapa A (sem a tarefa Notifications o icone de localizacao em uso nao aparece)" }
}
if ($catSt.Count) {
    $cm = @($catSt | Where-Object { -not $_.Ok })
    if ($cm) { Set-Res 'Signature catalogs' 'WARN' ("{0} de {1} catalogo(s) nao registrado(s) - binarios restaurados aparecem como NotSigned; rodar etapa A" -f $cm.Count, $catSt.Count) }
    else { Set-Res 'Signature catalogs' 'PASS' ("{0} catalogo(s) do perfil registrados" -f $catSt.Count) }
}

# ---------------------------------------------------------------- servico
L ''; L 'Servico:'
$svc = Get-Service lfsvc -ErrorAction SilentlyContinue
if ($svc) { Set-Res 'Service registration' 'PASS' "SCM reconhece lfsvc (DisplayName: $($svc.DisplayName))" } else { Set-Res 'Service registration' 'FAIL' 'SCM nao reconhece lfsvc (reinicializacao pendente?)' }
if ($svc -and $svc.DisplayName -eq 'lfsvc') { Set-Res 'Service registration' 'WARN' 'DisplayName nao resolvido (lfsvc.dll.mui do idioma ausente)' }
if ($svc) {
    foreach ($sv in 'lfsvc', 'camsvc') {
        $si = Get-SvcStartInfo $sv
        if ($null -eq $si.Scm) { continue }
        if (-not $si.Disabled) { Set-Res 'Service config (SCM)' 'PASS' ("{0}: SCM StartMode={1}, registro Start={2}" -f $sv, $si.Scm, $si.Reg) }
        elseif ($si.Mismatch) { Set-Res 'Service config (SCM)' 'FAIL' ("{0}: SCM StartMode={1} mas registro Start={2} - registro alterado sem reinicio; rodar etapa B (sc config) ou reiniciar" -f $sv, $si.Scm, $si.Reg) }
        else { Set-Res 'Service config (SCM)' 'FAIL' ("{0}: desativado (SCM={1}, registro={2}) - rodar etapa B" -f $sv, $si.Scm, $si.Reg) }
    }
}
$t0 = Get-Date
if ($svc) {
    $seenRun = ($svc.Status -eq 'Running'); $runPid = $null; $t1 = Get-Date
    $scOut = ''
    if (-not $NoStart -and $svc.Status -ne 'Running') { $scOut = (& sc.exe start lfsvc 2>&1 | Out-String).Trim() }
    $w = $null
    while (((Get-Date) - $t1).TotalSeconds -lt 12) {
        $w = Get-CimInstance Win32_Service -Filter "Name='lfsvc'"
        if ($w.State -eq 'Running') { $seenRun = $true; $runPid = $w.ProcessId }
        if ($seenRun -and ((Get-Date) - $t1).TotalSeconds -ge 6) { break }
        Start-Sleep -Milliseconds 150
    }
    $txt = "estado final=$($w.State) ExitCode=$($w.ExitCode); RUNNING observado=$seenRun$(if ($runPid) { " (PID $runPid)" })"
    if ($w.State -eq 'Running') { Set-Res 'Service start' 'PASS' "$txt - permanece em execucao" }
    elseif ($w.ExitCode -eq 126) { Set-Res 'Service start' 'FAIL' "$txt - erro 126: modulo nao encontrado" }
    elseif ($seenRun -and $w.ExitCode -eq 0) { Set-Res 'Service start' 'WARN' "$txt - iniciou e encerrou normalmente (ocioso ou localizacao desativada)" }
    elseif ($NoStart) { Set-Res 'Service start' 'WARN' "$txt (NoStart)" }
    else { Set-Res 'Service start' 'FAIL' "$txt - nao chegou a RUNNING"; if ($scOut) { L ('    sc start: ' + (($scOut -split "`r?`n" | Where-Object { $_ -match '\S' }) -join ' | ')) 'Red'; if ($scOut -match '1058') { L '    Dica: 1058 = SCM considera o servico DESATIVADO (veja "Service config (SCM)"). Corrige com a etapa B (sc config lfsvc start= demand).' 'Yellow' } } }
}
$ev = Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Service Control Manager'; StartTime = (Get-Date).AddHours(-24) } -ErrorAction SilentlyContinue |
      Where-Object { $_.Level -le 3 -and $_.Message -match '(?i)lfsvc|geoloc|localiza' }
if ($ev) {
    $recent = $ev | Where-Object { $_.TimeCreated -ge $t0.AddSeconds(-5) }
    Set-Res 'Events' $(if ($recent) { 'FAIL' } else { 'WARN' }) ("{0} evento(s) SCM de erro/aviso nas ultimas 24h ({1} desta verificacao); ultimo: [{2}] {3}" -f @($ev).Count, @($recent).Count, $ev[0].Id, (($ev[0].Message -split "`n")[0]).Trim())
} else { Set-Res 'Events' 'PASS' 'nenhum erro/aviso SCM relacionado ao lfsvc nas ultimas 24h' }

# ---------------------------------------------------------------- politicas / capability
L ''; L 'Politicas e privacidade (somente leitura):'
$pol = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors' -ErrorAction SilentlyContinue
$any = $false
foreach ($n in 'DisableLocation','DisableWindowsLocationProvider','DisableLocationScripting','DisableSensors') {
    if ($pol -and $pol.$n -eq 1) { $any = $true; Set-Res 'Location policies' 'WARN' "LocationAndSensors\$n = 1" }
}
$ap = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy' -ErrorAction SilentlyContinue
if ($ap -and $ap.LetAppsAccessLocation -eq 2) { $any = $true; Set-Res 'Location policies' 'WARN' 'AppPrivacy\LetAppsAccessLocation = 2 (Force Deny)' }
if (-not $any) { Set-Res 'Location policies' 'PASS' 'nenhuma politica bloqueando localizacao' }

$camM = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location' -ErrorAction SilentlyContinue).Value
L "  ConsentStore\location: dispositivo(HKLM)=$camM"
if ($camM -eq 'Deny') { Set-Res 'Location capability' 'WARN' 'Localizacao do dispositivo desativada (HKLM Value=Deny)' }
# por usuario: todos os perfis + perfil modelo Default (novos usuarios)
$us = @(Get-KitUserLocationState)
$uBad = 0
foreach ($u in $us) {
    if (-not $u.Loaded) {
        if ($u.Skip) { L ("  {0}: {1}" -f $u.Label, $u.Status) 'DarkGray' } else { $uBad++; Set-Res 'Location capability' 'WARN' ("{0}: {1}" -f $u.Label, $u.Status) }
        continue
    }
    $txt = "{0}: apps={1} appsDesktop={2}{3}" -f $u.Label, $u.Value, $u.NonPackaged, $(if ($u.PolicyKey) { ' | politica LocationAndSensors presente' })
    if ($u.Value -eq 'Allow' -and $u.NonPackaged -eq 'Allow' -and -not $u.PolicyKey) { L "  $txt" 'Green' }
    else { $uBad++; Set-Res 'Location capability' 'WARN' "$txt - rodar etapas B/C" }
}
if ($camM -ne 'Deny' -and $uBad -eq 0) { Set-Res 'Location capability' 'PASS' ("dispositivo e todos os {0} perfil(is) permitem localizacao (inclui Default = novos usuarios)" -f @($us | Where-Object { -not $_.Skip }).Count) }

# ---------------------------------------------------------------- teste funcional
if ($Functional) {
    L ''; L "Teste funcional (GeoCoordinateWatcher, ate $FunctionalTimeoutSec s):"
    try {
        Add-Type -AssemblyName System.Device -ErrorAction Stop
        $gw = New-Object System.Device.Location.GeoCoordinateWatcher([System.Device.Location.GeoPositionAccuracy]::Default)
        $started = $gw.TryStart($false, [TimeSpan]::FromSeconds(3))
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($sw.Elapsed.TotalSeconds -lt $FunctionalTimeoutSec -and ($gw.Status -ne 'Ready' -or $gw.Position.Location.IsUnknown) -and $gw.Permission -ne 'Denied') { Start-Sleep -Milliseconds 500 }
        $loc = $gw.Position.Location
        $info = "TryStart=$started Status=$($gw.Status) Permission=$($gw.Permission)"
        if (-not $loc.IsUnknown) { Set-Res 'Functional' 'PASS' ("{0} Lat={1:N5} Lon={2:N5} Precisao={3:N0}m" -f $info, $loc.Latitude, $loc.Longitude, $loc.HorizontalAccuracy) }
        elseif ($gw.Permission -eq 'Denied') { Set-Res 'Functional' 'WARN' "$info - acesso negado pelas configuracoes de privacidade/politica" }
        else { Set-Res 'Functional' 'WARN' "$info - sem posicao (sem Wi-Fi/GNSS? defina 'Local padrao' em Configuracoes > Privacidade > Localizacao)" }
        try { $gw.Stop() } catch {}   # Dispose omitido: o RCW COM pode lancar excecao ao liberar
    } catch { Set-Res 'Functional' 'FAIL' "excecao: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------- relatorio
$w2 = Get-CimInstance Win32_Service -Filter "Name='lfsvc'" -ErrorAction SilentlyContinue
if ($w2) { L ''; L "Estado final do lfsvc: $($w2.State) (ExitCode $($w2.ExitCode)). Obs.: lfsvc e trigger-start e pode parar sozinho quando ocioso; isso NAO e falha se ExitCode=0." }

$core = 'Files','lfsvc registry','ServiceDll','netsvcs','COM registry','Service registration','Service start'
$overall = if ($core | Where-Object { $res[$_] -eq 'FAIL' -or -not $res.Contains($_) }) { 'FAIL' }
           elseif ($res.Values -contains 'FAIL') { 'FAIL' }
           elseif ($res.Values -contains 'WARN') { 'PASS (com avisos)' } else { 'PASS' }
L ''
L 'Windows Location Repair Verification' 'Cyan'
L '------------------------------------' 'Cyan'
foreach ($kv in $res.GetEnumerator()) {
    $c = @{ 'PASS' = 'Green'; 'WARN' = 'Yellow'; 'FAIL' = 'Red' }[$kv.Value]
    L (("{0} " -f $kv.Key).PadRight(22, '.') + ' ' + $kv.Value) $c
}
L ''
L (('Overall ').PadRight(22, '.') + ' ' + $overall) $(if ($overall -like 'PASS*') { 'Green' } else { 'Red' })
L "Log: $Log"
if ($overall -eq 'FAIL') { exit 1 } else { exit 0 }
