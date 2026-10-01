#Requires -Version 5.1
<#
.SYNOPSIS
  Remove as POLITICAS de localizacao/sensores gravadas pelo debloat, para que a pagina
  Configuracoes > Privacidade > Localizacao deixe de ser "gerenciada pela organizacao" e
  o controle volte para o usuario/administrador pela interface.

.DESCRIPTION
  Remove SOMENTE (se existirem):
    HKLM\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors           (chave inteira)
    HKLM\SOFTWARE\WOW6432Node\Policies\Microsoft\Windows\LocationAndSensors (chave inteira)
    <usuario>\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors      (chave inteira) - em TODOS os perfis + perfil modelo Default
    HKLM\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy  valores LetAppsAccessLocation*
    HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\*  valores AllowLocation / LetAppsAccessLocation* / *Sensor*
  NAO mexe em outras politicas (telemetria, apps em segundo plano, etc.).
  Faz backup (reg export) de cada chave antes; -Revert reimporta o backup mais recente.
  Avisa se a Diretiva de Grupo Local (Registry.pol) for regravar as politicas.

.EXAMPLE
  .\Remove-LocationPolicies.ps1 -WhatIf
  .\Remove-LocationPolicies.ps1
  .\Remove-LocationPolicies.ps1 -Revert
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

. (Join-Path $PSScriptRoot 'KitProfile.ps1')

if ($Revert) {
    $last = Get-ChildItem (Join-Path $KitRoot 'Backup') -Directory -Filter 'Policies-*' -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1
    if (-not $last) { L 'Nenhum backup Policies-* encontrado.' 'Red'; exit 1 }
    Get-ChildItem $last.FullName -Filter '*.reg' | Where-Object { $_.Name -notlike '*-user-*' } | ForEach-Object { & reg.exe import $_.FullName 2>&1 | Out-Null; L "reimportado: $($_.Name)" 'Cyan' }
    $map = Join-Path $last.FullName 'user-hives.csv'
    if (Test-Path $map) {
        $hives = Get-KitUserHives
        foreach ($r in Import-Csv $map) {
            $h = $hives | Where-Object { $_.Sid -eq $r.Sid } | Select-Object -First 1
            if (-not $h -or -not (Mount-KitUserHive $h)) { L "AVISO revert: perfil $($r.Name) indisponivel - $($r.File) nao reimportado" 'Yellow'; continue }
            try { if (Import-KitUserReg (Join-Path $last.FullName $r.File) $r.Root $h.Root) { L "reimportado: $($r.File) ($($r.Name))" 'Cyan' } else { L "ERRO ao reimportar $($r.File)" 'Red' } }
            finally { Dismount-KitUserHive $h }
        }
    }
    Hist "Remove-LocationPolicies -Revert a partir de $($last.FullName)"
    L 'Politicas restauradas. Reinicie o Windows para refletir.' 'Green'; exit 0
}

$bk = Join-Path $KitRoot "Backup\Policies-$ts"
if (-not $WhatIf) { New-Item -ItemType Directory $bk -Force | Out-Null; L "Backup: $bk" 'Cyan' }
$n = 0; $removed = 0; $err = 0
function Backup-Key([string]$regPath) {
    $script:n++
    $f = Join-Path $bk ('{0:D2}-{1}.reg' -f $script:n, (($regPath -replace '^HK..\\', '') -replace '[\\ ]', '_'))
    & reg.exe export $regPath $f /y 2>&1 | Out-Null
}

# 1) Chaves LocationAndSensors inteiras
foreach ($k in 'HKLM\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors',
               'HKLM\SOFTWARE\WOW6432Node\Policies\Microsoft\Windows\LocationAndSensors') {
    $ps = 'Registry::' + ($k -replace '^HKLM', 'HKEY_LOCAL_MACHINE' -replace '^HKCU', 'HKEY_CURRENT_USER')
    if (-not (Test-Path $ps)) { continue }
    $vals = (Get-ItemProperty $ps).PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' } | ForEach-Object { "$($_.Name)=$($_.Value)" }
    if ($WhatIf) { L "WHATIF remover chave $k  [$($vals -join '; ')]" 'Yellow'; continue }
    Backup-Key $k
    try { Remove-Item $ps -Recurse -Force -ErrorAction Stop; $removed++; L "REMOVIDA $k  [$($vals -join '; ')]" 'Cyan'; Hist "Remove-LocationPolicies: removida $k [$($vals -join '; ')] (backup $bk)" }
    catch { $err++; L "ERRO  $k : $($_.Exception.Message)" 'Red' }
}

# 1b) LocationAndSensors POR USUARIO: todos os perfis existentes + perfil modelo Default (usuarios novos)
foreach ($h in Get-KitUserHives) {
    if (-not (Mount-KitUserHive $h)) {
        if ($h.Skip) { L ("INFO  perfil {0}: {1}" -f $h.Name, $h.Status) 'DarkGray' } else { L ("ERRO  perfil {0}: {1} - nao verificado" -f $h.Name, $h.Status) 'Red'; $err++ }
        continue
    }
    try {
        $ps = "Registry::$($h.Root)\$KitPolRel"
        if (-not (Test-Path $ps)) { continue }
        $lbl = "{0} [{1}] \{2}" -f $h.Name, $h.Kind, $KitPolRel
        $vals = (Get-ItemProperty $ps).PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' } | ForEach-Object { "$($_.Name)=$($_.Value)" }
        if ($WhatIf) { L "WHATIF remover chave $lbl  [$($vals -join '; ')]" 'Yellow'; continue }
        $script:n++
        $file = '{0:D2}-user-{1}.reg' -f $script:n, ($h.Sid -replace '[^\w-]', '_')
        & reg.exe export ("HKU\" + ($h.Root -replace '^HKEY_USERS\\', '') + "\$KitPolRel") (Join-Path $bk $file) /y 2>&1 | Out-Null
        [pscustomobject]@{ File = $file; Sid = $h.Sid; Name = $h.Name; Root = $h.Root } | Export-Csv (Join-Path $bk 'user-hives.csv') -Append -NoTypeInformation -Encoding UTF8
        try { Remove-Item $ps -Recurse -Force -ErrorAction Stop; $removed++; L "REMOVIDA $lbl  [$($vals -join '; ')]" 'Cyan'; Hist "Remove-LocationPolicies: removida $lbl [$($vals -join '; ')] (backup $bk)" }
        catch { $err++; L "ERRO  $lbl : $($_.Exception.Message)" 'Red' }
    } finally { Dismount-KitUserHive $h }
}

# 2) Valores especificos (AppPrivacy e PolicyManager\current\device)
$valueTargets = @()
$ap = 'HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy'
if (Test-Path "Registry::$ap") {
    (Get-ItemProperty "Registry::$ap").PSObject.Properties | Where-Object { $_.Name -like 'LetAppsAccessLocation*' } |
        ForEach-Object { $valueTargets += [pscustomobject]@{ Key = $ap; Name = $_.Name; Value = $_.Value } }
}
$pm = 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\PolicyManager\current\device'
if (Test-Path "Registry::$pm") {
    Get-ChildItem "Registry::$pm" -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        $kp = $_.Name
        (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).PSObject.Properties |
            Where-Object { $_.Name -notlike 'PS*' -and ($_.Name -match '^(AllowLocation|LetAppsAccessLocation.*|.*Sensor.*)$') } |
            ForEach-Object { $valueTargets += [pscustomobject]@{ Key = $kp; Name = $_.Name; Value = $_.Value } }
    }
}
foreach ($t in $valueTargets) {
    if ($WhatIf) { L ("WHATIF remover valor {0} [{1}={2}]" -f $t.Key, $t.Name, $t.Value) 'Yellow'; continue }
    Backup-Key $t.Key
    try { Remove-ItemProperty -Path "Registry::$($t.Key)" -Name $t.Name -ErrorAction Stop; $removed++
          L ("REMOVIDO valor {0} [{1}={2}]" -f $t.Key, $t.Name, $t.Value) 'Cyan'; Hist ("Remove-LocationPolicies: removido {0}[{1}={2}] (backup {3})" -f $t.Key, $t.Name, $t.Value, $bk) }
    catch { $err++; L ("ERRO  {0}[{1}]: {2}" -f $t.Key, $t.Name, $_.Exception.Message) 'Red' }
}
if ($removed -eq 0 -and -not $WhatIf -and $err -eq 0) { L 'Nenhuma politica de localizacao/sensores encontrada - nada a remover.' 'Green' }

# 3) Diretiva de Grupo Local: se Registry.pol contiver as politicas, o gpupdate vai regrava-las
foreach ($pol in "$env:SystemRoot\System32\GroupPolicy\Machine\Registry.pol", "$env:SystemRoot\System32\GroupPolicy\User\Registry.pol") {
    if (Test-Path $pol) {
        $txt = [Text.Encoding]::Unicode.GetString([IO.File]::ReadAllBytes($pol))
        if ($txt -match 'LocationAndSensors|LetAppsAccessLocation') {
            L "AVISO: $pol contem politicas de localizacao - o Windows pode regrava-las." 'Yellow'
            L '       Corrija em gpedit.msc > Configuracao do Computador > Modelos Administrativos > Componentes do Windows >' 'Yellow'
            L '       Local e Sensores: deixe as politicas como "Nao Configurado".' 'Yellow'
            Hist "AVISO: $pol contem LocationAndSensors/LetAppsAccessLocation"
        }
    }
}
if (-not $WhatIf) {
    & sc.exe stop lfsvc 2>&1 | Out-Null; Start-Sleep 2; & sc.exe start lfsvc 2>&1 | Out-Null
    L "Concluido: $removed item(ns) removido(s), $err erro(s). REINICIE o Windows para a pagina de Configuracoes refletir." 'Green'
}
if (-not $WhatIf -and $removed -eq 0) { Remove-Item -LiteralPath $bk -Recurse -Force -ErrorAction SilentlyContinue }
if ($err) { exit 1 } else { exit 0 }
