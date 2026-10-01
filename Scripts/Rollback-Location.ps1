#Requires -Version 5.1
<#
.SYNOPSIS
  Desfaz uma execucao do Restore-Location.ps1 usando a pasta de backup dela.
  - Arquivos: MOVE (nao apaga) os arquivos listados em created-files.txt para <backup>\rolled-back\.
    So atua em arquivos que o proprio kit criou e cujo hash ainda confere com o manifest.
  - Registro COM: com -RemoveCreatedRegistry remove SOMENTE as chaves/valores listados em created-registry.txt
    (criados pelo proprio kit), em ordem inversa. Chaves protegidas (PKEY/PVAL, SystemSettings) sao removidas
    com SeRestorePrivilege, sem alterar dono/ACL.
  - Registro: restaura netsvcs a partir de netsvcs-before.txt e, com -RestoreServiceRegistry,
    reimporta lfsvc.reg do backup.
  Sempre pede confirmacao (use -WhatIf para simular).

.EXAMPLE
  .\Rollback-Location.ps1 -BackupFolder 'C:\Restore-Location\Backup\20261001-101500' -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)][string]$BackupFolder,
    [switch]$RestoreNetsvcs,
    [switch]$RestoreServiceRegistry,
    [switch]$RemoveCreatedRegistry,
    [string]$KitRoot = (Split-Path $PSScriptRoot -Parent)
)
$ErrorActionPreference = 'Continue'
if (-not (Test-Path $BackupFolder)) { Write-Host "Backup nao encontrado: $BackupFolder" -ForegroundColor Red; exit 1 }
$hist = Join-Path $KitRoot 'Logs\Repair-History.log'
. (Join-Path $PSScriptRoot 'KitProfile.ps1')
$KP = Get-KitProfile -KitRoot $KitRoot
$manifest = @{}
if ($KP -and $KP.Features.Files -and (Test-Path $KP.ManifestPath)) { Import-Csv $KP.ManifestPath | ForEach-Object { $manifest[(Join-Path $env:SystemRoot $_.RelPath).ToLower()] = $_.SHA256 } }

& sc.exe stop lfsvc 2>&1 | Out-Null; Start-Sleep 2

$list = Join-Path $BackupFolder 'created-files.txt'
if (Test-Path $list) {
    $dstRoot = Join-Path $BackupFolder 'rolled-back'
    foreach ($f in (Get-Content $list | Where-Object { $_ })) {
        if (-not (Test-Path -LiteralPath $f)) { Write-Host "ja ausente: $f"; continue }
        $h = (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash
        if ($manifest[$f.ToLower()] -ne $h) { Write-Host "IGNORADO (hash nao e do kit): $f" -ForegroundColor Yellow; continue }
        if ($PSCmdlet.ShouldProcess($f, 'Mover para rolled-back')) {
            $t = Join-Path $dstRoot ($f.Substring($env:SystemRoot.Length).TrimStart('\'))
            New-Item -ItemType Directory (Split-Path $t) -Force | Out-Null
            & takeown.exe /f $f /a 2>&1 | Out-Null
            & icacls.exe $f /grant '*S-1-5-32-544:F' 2>&1 | Out-Null
            Move-Item -LiteralPath $f -Destination $t -Force
            Write-Host "movido: $f" -ForegroundColor Cyan
            "[{0}] Rollback: movido {1}" -f (Get-Date -Format 's'), $f | Out-File $hist -Append -Encoding UTF8
        }
    }
} else { Write-Host 'Nenhum created-files.txt neste backup (a execucao nao criou arquivos).' }

if ($RemoveCreatedRegistry) {
    $cr = Join-Path $BackupFolder 'created-registry.txt'
    if (Test-Path $cr) {
        $hklm = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', 'Registry64')
        $lines = @(Get-Content $cr | Where-Object { $_ }); [array]::Reverse($lines)
        $privOn = $false
        if ($lines | Where-Object { $_ -like 'PKEY HKLM\*' -or $_ -like 'PVAL HKLM\*' }) { $privOn = Set-KitRestorePrivilege $true; if (-not $privOn) { Write-Host 'AVISO: SeRestorePrivilege indisponivel - chaves protegidas (SystemSettings) nao serao removidas.' -ForegroundColor Yellow } }
        foreach ($ln in $lines) {
            if ($ln -like 'PVAL HKLM\*') {
                $x = $ln.Substring(10).Split('|')
                if ($privOn -and $PSCmdlet.ShouldProcess("HKLM\$($x[0]) [$($x[1])]", 'Remover valor (chave protegida) criado pelo kit')) {
                    $t = $hklm.OpenSubKey($x[0]); if ($t) { $t.Close(); try { [KitRegPriv]::DeleteValue($x[0], $x[1]) } catch { Write-Host "ERRO HKLM\$($x[0]) [$($x[1])]: $($_.Exception.Message)" -ForegroundColor Red } }
                }
                continue
            }
            if ($ln -like 'PKEY HKLM\*') {
                $path = $ln.Substring(10); $t = $hklm.OpenSubKey($path)
                if ($t) { $empty = ($t.SubKeyCount -eq 0 -and $t.ValueCount -eq 0); $t.Close()
                    if ($privOn -and $empty -and $PSCmdlet.ShouldProcess("HKLM\$path", 'Remover chave protegida criada pelo kit')) { try { [KitRegPriv]::DeleteKey($path); Write-Host "removida: HKLM\$path" -ForegroundColor Cyan } catch { Write-Host "ERRO HKLM\$path : $($_.Exception.Message)" -ForegroundColor Red } }
                    elseif (-not $empty) { Write-Host "mantida (nao vazia): HKLM\$path" -ForegroundColor Yellow } }
                continue
            }
            if ($ln -like 'VAL  HKLM\*') {
                $x = $ln.Substring(10).Split('|'); $k = $hklm.OpenSubKey($x[0], $true)
                if ($k -and $PSCmdlet.ShouldProcess("HKLM\$($x[0]) [$($x[1])]", 'Remover valor criado pelo kit')) { $k.DeleteValue($x[1], $false) }
                if ($k) { $k.Close() }
            } elseif ($ln -like 'KEY  HKLM\*') {
                $path = $ln.Substring(10); $k = $hklm.OpenSubKey($path)
                if ($k) { $empty = ($k.SubKeyCount -eq 0 -and $k.ValueCount -eq 0); $k.Close()
                    if ($empty -and $PSCmdlet.ShouldProcess("HKLM\$path", 'Remover chave vazia criada pelo kit')) { $hklm.DeleteSubKey($path, $false) }
                    elseif (-not $empty) { Write-Host "mantida (nao vazia): HKLM\$path" -ForegroundColor Yellow } }
            }
        }
        if ($privOn) { [void](Set-KitRestorePrivilege $false) }
        Write-Host 'Registro COM criado pelo kit removido.' -ForegroundColor Cyan
    } else { Write-Host 'Nenhum created-registry.txt neste backup.' }
}

if ($RestoreNetsvcs) {
    $nb = Join-Path $BackupFolder 'netsvcs-before.txt'
    if ((Test-Path $nb) -and $PSCmdlet.ShouldProcess('Svchost\netsvcs', 'Restaurar valor anterior')) {
        $v = [string[]](Get-Content $nb | Where-Object { $_ })
        Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Svchost' -Name netsvcs -Value $v -Type MultiString
        Write-Host 'netsvcs restaurado.' -ForegroundColor Cyan
    }
}
if ($RestoreServiceRegistry) {
    $rb = Join-Path $BackupFolder 'lfsvc.reg'
    if ((Test-Path $rb) -and $PSCmdlet.ShouldProcess('Services\lfsvc', "Reimportar $rb")) { & reg.exe import $rb; Write-Host 'lfsvc.reg reimportado.' -ForegroundColor Cyan }
}
Write-Host 'Rollback concluido. Reinicie se o registro foi alterado.'
