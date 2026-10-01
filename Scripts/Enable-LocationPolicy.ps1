#Requires -Version 5.1
<#
.SYNOPSIS
  OPCIONAL - Reabilita a localizacao do Windows desativada pelo debloat (politica + privacidade).
  NAO e executado pelo Restore-Location.ps1; rode somente se quiser a localizacao LIGADA.

.DESCRIPTION
  Altera SOMENTE:
    HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location  Value = Allow   (dispositivo)
    <usuario>\...\ConsentStore\location                                                          Value = Allow   (apps)
    <usuario>\...\ConsentStore\location\NonPackaged                                              Value = Allow   (apps desktop)
      -> em TODOS os perfis existentes (sessao aberta ou nao) e no perfil modelo Default (usuarios novos)
    HKLM\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors  DisableWindowsLocationProvider = 0 (so se existir = 1)
    HKLM\SYSTEM\CurrentControlSet\Services\lfsvc\Service\Configuration  Status = 1 (estado "Localizacao deste dispositivo")
    Servicos lfsvc e camsvc: se estiverem DESATIVADOS (Start=4) voltam para Manual (3)
  NAO altera DisableSensors, DisableLocationScripting nem DisableLocation.
  Faz backup (reg export) antes; -Revert reimporta o backup mais recente.

.EXAMPLE
  .\Enable-LocationPolicy.ps1 -WhatIf
  .\Enable-LocationPolicy.ps1
  .\Enable-LocationPolicy.ps1 -Revert
#>
[CmdletBinding()]
param([switch]$WhatIf, [switch]$Revert, [string]$KitRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Continue'
$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
$hist = Join-Path $KitRoot 'Logs\Repair-History.log'
function L([string]$m, [string]$c = 'Gray') { Write-Host $m -ForegroundColor $c }
function Hist([string]$m) { "[{0}] {1}" -f (Get-Date -Format 's'), $m | Out-File $hist -Append -Encoding UTF8 }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { L 'ERRO: execute como Administrador.' 'Red'; exit 2 }

$cam  = 'SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location'
$pol  = 'SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors'
$exports = [ordered]@{
    'HKLM-consent-location.reg' = "HKLM\$cam"
    'HKCU-consent-location.reg' = "HKCU\$cam"
    'HKLM-policy-LocationAndSensors.reg' = "HKLM\$pol"
    'HKLM-lfsvc-Service.reg' = 'HKLM\SYSTEM\CurrentControlSet\Services\lfsvc\Service'
    'HKLM-svc-lfsvc.reg'  = 'HKLM\SYSTEM\CurrentControlSet\Services\lfsvc'
    'HKLM-svc-camsvc.reg' = 'HKLM\SYSTEM\CurrentControlSet\Services\camsvc'
    'HKLM-svchost.reg'    = 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Svchost'
}

if ($Revert) {
    $last = Get-ChildItem (Join-Path $KitRoot 'Backup') -Directory -Filter 'Policy-*' -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1
    if (-not $last) { L 'Nenhum backup Policy-* encontrado.' 'Red'; exit 1 }
    foreach ($f in $exports.Keys) { $p = Join-Path $last.FullName $f; if (Test-Path $p) { & reg.exe import $p 2>&1 | Out-Null; L "reimportado: $p" 'Cyan' } }
    # valor criado por este script onde antes nao existia
    $created = Join-Path $last.FullName 'created-values.txt'
    if (Test-Path $created) { foreach ($ln in Get-Content $created) { $x = $ln.Split('|'); Remove-ItemProperty -Path $x[0] -Name $x[1] -ErrorAction SilentlyContinue; L "removido valor criado: $ln" 'Cyan' } }
    # valores por usuario (todos os perfis + Default)
    $uc = Join-Path $last.FullName 'user-values.csv'
    if (Test-Path $uc) {
        . (Join-Path $PSScriptRoot 'KitProfile.ps1')
        $hives = Get-KitUserHives
        foreach ($g in (Import-Csv $uc | Group-Object Sid)) {
            $h = $hives | Where-Object { $_.Sid -eq $g.Name } | Select-Object -First 1
            if (-not $h -or -not (Mount-KitUserHive $h)) { L "AVISO revert: perfil $($g.Name) indisponivel - nao revertido" 'Yellow'; continue }
            try {
                foreach ($r in $g.Group) {
                    $p = "Registry::$($h.Root)\$($r.RelKey)"
                    if ($r.Old -eq '<ausente>') { Remove-ItemProperty -Path $p -Name $r.ValueName -ErrorAction SilentlyContinue }
                    else { Set-ItemProperty -Path $p -Name $r.ValueName -Value $r.Old -Type String -ErrorAction SilentlyContinue }
                    L ("revertido: {0} ...\{1} -> {2}" -f $r.Name, ($r.RelKey -replace '^.*\\ConsentStore\\', 'ConsentStore\'), $r.Old) 'Cyan'
                }
            } finally { Dismount-KitUserHive $h }
        }
    }
    Hist "Enable-LocationPolicy -Revert a partir de $($last.FullName)"
    L 'Revertido. Reinicie o servico lfsvc (ou o Windows) para refletir.' 'Green'; exit 0
}

$bk = Join-Path $KitRoot "Backup\Policy-$ts"
if (-not $WhatIf) {
    New-Item -ItemType Directory $bk -Force | Out-Null
    foreach ($f in $exports.Keys) { & reg.exe export $exports[$f] (Join-Path $bk $f) /y 2>&1 | Out-Null }
    L "Backup: $bk" 'Cyan'
}
$setCount = 0

$changes = @(
    @{ Path = "HKLM:\$cam";              Name = 'Value'; Want = 'Allow'; Type = 'String' },
    @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Services\lfsvc\Service\Configuration'; Name = 'Status'; Want = 1; Type = 'DWord' }
)
# Status do dispositivo so faz sentido se o servico lfsvc existir (Win10 e Win11)
if (-not (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Services\lfsvc')) {
    $changes = @($changes | Where-Object { $_.Name -ne 'Status' })
    L 'AVISO: servico lfsvc nao existe nesta maquina - Status do dispositivo nao gravado (reparar o servico primeiro).' 'Yellow'
}
$pv = Get-ItemProperty "HKLM:\$pol" -Name DisableWindowsLocationProvider -ErrorAction SilentlyContinue
if ($pv -and $pv.DisableWindowsLocationProvider -eq 1) { $changes += @{ Path = "HKLM:\$pol"; Name = 'DisableWindowsLocationProvider'; Want = 0; Type = 'DWord' } }

$err = 0
. (Join-Path $PSScriptRoot 'KitProfile.ps1')
# Servicos desativados pelo debloat (Start=4 no registro OU "Disabled" carregado no SCM): lfsvc (localizacao) e camsvc (gerenciador de permissoes).
# Volta para Manual (3 = padrao do Windows 10/11) via sc.exe; nao mexe se ja estiver 2 ou 3.
foreach ($sv in 'lfsvc', 'camsvc') {
    $sk = "HKLM:\SYSTEM\CurrentControlSet\Services\$sv"
    if (-not (Test-Path $sk)) { continue }
    $si = Get-SvcStartInfo $sv
    $st = $si.Reg
    if (-not $si.Disabled) { L ("OK    servico {0}: Start={1} SCM={2} (nao desativado)" -f $sv, $si.Reg, $si.Scm) 'Green'; continue }
    if ($si.Mismatch) { L ("AVISO servico {0}: registro Start={1} mas SCM={2} (alteracao no registro sem reinicio) -> sincronizando via sc config" -f $sv, $si.Reg, $si.Scm) 'Yellow' }
    if ($WhatIf) { L ("WHATIF servico {0}: Desativado (reg {1}/SCM {2}) -> Manual (3)" -f $sv, $si.Reg, $si.Scm) 'Yellow'; continue }
    $o = & sc.exe config $sv start= demand 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0) {
        L ("SET   servico {0}: Desativado (reg {1}/SCM {2}) -> Manual (3)" -f $sv, $si.Reg, $si.Scm) 'Cyan'; $setCount++
        Add-Content (Join-Path $bk 'changes.txt') ("servico {0}: Start {1} (SCM {2}) -> 3" -f $sv, $si.Reg, $si.Scm)
        Hist ("Enable-LocationPolicy: servico {0} Start {1} (SCM {2}) -> 3 (backup {3})" -f $sv, $si.Reg, $si.Scm, $bk)
    } else { L ("ERRO  servico {0}: sc config falhou: {1}" -f $sv, $o.Trim()) 'Red'; $err++ }
}

# lfsvc precisa constar na lista do seu grupo svchost (grupo lido do ImagePath: netsvcs no Win10,
# netsvcsRedirectionGuard no Win11 24H2+). Adiciona SOMENTE se o grupo existir e lfsvc faltar; preserva as demais.
. (Join-Path $PSScriptRoot 'KitProfile.ps1')
$grp = Get-LfsvcSvchostGroup
$needGroupRestart = $false
if (-not $grp) { L 'AVISO: ImagePath do lfsvc sem "-k <grupo>" - grupo svchost nao verificado.' 'Yellow' }
elseif (-not $grp.Exists) { L ("AVISO: grupo svchost '{0}' nao existe em Svchost - NAO criado (requer perfil desta versao)." -f $grp.Group) 'Yellow' }
elseif ($grp.Contains) { L ("OK    Svchost\{0} contem lfsvc ({1} entradas)" -f $grp.Group, $grp.Members.Count) 'Green' }
elseif ($WhatIf) { L ("WHATIF Svchost\{0}: adicionar lfsvc ({1} entradas atuais)" -f $grp.Group, $grp.Members.Count) 'Yellow' }
else {
    try {
        $new = [string[]](@($grp.Members | Where-Object { $_ }) + 'lfsvc')
        Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Svchost' -Name $grp.Group -Value $new -Type MultiString -ErrorAction Stop
        L ("SET   Svchost\{0}: lfsvc adicionado ({1} -> {2} entradas)" -f $grp.Group, $grp.Members.Count, $new.Count) 'Cyan'; $setCount++
        Add-Content (Join-Path $bk 'changes.txt') ("Svchost\{0}: lfsvc adicionado" -f $grp.Group)
        Hist ("Enable-LocationPolicy: Svchost\{0} lfsvc adicionado (backup {1})" -f $grp.Group, $bk)
        $needGroupRestart = $true
    } catch { L ("ERRO  Svchost\{0}: {1}" -f $grp.Group, $_.Exception.Message) 'Red'; $err++ }
}

foreach ($c in $changes) {
    $cur = (Get-ItemProperty $c.Path -Name $c.Name -ErrorAction SilentlyContinue).($c.Name)
    if ("$cur" -eq "$($c.Want)") { L ("OK    {0}\{1} = {2} (ja estava)" -f $c.Path, $c.Name, $cur) 'Green'; continue }
    if ($WhatIf) { L ("WHATIF {0}\{1}: '{2}' -> '{3}'" -f $c.Path, $c.Name, $cur, $c.Want) 'Yellow'; continue }
    try {
        if (-not (Test-Path $c.Path)) { New-Item -Path $c.Path -Force -ErrorAction Stop | Out-Null }
        if ($null -eq $cur) { Add-Content (Join-Path $bk 'created-values.txt') ("{0}|{1}" -f $c.Path, $c.Name) }
        Set-ItemProperty -Path $c.Path -Name $c.Name -Value $c.Want -Type $c.Type -ErrorAction Stop
        L ("SET   {0}\{1}: '{2}' -> '{3}'" -f $c.Path, $c.Name, $cur, $c.Want) 'Cyan'; $setCount++
        Add-Content (Join-Path $bk 'changes.txt') ("{0}\{1}: '{2}' -> '{3}'" -f $c.Path, $c.Name, $cur, $c.Want)
        Hist ("Enable-LocationPolicy: {0}\{1} '{2}' -> '{3}' (backup {4})" -f $c.Path, $c.Name, $cur, $c.Want, $bk)
    } catch { L ("ERRO  {0}\{1}: {2}" -f $c.Path, $c.Name, $_.Exception.Message) 'Red'; $err++ }
}

# Privacidade POR USUARIO: todos os perfis existentes + perfil modelo Default (usuarios criados depois)
$userCsv = Join-Path $bk 'user-values.csv'
foreach ($h in Get-KitUserHives) {
    if (-not (Mount-KitUserHive $h)) {
        if ($h.Skip) { L ("INFO  perfil {0}: {1}" -f $h.Name, $h.Status) 'DarkGray' } else { L ("ERRO  perfil {0}: {1} - nao alterado" -f $h.Name, $h.Status) 'Red'; $err++ }
        continue
    }
    try {
        foreach ($rel in $cam, "$cam\NonPackaged") {
            $p = "Registry::$($h.Root)\$rel"
            $lbl = "{0} [{1}] {2}" -f $h.Name, $h.Kind, ($rel -replace '^.*\\ConsentStore\\', 'ConsentStore\')
            $cur = (Get-ItemProperty $p -Name Value -ErrorAction SilentlyContinue).Value
            if ("$cur" -eq 'Allow') { L "OK    $lbl = Allow (ja estava)" 'Green'; continue }
            if ($WhatIf) { L "WHATIF $lbl : '$cur' -> 'Allow'" 'Yellow'; continue }
            try {
                if (-not (Test-Path $p)) { New-Item -Path $p -Force -ErrorAction Stop | Out-Null }
                Set-ItemProperty -Path $p -Name Value -Value 'Allow' -Type String -ErrorAction Stop
                $old = if ($null -eq $cur) { '<ausente>' } else { "$cur" }
                [pscustomobject]@{ Sid = $h.Sid; Name = $h.Name; RelKey = $rel; ValueName = 'Value'; Old = $old } | Export-Csv $userCsv -Append -NoTypeInformation -Encoding UTF8
                L "SET   $lbl : '$old' -> 'Allow'" 'Cyan'; $setCount++
                Add-Content (Join-Path $bk 'changes.txt') "$lbl : '$old' -> 'Allow'"
                Hist "Enable-LocationPolicy: $lbl '$old' -> 'Allow' (backup $bk)"
            } catch { L "ERRO  $lbl : $($_.Exception.Message)" 'Red'; $err++ }
        }
    } finally { Dismount-KitUserHive $h }
}

L 'Mantidos sem alteracao: DisableSensors, DisableLocationScripting, DisableLocation.'
if (-not $WhatIf) {
    & sc.exe stop lfsvc 2>&1 | Out-Null; Start-Sleep 2; & sc.exe start lfsvc 2>&1 | Out-Null; Start-Sleep 3
    $w = Get-CimInstance Win32_Service -Filter "Name='lfsvc'"
    if (-not $w) { L 'lfsvc ainda nao registrado no SCM (servico recriado pelo registro) - sera carregado apos reiniciar o Windows.' 'Yellow' }
    else { L "lfsvc apos reinicio: State=$($w.State) ExitCode=$($w.ExitCode) PID=$($w.ProcessId)" $(if ($w.State -eq 'Running') { 'Green' } else { 'Yellow' }) }
    L 'Politicas (HKLM\Policies) podem exigir gpupdate/reinicializacao para efeito completo.'
}
if ($needGroupRestart) { L 'REINICIE o Windows: o processo svchost do grupo so reconhece o lfsvc apos reinicializacao.' 'Yellow' }
if (-not $WhatIf -and $setCount -eq 0) { Remove-Item -LiteralPath $bk -Recurse -Force -ErrorAction SilentlyContinue; L 'Backup descartado (nenhuma alteracao feita).' }
if ($err) { exit 1 } else { exit 0 }
