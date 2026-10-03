#Requires -Version 5.1
<#
.SYNOPSIS
  Execucao completa e INTELIGENTE do kit: primeiro DIAGNOSTICA o que falta na maquina e
  depois executa SOMENTE as etapas necessarias.

  Etapas possiveis (cada uma so roda se o diagnostico apontar necessidade):
    A) Restore-Location.ps1        - arquivos ausentes, registro do lfsvc/netsvcs, registro COM/WinRT ausente,
                                     catalogos de assinatura e tarefas agendadas de localizacao
    B) Enable-LocationPolicy.ps1   - ConsentStore (Allow) e estado do dispositivo (Status=1);
                                     parte por usuario em TODOS os perfis + perfil modelo Default (novos usuarios)
    C) Remove-LocationPolicies.ps1 - politicas de localizacao/sensores do debloat
    D) Verify-Location.ps1 -Functional (sempre, somente leitura)
    E) Limpeza final (sempre, exceto -CheckOnly): descarta backups sem alteracoes e logs antigos

  Nenhum arquivo existente e sobrescrito (Restore-Location valida hash/existencia de cada item).

.PARAMETER CheckOnly  So diagnostica e mostra o plano; nao altera nada.
.PARAMETER NoEnable   Nao executa B e C (nao mexe em privacidade/politicas).
.PARAMETER Force      Executa A, B e C mesmo que o diagnostico diga que nao e necessario (continuam idempotentes).
#>
[CmdletBinding()]
param([switch]$CheckOnly, [switch]$NoEnable, [switch]$Force)
$ErrorActionPreference = 'Continue'
Set-Location $PSScriptRoot
$KitRoot = Split-Path $PSScriptRoot -Parent
$hist = Join-Path $KitRoot 'Logs\Repair-History.log'
New-Item -ItemType Directory -Path (Join-Path $KitRoot 'Logs') -Force | Out-Null
function Hist([string]$m) { "[{0}] {1}" -f (Get-Date -Format 's'), $m | Out-File $hist -Append -Encoding UTF8 }

# ---- status final (sempre a ultima coisa no log)
$runStart = Get-Date
$steps = New-Object System.Collections.Generic.List[object]
function Step([string]$name, [string]$res, [string]$det = '') { $steps.Add([pscustomobject]@{ Etapa = $name; Resultado = $res; Detalhe = $det }) }
function Write-FinalStatus([string]$status, [string[]]$motivos = @(), [string[]]$acoes = @(), [int]$code = 0) {
    $cor = switch -Wildcard ($status) { 'SUCESSO COM*' { 'Yellow'; break } 'REINICIO*' { 'Yellow'; break } 'SUCESSO*' { 'Green'; break } 'DIAGNOSTICO*' { 'Cyan'; break } default { 'Red' } }
    Write-Host ''
    Write-Host '==================================================================' -ForegroundColor $cor
    Write-Host ("  RESULTADO FINAL: {0}" -f $status) -ForegroundColor $cor
    Write-Host '==================================================================' -ForegroundColor $cor
    Write-Host ("  Maquina: {0} | build {1} | perfil {2} | {3}" -f $env:COMPUTERNAME, $(if ($cv) { "$($cv.CurrentBuild).$($cv.UBR)" } else { '?' }), $(if ($KP) { $KP.Name } else { '-' }), (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    if ($steps.Count) {
        Write-Host '  Etapas:'
        foreach ($st in ($steps | Sort-Object Etapa)) {
            $c = switch -Wildcard ($st.Resultado) { '*avisos*' { 'Yellow'; break } 'OK*' { 'Green'; break } 'PASS*' { 'Green'; break } 'IGNORADO*' { 'DarkGray'; break } 'NAO NECESSARIO*' { 'DarkGray'; break } default { 'Red' } }
            Write-Host ("    {0} {1}{2}" -f ($st.Etapa + ' ').PadRight(38, '.'), $st.Resultado, $(if ($st.Detalhe) { " - $($st.Detalhe)" })) -ForegroundColor $c
        }
    }
    if ($motivos) { Write-Host $(if ($status -like 'SUCESSO*' -or $status -like 'REINICIO*') { '  Avisos:' } else { '  Motivos:' }) -ForegroundColor $cor; $motivos | ForEach-Object { Write-Host "    - $_" -ForegroundColor $cor } }
    if ($acoes)   { Write-Host '  Proximos passos:' -ForegroundColor Yellow; $acoes | ForEach-Object { Write-Host "    - $_" -ForegroundColor Yellow } }
    Write-Host ("  Codigo de saida: {0} (0 = sucesso, 3010 = sucesso - falta reiniciar, 1 = falha, 2/3 = abortado)" -f $code)
    Write-Host '==================================================================' -ForegroundColor $cor
    Hist ("RESULTADO FINAL: {0} (codigo {1}){2}" -f $status, $code, $(if ($motivos) { ' | ' + ($motivos -join '; ') }))
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Host 'ERRO: execute como Administrador.' -ForegroundColor Red; Write-FinalStatus 'FALHA (ABORTADO)' @('Sem privilegio de Administrador') @('Execute o REPARAR-E-HABILITAR.cmd e aceite o UAC') 2; exit 2 }
if (-not [Environment]::Is64BitProcess) { Write-Host 'ERRO: use o PowerShell 64-bit.' -ForegroundColor Red; Write-FinalStatus 'FALHA (ABORTADO)' @('PowerShell 32-bit') @('Use o PowerShell 64-bit') 2; exit 2 }

$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$b = [int]$cv.CurrentBuild
Write-Host ("Maquina: {0} | {1} {2} build {3}.{4} {5}" -f $env:COMPUTERNAME, $cv.ProductName, $cv.DisplayVersion, $b, $cv.UBR, $env:PROCESSOR_ARCHITECTURE) -ForegroundColor Cyan
. (Join-Path $PSScriptRoot 'KitProfile.ps1')
$KP = Get-KitProfile -KitRoot $KitRoot
if (-not $KP) { Write-Host "INCOMPATIVEL: nenhum perfil em Profiles\ cobre o build $b ($env:PROCESSOR_ARCHITECTURE). Nada foi alterado." -ForegroundColor Red; Write-FinalStatus 'FALHA (ABORTADO)' @("Nenhum perfil cobre o build $b") @('Nada foi alterado') 3; exit 3 }
Write-KitProfileBanner $KP
$KF = $KP.Features

# =====================================================================  DIAGNOSTICO
Write-Host "`n========== DIAGNOSTICO (somente leitura) ==========" -ForegroundColor Cyan
$findings = New-Object System.Collections.Generic.List[object]
function F([string]$area, [string]$item, [bool]$ok, [string]$step, [bool]$supported = $true) {
    $st = if ($ok) { 'OK' } elseif ($supported) { 'FALTA' } else { 'FALTA (perfil nao corrige)' }
    $findings.Add([pscustomobject]@{ Area = $area; Item = $item; Status = $st; Etapa = $(if ($ok -or -not $supported) { '' } else { $step }) })
}
$sys = $env:SystemRoot

# A1) arquivos
if ($KF.Files -and (Test-Path $KP.ManifestPath)) {
    $manifest = Import-Csv $KP.ManifestPath | Where-Object { $_.Required -eq 'Required' }
    foreach ($m in $manifest) {
        $d = Join-Path $sys $m.RelPath
        if ($m.RelPath -like '*\pt-BR\*' -and -not (Test-Path (Split-Path $d))) { continue }   # idioma nao instalado
        F 'Arquivo' $m.RelPath (Test-Path -LiteralPath $d) 'A'
    }
} else {
    $manifest = @()
    foreach ($f in 'System32\lfsvc.dll','System32\LocationFramework.dll','System32\Geolocation.dll','System32\LocationApi.dll') {
        F 'Arquivo' $f (Test-Path (Join-Path $sys $f)) 'A' $false
    }
}
# A2) registro do servico + netsvcs
$sk = 'HKLM:\SYSTEM\CurrentControlSet\Services\lfsvc'
$p = Get-ItemProperty "$sk\Parameters" -ErrorAction SilentlyContinue
$s = Get-ItemProperty $sk -ErrorAction SilentlyContinue
F 'Servico' 'Services\lfsvc (ServiceDll/ImagePath/TriggerInfo)' ([bool]($p -and $p.ServiceDll -match 'lfsvc\.dll$' -and $s -and $s.ImagePath -match 'svchost\.exe -k netsvcs' -and (Test-Path "$sk\TriggerInfo"))) 'A' ([bool]$KF.ServiceRegistry)
$ns = @((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Svchost' -Name netsvcs -ErrorAction SilentlyContinue).netsvcs)
$grp = Get-LfsvcSvchostGroup
if ($grp) {
    if ($grp.Exists) { F 'Servico' ("Svchost\{0} (grupo do ImagePath) contem lfsvc" -f $grp.Group) $grp.Contains 'B' }
    else { F 'Servico' ("Svchost\{0} (grupo do ImagePath) existe" -f $grp.Group) $false 'B' $false }
} else { F 'Servico' 'Svchost\netsvcs contem lfsvc' ([bool]($ns | Where-Object { $_ -ieq 'lfsvc' })) 'A' ([bool]$KF.ServiceRegistry) }
# A3) registro COM + SystemSettings (controles da pagina Configuracoes; chave protegida, restaurada com SeRestorePrivilege)
$hk = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', 'Registry64')
if ($KF.ComRegistry) {
    $comMissing = @{}
    $entries = Get-Content (Join-Path $KP.RegistryRoot 'location-registry.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($e in $entries) {
        if ($e.RequiresFile -and -not (Test-Path (Join-Path $sys $e.RequiresFile))) {
            # arquivo sera restaurado na etapa A -> a entrada tambem sera
            if (-not ($manifest | Where-Object { $_.RelPath -ieq $e.RequiresFile })) { continue }
        }
        $bad = $false
        foreach ($k in $e.Keys) {
            $r = $null; try { $r = $hk.OpenSubKey($k.Path) } catch { continue }   # chave existe mas nao pode ser lida: nao conta como ausente
            if (-not $r) { $bad = $true; break }
            foreach ($v in @($k.Values)) { if ($null -eq $r.GetValue([string]$v.Name, $null, 'DoNotExpandEnvironmentNames')) { $bad = $true } }
            $r.Close(); if ($bad) { break }
        }
        if ($bad) { $comMissing[$e.Group] = 1 + [int]$comMissing[$e.Group] }
    }
    # grupos: COM-* (classes, interfaces, ProgIDs, TypeLib), WinRT (Windows.Devices.Geolocation), Sistema (notificacoes,
    # BackgroundModel, log de eventos, definicoes de capability/politica), SystemSettings (controles da pagina Configuracoes)
    foreach ($g in @($entries | ForEach-Object { $_.Group } | Select-Object -Unique)) {
        $area = switch -Wildcard ($g) { 'SystemSettings' { 'Configuracoes' } 'COM-*' { 'Registro COM' } default { 'Registro' } }
        F $area ("{0}{1}" -f $g, $(if ($comMissing[$g]) { " ($($comMissing[$g]) ausente(s))" })) (-not $comMissing[$g]) 'A'
    }
} else {
    # perfil sem dados COM: apenas diagnostica a classe COM "lfsvc" (ponte WinRT -> servico)
    F 'Registro COM' 'Classe COM lfsvc {08D9DFDF...} + AppID {020FB939...}' ((Test-Path 'HKLM:\SOFTWARE\Classes\CLSID\{08D9DFDF-C6F7-404A-A20F-66EEC0A609CD}') -and (Test-Path 'HKLM:\SOFTWARE\Classes\AppID\{020FB939-2C8B-4DB7-9E90-9527966E38E5}')) 'A' $false
}
# A4) tarefas agendadas e catalogos de assinatura (somente perfis que os trazem)
if ($KF.Files) {
    foreach ($t in @(Get-KitTaskState $KP)) {
        # sem o executavel a tarefa nao se aplica - a menos que a etapa A va restaura-lo
        if (-not $t.Applicable -and -not ($manifest | Where-Object { $_.RelPath -ieq $t.RequiresFile })) { continue }
        F 'Tarefa' ("{0}{1}" -f $t.TaskPath, $t.TaskName) $t.Ok 'A'
    }
    $catSt = @(Get-KitCatalogState $KP)
    if ($catSt.Count) { $catMiss = @($catSt | Where-Object { -not $_.Ok }).Count; F 'Assinatura' ("catalogos dos binarios registrados{0}" -f $(if ($catMiss) { " ($catMiss de $($catSt.Count) ausente(s))" })) (-not $catMiss) 'A' }
}
# B) privacidade / estado do dispositivo
$cam ='SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location'
F 'Privacidade' 'Dispositivo (HKLM ConsentStore) = Allow' ((Get-ItemProperty "HKLM:\$cam" -ErrorAction SilentlyContinue).Value -eq 'Allow') 'B'
# por usuario: TODOS os perfis existentes + perfil modelo Default (usuarios novos)
$userStates = @(Get-KitUserLocationState)
foreach ($u in $userStates) {
    if (-not $u.Loaded) {
        if (-not $u.Skip) { Write-Host ("AVISO perfil {0}: {1}" -f $u.Label, $u.Status) -ForegroundColor Yellow; F 'Privacidade' ("{0} (perfil nao carregado)" -f $u.Label) $false 'B' }
        continue
    }
    F 'Privacidade' ("{0} apps = Allow" -f $u.Label) ($u.Value -eq 'Allow') 'B'
    F 'Privacidade' ("{0} apps desktop = Allow" -f $u.Label) ($u.NonPackaged -eq 'Allow') 'B'
}
foreach ($sv in 'lfsvc', 'camsvc') {
    $si = Get-SvcStartInfo $sv
    if ($null -ne $si.Reg -or $si.Scm) { F 'Servico' ("{0} nao desativado (registro Start={1}; SCM={2})" -f $sv, $si.Reg, $si.Scm) (-not $si.Disabled) 'B' }
}
F 'Privacidade' 'lfsvc\Service\Configuration Status = 1' ((Get-ItemProperty "$sk\Service\Configuration" -ErrorAction SilentlyContinue).Status -eq 1) 'B'
# C) politicas
$polKey = Test-Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors'
$polUsers = @($userStates | Where-Object { $_.PolicyKey } | ForEach-Object { $_.Name })
$apLoc = @((Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy' -ErrorAction SilentlyContinue).PSObject.Properties | Where-Object { $_.Name -like 'LetAppsAccessLocation*' }).Count
$pmLoc = 0
if (Test-Path 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device') {
    Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device' -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        $pmLoc += @((Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).PSObject.Properties | Where-Object { $_.Name -match '^(AllowLocation|LetAppsAccessLocation.*|.*Sensor.*)$' }).Count
    }
}
F 'Politicas' 'Policies\...\LocationAndSensors (HKLM) ausente' (-not $polKey) 'C'
F 'Politicas' ('Policies\...\LocationAndSensors (usuarios) ausente' + $(if ($polUsers) { ' - presente em: ' + ($polUsers -join ', ') })) (-not $polUsers) 'C'
F 'Politicas' 'AppPrivacy\LetAppsAccessLocation* ausente' ($apLoc -eq 0) 'C'
F 'Politicas' 'PolicyManager AllowLocation/LetAppsAccessLocation ausente' ($pmLoc -eq 0) 'C'
# servico
$svc = Get-CimInstance Win32_Service -Filter "Name='lfsvc'" -ErrorAction SilentlyContinue
F 'Servico' 'lfsvc registrado no SCM' ([bool]$svc) 'A' ([bool]$KF.ServiceRegistry)

$findings | Format-Table Area, Item, Status, Etapa -AutoSize | Out-String -Width 200 | Write-Host
$need = @{ A = [bool]($findings | Where-Object Etapa -eq 'A'); B = [bool]($findings | Where-Object Etapa -eq 'B'); C = [bool]($findings | Where-Object Etapa -eq 'C') }
if ($Force) { $need.A = $true; $need.B = $true; $need.C = $true }
if ($NoEnable) { $need.B = $false; $need.C = $false }
if (-not ($KF.Files -or $KF.ServiceRegistry -or $KF.ComRegistry)) { $need.A = $false }
if (-not $KF.Consent) { $need.B = $false }
if (-not $KF.Policies) { $need.C = $false }
$unsupported = @($findings | Where-Object { $_.Status -like 'FALTA (perfil*' })

Write-Host '========== PLANO ==========' -ForegroundColor Cyan
Write-Host ("A) Restaurar arquivos/registro .......... {0}" -f $(if ($need.A) { 'EXECUTAR' } else { 'nao necessario' }))
Write-Host ("B) Habilitar privacidade/dispositivo .... {0}" -f $(if ($need.B) { 'EXECUTAR' } elseif ($NoEnable) { 'ignorado (-NoEnable)' } else { 'nao necessario' }))
Write-Host ("C) Remover politicas de localizacao ..... {0}" -f $(if ($need.C) { 'EXECUTAR' } elseif ($NoEnable) { 'ignorado (-NoEnable)' } else { 'nao necessario' }))
Write-Host  "D) Verificacao final .................... sempre (somente leitura)"
Write-Host  "E) Limpeza final ....................... sempre (exceto -CheckOnly)"
if ($unsupported) {
    Write-Host "`nATENCAO: $($unsupported.Count) item(ns) ausente(s) que o perfil $($KP.Name) NAO corrige (falta perfil com binarios/registro desta versao):" -ForegroundColor Yellow
    $unsupported | ForEach-Object { Write-Host "  - $($_.Area): $($_.Item)" -ForegroundColor Yellow }
}
Hist ("Repair-And-Enable diagnostico: A={0} B={1} C={2} (CheckOnly={3} Force={4} NoEnable={5})" -f $need.A, $need.B, $need.C, [bool]$CheckOnly, [bool]$Force, [bool]$NoEnable)

if ($CheckOnly) {
    Write-Host "`n-CheckOnly: nada foi alterado." -ForegroundColor Yellow
    $pend = @($findings | Where-Object { $_.Status -ne 'OK' })
    Write-FinalStatus 'DIAGNOSTICO (nada alterado)' @($pend | ForEach-Object { "$($_.Area): $($_.Item) [$($_.Status)]" }) @($(if ($pend) { 'Rode sem -CheckOnly para corrigir' })) 0
    exit 0
}

# =====================================================================  EXECUCAO
$changed = $false; $policiesRemoved = $false
if ($need.A) {
    Write-Host "`n========== A) Restore-Location ==========" -ForegroundColor Cyan
    & .\Restore-Location.ps1 -NoServiceTest
    $rc = $LASTEXITCODE
    if ($rc -ge 2) {
        Write-Host "Restore-Location abortou (codigo ${rc}). Nada mais sera feito." -ForegroundColor Red
        Step 'A) Restaurar arquivos/registro' 'ABORTADO' "codigo $rc"
        Write-FinalStatus 'FALHA (ABORTADO)' @("Restore-Location abortou com codigo $rc (sistema incompativel ou sem permissao)") @('Veja a secao A) acima no log') $rc
        exit $rc
    }
    if ($rc -eq 1) { Write-Host 'Restore-Location terminou com erros - veja o log acima.' -ForegroundColor Yellow; Step 'A) Restaurar arquivos/registro' 'ERRO' 'veja a secao A) no log' }
    else { Step 'A) Restaurar arquivos/registro' 'OK' }
    $changed = $true
}
if ($need.B) {
    Write-Host "`n========== B) Enable-LocationPolicy ==========" -ForegroundColor Cyan
    & .\Enable-LocationPolicy.ps1
    if ($LASTEXITCODE -eq 0) { Step 'B) Habilitar privacidade/servicos' 'OK' } else { Step 'B) Habilitar privacidade/servicos' 'ERRO' "codigo $LASTEXITCODE - veja a secao B) no log" }
    $changed = $true
}
if ($need.C) {
    Write-Host "`n========== C) Remove-LocationPolicies ==========" -ForegroundColor Cyan
    & .\Remove-LocationPolicies.ps1
    if ($LASTEXITCODE -eq 0) { Step 'C) Remover politicas' 'OK' } else { Step 'C) Remover politicas' 'ERRO' "codigo $LASTEXITCODE - veja a secao C) no log" }
    $changed = $true; $policiesRemoved = $true
}
if ($changed -and -not $need.B -and -not $need.C) {
    # A registra a classe COM do lfsvc: o servico precisa reiniciar para publica-la
    & sc.exe stop lfsvc 2>&1 | Out-Null; Start-Sleep 2; & sc.exe start lfsvc 2>&1 | Out-Null; Start-Sleep 2
}
if (-not $changed) { Write-Host "`nNenhuma correcao necessaria - a maquina ja esta reparada." -ForegroundColor Green }

Write-Host "`n========== D) Verify-Location -Functional ==========" -ForegroundColor Cyan
& .\Verify-Location.ps1 -Functional
$vrc = $LASTEXITCODE
$svcWasMissing = [bool]($findings | Where-Object { $_.Area -eq 'Servico' -and $_.Status -eq 'FALTA' })
if ($policiesRemoved -or $svcWasMissing) {
    Write-Host "`nREINICIE o Windows para a pagina Configuracoes > Privacidade > Localizacao refletir as mudancas." -ForegroundColor Yellow
}
Write-Host "`n========== E) Limpeza final ==========" -ForegroundColor Cyan
Invoke-KitHousekeeping -KitRoot $KitRoot
Hist ("Repair-And-Enable concluido: A={0} B={1} C={2} verify_exit={3}" -f $need.A, $need.B, $need.C, $vrc)

# ---- consolidacao do resultado
foreach ($e in @(@('A','A) Restaurar arquivos/registro'), @('B','B) Habilitar privacidade/servicos'), @('C','C) Remover politicas'))) {
    if (-not $need[$e[0]]) { Step $e[1] $(if ($NoEnable -and $e[0] -ne 'A') { 'IGNORADO (-NoEnable)' } else { 'NAO NECESSARIO' }) }
}
$vLog = Get-ChildItem (Join-Path $KitRoot 'Logs') -Filter 'Verify-*.log' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $runStart } | Sort-Object LastWriteTime | Select-Object -Last 1
$vOverall = $null; $vProblems = @()
if ($vLog) {
    $vt = Get-Content $vLog.FullName -Encoding UTF8
    $m = $vt | Select-String -Pattern '^Overall \.+ (.+)$' | Select-Object -Last 1
    if ($m) { $vOverall = $m.Matches[0].Groups[1].Value.Trim() }
    $vProblems = @($vt | Where-Object { $_ -match '^\s*\[(FAIL|WARN)\]' } | ForEach-Object { $_.Trim() })
}
if (-not $vOverall) { $vOverall = $(if ($vrc -eq 0) { 'PASS' } else { 'FAIL' }) }
Step 'D) Verificacao final' $vOverall $(if ($vLog) { $vLog.Name })

$erros  = @($steps | Where-Object { $_.Resultado -match '^(ERRO|ABORTADO)' })
# etapa A: so pede reinicio se o proprio Restore-Location disse que e necessario
$restoreReboot = $false
if ($need.A) {
    $rLog = Get-ChildItem (Join-Path $KitRoot 'Logs') -Filter 'Restore-*.log' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $runStart } | Sort-Object LastWriteTime | Select-Object -Last 1
    $restoreReboot = if ($rLog) { [bool](Select-String -Path $rLog.FullName -Pattern 'REINICIALIZACAO NECESSARIA' -SimpleMatch -Quiet) } else { $true }
}
$reboot = $policiesRemoved -or $svcWasMissing -or $restoreReboot
$motivos = @(); $acoes = @()
$motivos += @($erros | ForEach-Object { "$($_.Etapa): $($_.Resultado) $($_.Detalhe)".Trim() })
$motivos += $vProblems
if ($reboot) { $acoes += 'Reinicie o Windows e rode o REPARAR-E-HABILITAR.cmd de novo para confirmar' }

# FAILs que sao apenas consequencia de reinicio pendente (servico recriado pelo registro: o SCM so o carrega no boot)
$vFails = @($vProblems | Where-Object { $_ -match '^\[FAIL\]' })
$onlyPending = $reboot -and $vFails.Count -gt 0 -and -not ($vFails | Where-Object { $_ -notmatch '^\[FAIL\] Service (registration|start|config)' })
if (-not $erros -and $onlyPending) {
    $status = 'REINICIO NECESSARIO'; $code = 3010
    $motivos = @('Tudo foi restaurado; o servico lfsvc foi recriado pelo registro e o Windows so o reconhece apos reiniciar') + $motivos
} elseif ($erros -or $vOverall -eq 'FAIL' -or $vrc -ne 0) {
    $status = 'FALHA'; $code = 1
    if (-not $acoes) { $acoes += 'Envie este log para analise' }
} elseif ($vOverall -like '*avisos*' -or $reboot) {
    $status = 'SUCESSO COM AVISOS'; $code = 0
} else { $status = 'SUCESSO'; $code = 0 }
Write-FinalStatus $status $motivos $acoes $code
exit $code
