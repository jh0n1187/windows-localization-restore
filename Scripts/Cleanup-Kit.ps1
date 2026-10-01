#Requires -Version 5.1
<#
.SYNOPSIS
  Limpa o kit, deixando apenas o necessario para distribuicao/uso.
  Atua SOMENTE dentro da pasta do kit. Antes de apagar, valida o perfil Win10-19041 (SHA256 de todos os arquivos).

  Remove:  Extracted\  Temp\  Files\ (raiz, legado)  Registry\ (raiz, legado)
           Logs\Inventory\  Logs\Diag-*\10-wim-fulllist.txt
  Mantem:  REPARAR-E-HABILITAR.cmd  README.md  Profiles\  Scripts\  Backup\  Logs\ (historico/rollback)

  -IncludeExternal (autorizado pelo usuario): remove tambem os itens criados para o reparo FORA do kit
           e as ferramentas que so funcionavam com o WIM:
           C:\install-pro.wim  C:\lfsvc-original.reg  C:\lfsvc-restaurar.reg  C:\svchost-original.reg
           C:\Localization Restore\  Scripts\Diag-Location.ps1  Scripts\Build-KitFiles.ps1

.EXAMPLE
  .\Cleanup-Kit.ps1 -WhatIf
  .\Cleanup-Kit.ps1
#>
[CmdletBinding()]
param([switch]$WhatIf, [switch]$IncludeExternal, [string]$KitRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Continue'
$KitRoot = (Resolve-Path $KitRoot).Path.TrimEnd('\')
$hist = Join-Path $KitRoot 'Logs\Repair-History.log'
function Size($p) { if (Test-Path -LiteralPath $p) { (Get-ChildItem -LiteralPath $p -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum } else { 0 } }

# 1) Validar perfis antes de qualquer remocao
$ok = $true
foreach ($pf in Get-ChildItem (Join-Path $KitRoot 'Profiles') -Directory -ErrorAction SilentlyContinue) {
    $p = Get-Content (Join-Path $pf.FullName 'profile.json') -Raw | ConvertFrom-Json
    if ($p.Features.Files) {
        $mf = Join-Path $pf.FullName 'Files\manifest.csv'
        if (-not (Test-Path $mf)) { Write-Host "ERRO: $mf ausente" -ForegroundColor Red; $ok = $false; continue }
        foreach ($m in Import-Csv $mf) {
            $f = Join-Path $pf.FullName ("Files\" + $m.RelPath)
            if (-not (Test-Path $f) -or (Get-FileHash $f -Algorithm SHA256).Hash -ne $m.SHA256) { Write-Host "ERRO: $f ausente/hash divergente" -ForegroundColor Red; $ok = $false }
        }
    }
    if ($p.Features.ComRegistry -and -not (Test-Path (Join-Path $pf.FullName 'Registry\location-registry.json'))) { Write-Host "ERRO: location-registry.json ausente em $($pf.Name)" -ForegroundColor Red; $ok = $false }
    if ($p.Features.ServiceRegistry -and -not (Test-Path (Join-Path $pf.FullName 'Registry\lfsvc-restaurar.reg'))) { Write-Host "ERRO: lfsvc-restaurar.reg ausente em $($pf.Name)" -ForegroundColor Red; $ok = $false }
    Write-Host ("Perfil {0}: validado" -f $p.Name) -ForegroundColor Green
}
foreach ($need in 'REPARAR-E-HABILITAR.cmd','Scripts\Repair-And-Enable.ps1','Scripts\Restore-Location.ps1','Scripts\KitProfile.ps1','Scripts\Verify-Location.ps1') {
    if (-not (Test-Path (Join-Path $KitRoot $need))) { Write-Host "ERRO: $need ausente" -ForegroundColor Red; $ok = $false }
}
if (-not $ok) { Write-Host 'Validacao falhou - NADA foi removido.' -ForegroundColor Red; exit 1 }

# 2) Alvos (somente dentro do kit)
$targets = @('Extracted', 'Temp', 'Files', 'Registry', 'Logs\Inventory') | ForEach-Object { Join-Path $KitRoot $_ }
$targets += Get-ChildItem (Join-Path $KitRoot 'Logs') -Directory -Filter 'Diag-*' -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName '10-wim-fulllist.txt' }
$targets += @('Scripts\Diag-Location.ps1', 'Scripts\Build-KitFiles.ps1') | Where-Object { $IncludeExternal } | ForEach-Object { Join-Path $KitRoot $_ }
# Lista FIXA de itens externos (sem curingas) - somente com -IncludeExternal
$external = @('C:\install-pro.wim', 'C:\lfsvc-original.reg', 'C:\lfsvc-restaurar.reg', 'C:\svchost-original.reg', 'C:\Localization Restore')
if ($IncludeExternal) { $targets += $external }
$total = 0
foreach ($t in $targets) {
    if (-not (Test-Path -LiteralPath $t)) { continue }
    $full = (Resolve-Path -LiteralPath $t).Path
    $inKit = $full.StartsWith($KitRoot + '\', [StringComparison]::OrdinalIgnoreCase)
    $isExt = $IncludeExternal -and ($external -contains $full)
    if (-not ($inKit -or $isExt)) { Write-Host "IGNORADO (fora do kit e fora da lista): $full" -ForegroundColor Yellow; continue }
    $sz = Size $full; $total += $sz
    if ($WhatIf) { Write-Host ("WHATIF remover {0}  ({1:N1} MB)" -f $full, ($sz / 1MB)) -ForegroundColor Yellow; continue }
    try {
        Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
        Write-Host ("REMOVIDO {0}  ({1:N1} MB)" -f $full, ($sz / 1MB)) -ForegroundColor Cyan
        "[{0}] Cleanup-Kit: removido {1} ({2:N1} MB)" -f (Get-Date -Format 's'), $full, ($sz / 1MB) | Out-File $hist -Append -Encoding UTF8
    } catch { Write-Host "ERRO ao remover ${full}: $($_.Exception.Message)" -ForegroundColor Red }
}
Write-Host ("Total {0}: {1:N1} MB" -f $(if ($WhatIf) { 'a liberar' } else { 'liberado' }), ($total / 1MB)) -ForegroundColor Green

# 3) Estado final
Write-Host "`nConteudo do kit:" -ForegroundColor Cyan
Get-ChildItem $KitRoot -Force | ForEach-Object { "{0,-28} {1,10:N1} MB" -f ($_.Name + $(if ($_.PSIsContainer) { '\' })), ((Size $_.FullName) / 1MB) }
