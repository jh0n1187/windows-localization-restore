#Requires -Version 5.1
<#
.SYNOPSIS
  Monta Profiles\Win10-19041\Files\ (binarios do Windows Location) a partir de uma imagem OFICIAL do Windows 10.
  Os binarios nao sao distribuidos no repositorio (sao arquivos da Microsoft); cada arquivo copiado e validado
  pelo SHA256 do manifest.csv - so entra no kit se for byte a byte igual ao usado nos testes.

.DESCRIPTION
  Fonte (use UMA):
    -ImageRoot <pasta>  raiz de uma imagem ja montada/extraida (a pasta que contem Windows\System32)
    -Wim <arquivo> [-Index n]  install.wim: monta somente leitura com DISM em pasta temporaria e desmonta (/Discard)
  Requisitos da imagem: Windows 10 2004-22H2 x64 com os arquivos 10.0.19041.3636 (ex.: midia 22H2 de nov/2023, build 19045.3636)
  e idioma pt-BR para os .mui. Arquivo com hash diferente NAO e copiado (o relatorio mostra qual faltou).
  install.esd (Media Creation Tool) precisa ser convertido antes:
    dism /Export-Image /SourceImageFile:install.esd /SourceIndex:<n> /DestinationImageFile:install.wim /Compress:max /CheckIntegrity

.EXAMPLE
  .\Build-KitFiles.ps1 -Wim D:\sources\install.wim -Index 6
  .\Build-KitFiles.ps1 -ImageRoot C:\mount\win10
#>
[CmdletBinding(DefaultParameterSetName = 'Root')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Root')][string]$ImageRoot,
    [Parameter(Mandatory = $true, ParameterSetName = 'Wim')][string]$Wim,
    [Parameter(ParameterSetName = 'Wim')][int]$Index = 0,
    [string]$ProfileName = 'Win10-19041',
    [string]$KitRoot = (Split-Path $PSScriptRoot -Parent)
)
$ErrorActionPreference = 'Stop'
$prof = Join-Path $KitRoot "Profiles\$ProfileName"
$manifestPath = Join-Path $prof 'Files\manifest.csv'
if (-not (Test-Path $manifestPath)) { Write-Host "manifest nao encontrado: $manifestPath" -ForegroundColor Red; exit 2 }
$manifest = Import-Csv $manifestPath
$mount = $null

try {
    if ($PSCmdlet.ParameterSetName -eq 'Wim') {
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if (-not $isAdmin) { Write-Host 'ERRO: montar o WIM exige Administrador.' -ForegroundColor Red; exit 2 }
        if (-not (Test-Path -LiteralPath $Wim)) { Write-Host "WIM nao encontrado: $Wim" -ForegroundColor Red; exit 2 }
        if ($Index -le 0) {
            Write-Host 'Indices disponiveis no WIM:' -ForegroundColor Cyan
            Get-WindowsImage -ImagePath $Wim | ForEach-Object { Write-Host ("  {0}: {1} ({2})" -f $_.ImageIndex, $_.ImageName, $_.ImageDescription) }
            Write-Host 'Rode de novo com -Index <n> (ex.: a edicao Pro).' -ForegroundColor Yellow; exit 1
        }
        $mount = Join-Path $env:TEMP ('kitwim-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory $mount | Out-Null
        Write-Host "Montando $Wim (indice $Index) em $mount (somente leitura)..." -ForegroundColor Cyan
        Mount-WindowsImage -ImagePath $Wim -Index $Index -Path $mount -ReadOnly | Out-Null
        $ImageRoot = $mount
    }
    $win = Join-Path $ImageRoot 'Windows'
    if (-not (Test-Path $win)) { Write-Host "Pasta Windows nao encontrada em $ImageRoot" -ForegroundColor Red; exit 2 }

    $ok = 0; $bad = @()
    foreach ($m in $manifest) {
        $src = Join-Path $win $m.RelPath
        $dst = Join-Path $prof ('Files\' + $m.RelPath)
        $tag = "G$($m.Group) $($m.RelPath) ($($m.Required))"
        if (-not (Test-Path -LiteralPath $src)) { $bad += [pscustomobject]@{ Arquivo = $tag; Motivo = 'ausente na imagem' }; continue }
        $h = (Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash
        if ($h -ne $m.SHA256) { $bad += [pscustomobject]@{ Arquivo = $tag; Motivo = "hash diferente (versao da imagem nao e a do manifest: $($m.Version))" }; continue }
        New-Item -ItemType Directory (Split-Path $dst) -Force | Out-Null
        Copy-Item -LiteralPath $src -Destination $dst -Force
        Write-Host "OK    $tag" -ForegroundColor Green; $ok++
    }
    Write-Host ''
    Write-Host ("Copiados e validados: {0} de {1}" -f $ok, $manifest.Count) -ForegroundColor Cyan
    foreach ($b in $bad) { Write-Host ("FALTA {0}: {1}" -f $b.Arquivo, $b.Motivo) -ForegroundColor $(if ($b.Arquivo -like '*(Optional)') { 'DarkYellow' } else { 'Red' }) }
    $reqBad = @($bad | Where-Object { $_.Arquivo -like '*(Required)' -and $_.Arquivo -notlike '*\pt-BR\*' })
    if ($reqBad) { Write-Host 'Perfil INCOMPLETO: falta binario obrigatorio - use uma imagem com os arquivos 10.0.19041.3636.' -ForegroundColor Red; exit 1 }
    if ($bad | Where-Object { $_.Arquivo -like '*\pt-BR\*' }) { Write-Host 'Aviso: recursos pt-BR ausentes/diferentes - o kit funciona, mas sem nomes em portugues.' -ForegroundColor Yellow }
    Write-Host 'Perfil pronto para uso.' -ForegroundColor Green; exit 0
}
finally {
    if ($mount) {
        Write-Host 'Desmontando a imagem (/Discard)...' -ForegroundColor Cyan
        Dismount-WindowsImage -Path $mount -Discard -ErrorAction SilentlyContinue | Out-Null
        Remove-Item $mount -Recurse -Force -ErrorAction SilentlyContinue
    }
}
