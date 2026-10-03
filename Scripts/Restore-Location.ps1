#Requires -Version 5.1
<#
.SYNOPSIS
  Restaura o Windows Location (lfsvc) em Windows 10 2004-22H2 x64 modificados/debloated.

.DESCRIPTION
  - Usa o perfil de Profiles\<versao> escolhido pelo build (KitProfile.ps1); arquivos validados por SHA256 do manifest.csv do perfil.
  - Nunca sobrescreve arquivo existente: restaura apenas o que esta AUSENTE.
  - Faz backup em ..\Backup\<timestamp>\ antes de qualquer alteracao.
  - Restaura o registro do lfsvc apenas se estiver ausente/incompleto.
  - Adiciona lfsvc ao Svchost\netsvcs apenas se estiver ausente (preserva as demais entradas).
  - Registro COM/WinRT/sistema (location-registry.json): cria somente chaves/valores AUSENTES.
  - Registra os catalogos de assinatura do perfil (Catalogs\*.cat) e as tarefas agendadas \Microsoft\Windows\Location\*
    que estiverem ausentes.
  - NAO altera politicas de localizacao nem permissoes de privacidade (apenas reporta).
  - Idempotente: pode ser executado varias vezes.

.PARAMETER Group
  Grupos do manifest a restaurar (padrao: todos os obrigatorios 0-4).
  0=lfsvc.dll 1=LocationFramework.dll 2=MUI pt-BR 3=Framework/COM 4=UI(Configuracoes/notificacao)

.PARAMETER IncludeOptional
  Inclui o grupo 9 (opcional: modelo de politica LocationProviderAdm.admx/.adml).

.PARAMETER WhatIf
  Modo diagnostico: mostra o que seria feito, sem alterar o sistema.

.EXAMPLE
  .\Restore-Location.ps1 -WhatIf
  .\Restore-Location.ps1
  .\Restore-Location.ps1 -Group 0,1
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [int[]]$Group = @(0, 1, 2, 3, 4),
    [switch]$IncludeOptional,
    [switch]$NoServiceTest,
    [switch]$SkipComRegistry,
    [string]$KitRoot = (Split-Path $PSScriptRoot -Parent)
)

$ErrorActionPreference = 'Continue'   # nativos (reg/sc/icacls) escrevem em stderr; erros tratados com -ErrorAction Stop
$DryRun  = [bool]$WhatIfPreference
$WhatIfPreference = $false   # o modo simulacao e tratado por $DryRun; o log e o backup da propria execucao precisam ser gravados
$ts      = Get-Date -Format 'yyyyMMdd-HHmmss'
$LogDir  = Join-Path $KitRoot 'Logs'
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$Log     = Join-Path $LogDir "Restore-$ts.log"
$History = Join-Path $LogDir 'Repair-History.log'

function L([string]$m, [string]$c = 'Gray') {
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m
    Add-Content -Path $Log -Value $line -Encoding UTF8
    Write-Host $line -ForegroundColor $c
}
function Hist([string]$m) { "[{0}] {1}" -f (Get-Date -Format 's'), $m | Out-File -FilePath $History -Append -Encoding UTF8 }

# ------------------------------------------------------------------ pre-requisitos
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Host 'ERRO: execute como Administrador.' -ForegroundColor Red; exit 2 }
if (-not [Environment]::Is64BitProcess) { Write-Host 'ERRO: use o PowerShell 64-bit.' -ForegroundColor Red; exit 2 }

$cv    = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$build = [int]$cv.CurrentBuild
$arch  = $env:PROCESSOR_ARCHITECTURE
L ("Restore-Location | {0} {1} build {2}.{3} {4} | UI {5} | Modo: {6}" -f $cv.ProductName, $cv.DisplayVersion, $build, $cv.UBR, $arch, (Get-UICulture).Name, $(if ($DryRun) { 'WHATIF (sem alteracoes)' } else { 'EXECUCAO' })) 'Cyan'

. (Join-Path $PSScriptRoot 'KitProfile.ps1')
$KP = Get-KitProfile -KitRoot $KitRoot
if (-not $KP) { L "INCOMPATIVEL: nenhum perfil em $KitRoot\Profiles cobre o build $build ($arch). Abortando." 'Red'; exit 3 }
Write-KitProfileBanner $KP
$F = $KP.Features
L ("Perfil {0}: Files={1} ServiceRegistry={2} ComRegistry={3}" -f $KP.Name, [bool]$F.Files, [bool]$F.ServiceRegistry, [bool]$F.ComRegistry)
if (-not ($F.Files -or $F.ServiceRegistry -or $F.ComRegistry)) {
    L "Perfil $($KP.Name) nao suporta restauracao de arquivos/registro (somente diagnostico). Nenhuma alteracao feita por este script." 'Yellow'
    exit 0
}
$manifestPath = $KP.ManifestPath
$groups = @($Group); if ($IncludeOptional) { $groups += 9 }
if ($F.Files) {
    if (-not (Test-Path $manifestPath)) { L "manifest.csv nao encontrado em $manifestPath" 'Red'; exit 4 }
    $manifest = Import-Csv $manifestPath | Where-Object { $groups -contains [int]$_.Group }
} else { $manifest = @(); L 'Arquivos: perfil sem binarios - etapa ignorada.' 'DarkYellow' }
L ("Grupos selecionados: {0} ({1} arquivos)" -f ($groups -join ','), @($manifest).Count)

# ------------------------------------------------------------------ backup
$Backup = Join-Path $KitRoot "Backup\$ts"
$i = 1; while (Test-Path $Backup) { $Backup = Join-Path $KitRoot "Backup\$ts-$i"; $i++ }
New-Item -ItemType Directory -Path $Backup -Force | Out-Null
L "Backup: $Backup"
$regToBackup = @{
    'lfsvc.reg'              = 'HKLM\SYSTEM\CurrentControlSet\Services\lfsvc'
    'svchost.reg'            = 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Svchost'
    'policy-LocationAndSensors.reg' = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors'
    'cam-location-HKLM.reg'  = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location'
    'cam-location-HKCU.reg'  = 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location'
}
foreach ($k in $regToBackup.Keys) {
    & reg.exe export $regToBackup[$k] (Join-Path $Backup $k) /y 2>&1 | Out-Null
}
$ns0 = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Svchost' -Name netsvcs -ErrorAction SilentlyContinue).netsvcs
$ns0 | Out-File (Join-Path $Backup 'netsvcs-before.txt') -Encoding UTF8
(& sc.exe qc lfsvc 2>&1 | Out-String) + (& sc.exe queryex lfsvc 2>&1 | Out-String) | Out-File (Join-Path $Backup 'service-before.txt') -Encoding UTF8

$state = foreach ($m in $(if ($F.Files) { Import-Csv $manifestPath } else { @() })) {
    $d = Join-Path $env:SystemRoot $m.RelPath
    $e = Test-Path -LiteralPath $d
    [pscustomobject]@{ RelPath = $m.RelPath; Exists = $e
        Version = $(if ($e) { (Get-Item -LiteralPath $d).VersionInfo.FileVersion })
        SHA256  = $(if ($e) { (Get-FileHash -LiteralPath $d -Algorithm SHA256).Hash }) }
}
$state | Export-Csv (Join-Path $Backup 'files-before.csv') -NoTypeInformation -Encoding UTF8
$createdList = Join-Path $Backup 'created-files.txt'
Hist "Restore-Location iniciado ($(if ($DryRun) {'WhatIf'} else {'execucao'})) grupos $($groups -join ','). Backup: $Backup"

# ------------------------------------------------------------------ helpers
function Set-SystemFileSecurity([string]$dest) {
    $dir = Split-Path $dest
    $ref = if ($dest -like '*.mui') { Get-ChildItem $dir -Filter 'kernel32.dll.mui' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName }
           else { Join-Path $dir 'kernel32.dll' }
    if (-not $ref -or -not (Test-Path $ref)) { $ref = Join-Path $env:SystemRoot 'System32\kernel32.dll' }
    try {
        $sddl = (Get-Acl -LiteralPath $ref -ErrorAction Stop).GetSecurityDescriptorSddlForm('Access')
        $acl  = Get-Acl -LiteralPath $dest
        $acl.SetSecurityDescriptorSddlForm($sddl, 'Access')
        Set-Acl -LiteralPath $dest -AclObject $acl -ErrorAction Stop
        & icacls.exe $dest /setowner 'NT SERVICE\TrustedInstaller' 2>&1 | Out-Null
        L "    ACL/owner aplicados (referencia: $ref)"
    } catch { L "    AVISO: nao foi possivel ajustar ACL/owner: $($_.Exception.Message)" 'Yellow' }
}

# ------------------------------------------------------------------ arquivos
$created = 0; $kept = 0; $skipped = 0; $errors = 0; $regChanged = $false
foreach ($m in $manifest) {
    $src  = Join-Path $KP.FilesRoot $m.RelPath
    $dest = Join-Path $env:SystemRoot $m.RelPath
    $tag  = "G$($m.Group) $($m.RelPath)"

    if (-not (Test-Path -LiteralPath $src)) {
        # copia do kit incompleta: se o Windows ja tem o arquivo identico, nada a fazer
        if ((Test-Path -LiteralPath $dest) -and (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash -eq $m.SHA256) { L "KEEP  $tag : ja presente (identico ao manifest)" 'Green'; $kept++; continue }
        if ($m.RelPath -like '*\pt-BR\*' -and -not (Test-Path (Split-Path $dest))) { L "SKIP  $tag : idioma pt-BR nao instalado (pasta inexistente)" 'DarkYellow'; $skipped++; continue }
        L "ERRO  $tag : ausente no kit ($src) - pasta Profiles\ incompleta: copie o kit inteiro de novo" 'Red'; $errors++; continue
    }
    $srcHash = (Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash
    if ($srcHash -ne $m.SHA256) { L "ERRO  $tag : hash do kit nao confere (esperado $($m.SHA256), obtido $srcHash)" 'Red'; $errors++; continue }

    if ($m.RelPath -like '*\pt-BR\*' -and -not (Test-Path (Split-Path $dest))) {
        L "SKIP  $tag : idioma pt-BR nao instalado (pasta inexistente)" 'DarkYellow'; $skipped++; continue
    }

    if (Test-Path -LiteralPath $dest) {
        $h = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash
        if ($h -eq $m.SHA256) { L "KEEP  $tag : ja presente (identico ao kit)" 'Green' }
        else { L ("KEEP  $tag : ja presente, versao {0} (difere do kit {1}) - preservado, NAO sobrescrito" -f (Get-Item -LiteralPath $dest).VersionInfo.FileVersion, $m.Version) 'Green' }
        $kept++; continue
    }

    if (-not $DryRun) {
        try {
            Copy-Item -LiteralPath $src -Destination $dest -ErrorAction Stop
            Add-Content -Path $createdList -Value $dest -Encoding UTF8
            if ((Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash -ne $m.SHA256) { throw 'hash apos copia nao confere' }
            L "NEW   $tag : restaurado (v$($m.Version))" 'Cyan'
            Set-SystemFileSecurity $dest
            $created++
        } catch { L "ERRO  $tag : $($_.Exception.Message)" 'Red'; $errors++ }
    } else { L "WHATIF $tag : seria restaurado (ausente)" 'Yellow' }
}

# ------------------------------------------------------------------ registro do servico
$needReboot = $false
if (-not $F.ServiceRegistry) { L 'REG   lfsvc/netsvcs: perfil sem dados de servico - etapa ignorada (somente diagnostico).' 'DarkYellow' }
else {
$svcKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\lfsvc'
$p  = Get-ItemProperty "$svcKey\Parameters" -ErrorAction SilentlyContinue
$mk = Get-ItemProperty $svcKey -ErrorAction SilentlyContinue
$regOk = $p -and ($p.ServiceDll -match 'lfsvc\.dll$') -and $mk -and ($mk.ImagePath -match 'svchost\.exe -k netsvcs') -and ($mk.Type -eq 32) -and (Test-Path "$svcKey\TriggerInfo")
if ($regOk) { L 'REG   lfsvc: configuracao presente e consistente - nenhuma alteracao' 'Green' }
else {
    $regFile = Join-Path $KP.RegistryRoot 'lfsvc-restaurar.reg'
    if (-not (Test-Path $regFile)) { L "ERRO  REG lfsvc incompleto e $regFile ausente" 'Red'; $errors++ }
    elseif (-not $DryRun) {
        & reg.exe import $regFile 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { L 'REG   lfsvc: configuracao importada de Registry\lfsvc-restaurar.reg' 'Cyan'; Hist 'lfsvc-restaurar.reg importado.'; $regChanged = $true; Add-Content (Join-Path $Backup 'changes.txt') 'lfsvc-restaurar.reg importado' }
        else { L 'ERRO  REG falha ao importar lfsvc-restaurar.reg' 'Red'; $errors++ }
        if (-not (Get-Service lfsvc -ErrorAction SilentlyContinue)) { $needReboot = $true }
        else {
            # O SCM mantem a configuracao do servico em memoria e so rele o registro no boot.
            # O reg import grava Start/Type/ImagePath direto no registro: sincroniza o SCM via sc config
            # (senao sc start falha com 1058 se o SCM ainda tiver "Disabled" do debloat).
            $si = Get-SvcStartInfo 'lfsvc'
            $img = (Get-Item $svcKey).GetValue('ImagePath', $null, 'DoNotExpandEnvironmentNames')   # mantem %SystemRoot% literal
            $o = & sc.exe config lfsvc type= share start= demand binPath= "$img" 2>&1 | Out-String
            if ($LASTEXITCODE -eq 0) {
                $si2 = Get-SvcStartInfo 'lfsvc'
                L ("SCM   lfsvc: configuracao sincronizada via sc config (antes SCM={0}, agora SCM={1}; registro Start={2})" -f $si.Scm, $si2.Scm, $si2.Reg) 'Cyan'
                Add-Content (Join-Path $Backup 'changes.txt') ("lfsvc: SCM sincronizado via sc config (SCM {0} -> {1})" -f $si.Scm, $si2.Scm)
            } else { L ("AVISO SCM lfsvc: sc config falhou ({0}) - reinicie o Windows para o SCM reler o registro" -f $o.Trim()) 'Yellow' }
            # Gatilhos (TriggerInfo), dependencias e privilegios importados so sao lidos pelo SCM no boot.
            $needReboot = $true
        }
    } else { L 'WHATIF REG lfsvc: seria importado Registry\lfsvc-restaurar.reg' 'Yellow' }
}

# netsvcs
$shKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Svchost'
$ns = @((Get-ItemProperty $shKey -Name netsvcs -ErrorAction SilentlyContinue).netsvcs)
if ($ns | Where-Object { $_ -ieq 'lfsvc' }) { L "REG   netsvcs: lfsvc ja presente ($($ns.Count) entradas) - nenhuma alteracao" 'Green' }
elseif (-not $DryRun) {
    try {
        $new = @($ns | Where-Object { $_ }) + 'lfsvc'
        Set-ItemProperty -Path $shKey -Name netsvcs -Value ([string[]]$new) -Type MultiString -ErrorAction Stop
        L "REG   netsvcs: lfsvc adicionado ($($new.Count) entradas)" 'Cyan'; Hist 'lfsvc adicionado ao netsvcs.'; $regChanged = $true; Add-Content (Join-Path $Backup 'changes.txt') 'lfsvc adicionado ao netsvcs'
        $needReboot = $true
    } catch { L "ERRO  netsvcs: $($_.Exception.Message)" 'Red'; $errors++ }
} else { L 'WHATIF REG netsvcs: lfsvc seria adicionado' 'Yellow' }

}

# ------------------------------------------------------------------ registro COM / SystemSettings (aditivo)
# Fonte: Registry\location-registry.json (extraido dos hives da imagem original; as entradas "Source":"manifest" sao as
# chaves que os manifestos dos componentes de geolocalizacao declaram: ProgIDs/Interfaces/TypeLib da Location API,
# classes WinRT, notificacoes, BackgroundModel, log de eventos).
# Regras: cria somente chaves/valores AUSENTES; nunca altera valor existente; so aplica uma
# entrada se o arquivo que ela referencia existir no disco; registra tudo que criou para rollback.
$comData = Join-Path $KP.RegistryRoot 'location-registry.json'
$regCreated = Join-Path $Backup 'created-registry.txt'
$regStats = @{ keys = 0; values = 0; kept = 0; skipped = 0; diff = 0 }
if ($SkipComRegistry -or -not $F.ComRegistry) { L 'REG   COM/SystemSettings: ignorado (-SkipComRegistry ou perfil sem registro COM)' }
elseif (-not (Test-Path $comData)) { L "AVISO REG COM: $comData ausente - etapa ignorada" 'Yellow' }
else {
    $entries = Get-Content $comData -Raw -Encoding UTF8 | ConvertFrom-Json
    $hklm = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', 'Registry64')
    $sysRoot = $env:SystemRoot
    $protected = New-Object System.Collections.Generic.List[string]
    $privOn = $false; $privTried = $false; $settingsCreated = 0; $newByGroup = @{}
    foreach ($e in $entries) {
        if ($e.RequiresFile -and -not (Test-Path (Join-Path $sysRoot $e.RequiresFile))) { $regStats.skipped++; continue }
        # SystemSettings\SettingId (dono TrustedInstaller) e entradas "Protected" (WindowsRuntime, BackgroundModel...):
        # criadas com SeRestorePrivilege, sem alterar dono/ACL
        if ($e.Protected -or $e.Group -eq 'SystemSettings') {
            if ($DryRun) {
                foreach ($k in $e.Keys) {
                    $t = $null; try { $t = $hklm.OpenSubKey($k.Path) } catch { }
                    if (-not $t) { $regStats.keys++; $regStats.values += @($k.Values).Count; continue }
                    foreach ($v in @($k.Values)) { if ($null -eq $t.GetValue([string]$v.Name, $null, 'DoNotExpandEnvironmentNames')) { $regStats.values++ } else { $regStats.kept++ } }
                    $t.Close()
                }
                continue
            }
            if (-not $privOn -and -not $privTried) {
                $privTried = $true
                $privOn = Set-KitRestorePrivilege $true
                if (-not $privOn) { L 'AVISO REG: nao foi possivel ativar SeRestorePrivilege - chaves protegidas NAO criadas' 'Yellow' }
            }
            if (-not $privOn) { $protected.Add($e.Root); continue }
            $r = Restore-KitProtectedEntry $e $sysRoot $regCreated
            $regStats.keys += $r.Keys; $regStats.values += $r.Values; $regStats.kept += $r.Kept
            if ($r.Error) { L "ERRO  REG HKLM\$($e.Root) (protegida): $($r.Error)" 'Red'; $errors++ }
            elseif ($e.Group -ne 'SystemSettings') { if ($r.Keys -or $r.Values) { $newByGroup[$e.Group] = 1 + [int]$newByGroup[$e.Group] } }
            elseif ($r.Keys -or $r.Values) { L ("REG   HKLM\{0}: criada ({1} valores) com privilegio de restauracao - dono/ACL do Windows inalterados" -f $e.Root, $r.Values) 'Cyan'; $settingsCreated++ }
            continue
        }
        $rk = $hklm.OpenSubKey($e.Root)
        if ($rk) { $rk.Close(); if (-not $DryRun) { & reg.exe export "HKLM\$($e.Root)" (Join-Path $Backup ('reg-' + ($e.Root -replace '[\\{}]', '_') + '.reg')) /y 2>&1 | Out-Null } }
        foreach ($k in $e.Keys) {
            $ro = $hklm.OpenSubKey($k.Path, $false)   # somente leitura: checa existencia sem pedir escrita
            if (-not $ro) {
                if ($DryRun) { $regStats.keys++ }
                else {
                    try { $ro = $hklm.CreateSubKey($k.Path); Add-Content $regCreated "KEY  HKLM\$($k.Path)" -Encoding UTF8; $regStats.keys++ }
                    catch [System.UnauthorizedAccessException] { $protected.Add($e.Root); break }
                    catch { L "ERRO  REG criar HKLM\$($k.Path): $($_.Exception.Message)" 'Red'; $errors++; break }
                }
            }
            $rw = $null
            foreach ($v in @($k.Values)) {
                $isBin = ($v.Type -eq 'Binary')
                $data = if ($isBin) { [string]$v.Data } else { [string]$v.Data -replace '(?i)^X:\\Windows', $sysRoot }
                # atribuicao direta: "$x = if {...}" desmonta byte[] em object[] e a comparacao binaria falha
                $existing = $null
                if ($ro) { $existing = $ro.GetValue([string]$v.Name, $null, 'DoNotExpandEnvironmentNames') }
                if ($isBin -and $existing -is [byte[]]) { $existing = -join ($existing | ForEach-Object { $_.ToString('x2') }) }
                if ($null -ne $existing) {
                    if ([string]$existing -ine $data) { $regStats.diff++; L ("KEEP  REG HKLM\{0} [{1}] existente='{2}' (imagem='{3}') - preservado" -f $k.Path, $v.Name, $existing, $data) 'DarkYellow' }
                    else { $regStats.kept++ }
                    continue
                }
                if ($DryRun) { $regStats.values++; continue }
                try {
                    if (-not $rw) { $rw = $hklm.OpenSubKey($k.Path, $true) }   # escrita so quando ha valor a criar
                    if ($isBin) {
                        $bytes = [byte[]]::new($data.Length / 2)
                        for ($bi = 0; $bi -lt $bytes.Length; $bi++) { $bytes[$bi] = [Convert]::ToByte($data.Substring($bi * 2, 2), 16) }
                        $rw.SetValue([string]$v.Name, $bytes, 'Binary')
                    } else {
                        $kind = if ($v.Type -eq 'ExpandString') { 'ExpandString' } else { 'String' }
                        $rw.SetValue([string]$v.Name, $data, $kind)
                    }
                    Add-Content $regCreated ("VAL  HKLM\{0}|{1}" -f $k.Path, $v.Name) -Encoding UTF8
                    $regStats.values++
                } catch { L "ERRO  REG valor HKLM\$($k.Path)[$($v.Name)]: $($_.Exception.Message)" 'Red'; $errors++ }
            }
            if ($rw) { $rw.Close() }
            if ($ro) { $ro.Close() }
        }
    }
    if ($privOn) { [void](Set-KitRestorePrivilege $false) }
    if ($settingsCreated) { L "REG   SystemSettings: $settingsCreated controle(s) da pagina Privacidade > Localizacao registrados. Feche e reabra Configuracoes para aparecerem." 'Cyan'; Hist "SystemSettings: $settingsCreated chave(s) criadas com SeRestorePrivilege" }
    if ($newByGroup.Count) { L ('REG   entradas restauradas com privilegio de restauracao (dono/ACL do Windows inalterados): ' + (($newByGroup.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ', ')) 'Cyan' }
    foreach ($pk in ($protected | Select-Object -Unique)) {
        L "AVISO REG HKLM\$pk ausente, mas a chave pai e protegida (TrustedInstaller). NAO criada - ver README (acao manual opcional)." 'Yellow'
    }
    $verb = if ($DryRun) { 'WHATIF seriam criados' } else { 'criados' }
    L ("REG   COM/SystemSettings: {0}: {1} chaves, {2} valores | ja presentes: {3} valores | divergentes preservados: {4} | entradas ignoradas (arquivo ausente): {5}" -f $verb, $regStats.keys, $regStats.values, $regStats.kept, $regStats.diff, $regStats.skipped) $(if ($regStats.keys -or $regStats.values) { 'Cyan' } else { 'Green' })
    if (-not $DryRun -and ($regStats.keys -or $regStats.values)) { Hist ("Registro COM/SystemSettings restaurado: {0} chaves, {1} valores (lista: {2})" -f $regStats.keys, $regStats.values, $regCreated) }
}

# ------------------------------------------------------------------ catalogos de assinatura
# Os binarios do perfil nao tem assinatura embutida: so sao reconhecidos como assinados pela Microsoft se o catalogo do
# pacote deles estiver registrado. Registra somente os catalogos AUSENTES (rollback: -RemoveTasksAndCatalogs).
$catNew = 0
foreach ($c in @(Get-KitCatalogState $KP | Where-Object { -not $_.Ok })) {
    if ($DryRun) { $catNew++; continue }
    try { [KitCat]::Add($c.FullName); Add-Content (Join-Path $Backup 'changes.txt') "CATALOG $($c.Name)" -Encoding UTF8; $catNew++ }
    catch { L "AVISO catalogo $($c.Name): $($_.Exception.Message)" 'Yellow' }
}
L ("CAT   catalogos de assinatura {0}: {1}" -f $(if ($DryRun) { 'a registrar (WHATIF)' } else { 'registrados' }), $catNew) $(if ($catNew) { 'Cyan' } else { 'Green' })

# ------------------------------------------------------------------ tarefas agendadas
# \Microsoft\Windows\Location\Notifications (inicia o LocationNotificationWindows.exe = icone "localizacao em uso") e
# \Microsoft\Windows\Location\WindowsActionDialog. Registra somente as AUSENTES, e so se o executavel existir.
$taskNew = 0
foreach ($t in @(Get-KitTaskState $KP | Where-Object { -not $_.Ok })) {
    $tn = "$($t.TaskPath)$($t.TaskName)"
    if (-not $t.Applicable) { if (-not $DryRun) { L "AVISO tarefa '$tn': $($t.RequiresFile) ausente - nao registrada" 'Yellow' }; continue }
    $xml = Join-Path $KP.TasksRoot $t.File
    if (-not (Test-Path -LiteralPath $xml)) { L "ERRO  tarefa '$tn': $xml ausente no kit" 'Red'; $errors++; continue }
    if ($DryRun) { L "WHATIF tarefa '$tn' seria registrada" 'Yellow'; $taskNew++; continue }
    try {
        Register-ScheduledTask -TaskPath $t.TaskPath -TaskName $t.TaskName -Xml (Get-Content -LiteralPath $xml -Raw) -ErrorAction Stop | Out-Null
        Add-Content (Join-Path $Backup 'changes.txt') "TASK $tn" -Encoding UTF8
        L "TASK  '$tn' registrada" 'Cyan'; Hist "Tarefa agendada registrada: $tn"; $taskNew++
    } catch { L "ERRO  tarefa '$tn': $($_.Exception.Message)" 'Red'; $errors++ }
}
if (-not $taskNew) { L 'TASK  tarefas agendadas de localizacao: nenhuma a registrar' 'Green' }

# ------------------------------------------------------------------ teste do servico
$svcResult = 'NAO TESTADO'
if (-not $NoServiceTest -and -not $DryRun -and (Get-Service lfsvc -ErrorAction SilentlyContinue)) {
    L 'TEST  sc.exe start lfsvc'
    & sc.exe start lfsvc 2>&1 | Out-Null
    $w = Get-CimInstance Win32_Service -Filter "Name='lfsvc'"
    for ($t = 0; $t -lt 10 -and $w.State -eq 'Start Pending'; $t++) { Start-Sleep 1; $w = Get-CimInstance Win32_Service -Filter "Name='lfsvc'" }
    Start-Sleep 3
    $w = Get-CimInstance Win32_Service -Filter "Name='lfsvc'"
    $svcResult = "State=$($w.State) ExitCode=$($w.ExitCode) PID=$($w.ProcessId)"
    L "TEST  lfsvc: $svcResult" $(if ($w.State -eq 'Running') { 'Green' } else { 'Red' })
    (& sc.exe queryex lfsvc 2>&1 | Out-String) | Add-Content -Path $Log -Encoding UTF8
    if ($w.ExitCode -eq 126) { L '      Erro 126 persiste: rode Verify-Location.ps1 e o diagnostico de dependencias.' 'Red' }
    $si = Get-SvcStartInfo 'lfsvc'
    if ($w.State -ne 'Running' -and $si.Disabled) { L ("      lfsvc desativado no SCM (SCM={0}, registro Start={1}) - a etapa B (Enable-LocationPolicy) corrige via sc config." -f $si.Scm, $si.Reg) 'Yellow' }
}

# ------------------------------------------------------------------ politicas (somente leitura)
$pol = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors' -ErrorAction SilentlyContinue
$cam = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location' -ErrorAction SilentlyContinue).Value
if ($pol) { foreach ($n in 'DisableLocation','DisableWindowsLocationProvider','DisableLocationScripting','DisableSensors') {
    if ($pol.$n -eq 1) { L "WARN  Politica LocationAndSensors\$n = 1 (bloqueia parte da localizacao) - nao alterado aqui (etapas B/C do REPARAR-E-HABILITAR tratam)" 'Yellow' } } }
if ($cam -eq 'Deny') { L 'WARN  CapabilityAccessManager\location (HKLM) = Deny - localizacao desativada para o dispositivo - nao alterado aqui (etapa B do REPARAR-E-HABILITAR trata)' 'Yellow' }

# ------------------------------------------------------------------ resumo
L ''
L ("RESUMO: restaurados={0} mantidos={1} ignorados={2} erros={3} | servico: {4}" -f $created, $kept, $skipped, $errors, $svcResult) 'Cyan'
if ($created -gt 0) { L "Arquivos criados nesta execucao listados em: $createdList (usado pelo rollback)" }
if ($needReboot) { L 'REINICIALIZACAO NECESSARIA: a configuracao do servico/netsvcs foi alterada.' 'Yellow' }
else { L 'Reinicializacao: nao necessaria.' }
Hist ("Restore-Location concluido: restaurados={0} mantidos={1} ignorados={2} erros={3} servico={4} reboot={5}" -f $created, $kept, $skipped, $errors, $svcResult, $needReboot)
# Backup so e mantido se esta execucao alterou algo (e o que o rollback usa)
$madeChanges = (-not $DryRun) -and ($created -gt 0 -or $regChanged -or $regStats.keys -gt 0 -or $regStats.values -gt 0 -or $catNew -gt 0 -or $taskNew -gt 0)
if ($madeChanges) { Copy-Item $Log $Backup -ErrorAction SilentlyContinue }
else { Remove-Item -LiteralPath $Backup -Recurse -Force -ErrorAction SilentlyContinue; L 'Backup desta execucao descartado (nenhuma alteracao feita).' }
if ($errors) { exit 1 } else { exit 0 }
