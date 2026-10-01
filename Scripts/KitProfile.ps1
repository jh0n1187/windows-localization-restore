# KitProfile.ps1 - selecao do perfil do kit pela versao do Windows (dot-source: . "$PSScriptRoot\KitProfile.ps1")
#
# Cada perfil fica em <KitRoot>\Profiles\<Nome>\ com:
#   profile.json        -> MinBuild/MaxBuild e quais recursos (Features) o perfil suporta
#   Files\manifest.csv  -> binarios do perfil (somente se Features.Files = true)
#   Registry\*          -> lfsvc-restaurar.reg e location-registry.json (somente se ServiceRegistry/ComRegistry = true)
#
# Features:
#   Files           restaurar binarios ausentes
#   ServiceRegistry restaurar Services\lfsvc / netsvcs
#   ComRegistry     restaurar registro COM (CLSID/Interface/AppID/TypeLib)
#   Consent         liberar ConsentStore + estado do dispositivo   (agnostico de versao)
#   Policies        remover politicas de localizacao/sensores     (agnostico de versao)

function Get-KitProfile {
    param([Parameter(Mandatory = $true)][string]$KitRoot, [string]$Name)
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $build = [int]$cv.CurrentBuild
    $arch = $env:PROCESSOR_ARCHITECTURE
    $dirs = Get-ChildItem (Join-Path $KitRoot 'Profiles') -Directory -ErrorAction SilentlyContinue
    foreach ($d in $dirs) {
        $pj = Join-Path $d.FullName 'profile.json'
        if (-not (Test-Path $pj)) { continue }
        $p = Get-Content $pj -Raw -Encoding UTF8 | ConvertFrom-Json
        $match = if ($Name) { $p.Name -ieq $Name } else { ($build -ge [int]$p.MinBuild) -and ($build -le [int]$p.MaxBuild) -and (@($p.Arch) -contains $arch) }
        if ($match) {
            return [pscustomobject]@{
                Name         = $p.Name
                Description  = $p.Description
                Path         = $d.FullName
                MinBuild     = [int]$p.MinBuild
                MaxBuild     = [int]$p.MaxBuild
                Build        = $build
                UBR          = $cv.UBR
                Arch         = $arch
                IsWindows11  = ($build -ge 22000)   # ProductName continua "Windows 10" no registro do Win11
                Features     = $p.Features
                Note         = $p.Note
                ManifestPath = Join-Path $d.FullName 'Files\manifest.csv'
                FilesRoot    = Join-Path $d.FullName 'Files'
                RegistryRoot = Join-Path $d.FullName 'Registry'
            }
        }
    }
    return $null
}

function Write-KitProfileBanner($KitProf) {
    if (-not $KitProf) { return }
    $f = $KitProf.Features
    $on = @(); $off = @()
    foreach ($n in 'Files','ServiceRegistry','ComRegistry','Consent','Policies') { if ($f.$n) { $on += $n } else { $off += $n } }
    Write-Host ("Perfil: {0} (builds {1}-{2}) | build atual {3}.{4} {5}{6}" -f $KitProf.Name, $KitProf.MinBuild, $KitProf.MaxBuild, $KitProf.Build, $KitProf.UBR, $KitProf.Arch, $(if ($KitProf.IsWindows11) { ' [Windows 11]' })) -ForegroundColor Cyan
    Write-Host ("  Recursos ativos: {0}" -f ($on -join ', ')) -ForegroundColor Cyan
    if ($off) { Write-Host ("  Somente diagnostico (nao suportado neste perfil): {0}" -f ($off -join ', ')) -ForegroundColor DarkYellow }
    if ($KitProf.Note) { Write-Host "  Obs.: $($KitProf.Note)" -ForegroundColor DarkYellow }
}

# ----------------------------------------------------------------------------------------------
# Limpeza final (housekeeping) - chamada ao fim do Repair-And-Enable.
#  - Remove pastas de Backup que NAO registram alteracao (execucoes que nao mudaram nada).
#    Um backup e mantido se contiver created-files.txt, created-registry.txt, changes.txt ou
#    created-values.txt, ou se o Repair-History.log citar a pasta como backup de uma alteracao
#    (casos anteriores aos marcadores). Restore-<ts> antigos: mantidos se o log indicar import/netsvcs.
#  - Remove pastas vazias em Backup\.
#  - Logs: mantem os N mais recentes de cada tipo (Repair-History.log e Logs\Diag-* nunca sao apagados).
# ----------------------------------------------------------------------------------------------
function Invoke-KitHousekeeping {
    param([Parameter(Mandatory = $true)][string]$KitRoot, [int]$KeepLogs = 10, [switch]$WhatIf)
    $bkRoot = Join-Path $KitRoot 'Backup'
    $logRoot = Join-Path $KitRoot 'Logs'
    $histFile = Join-Path $logRoot 'Repair-History.log'
    $hist = if (Test-Path $histFile) { Get-Content $histFile -Raw } else { '' }
    $removedB = 0; $keptB = 0; $removedL = 0
    foreach ($d in (Get-ChildItem $bkRoot -Directory -ErrorAction SilentlyContinue)) {
        $files = @(Get-ChildItem $d.FullName -Recurse -File -Force -ErrorAction SilentlyContinue)
        $markers = $files | Where-Object { $_.Name -in 'created-files.txt','created-registry.txt','changes.txt','created-values.txt' }
        $keep = [bool]$markers
        if (-not $keep -and $files.Count -gt 0) {
            if ($d.Name -like 'Policies-*') {
                # Remove-LocationPolicies so exporta .reg de itens que removeu -> .reg presente = alteracao
                $keep = [bool]($files | Where-Object { $_.Extension -eq '.reg' })
            } elseif ($d.Name -like 'Policy-*') {
                # backup citado no historico como origem de uma alteracao (SET/removida) = manter
                $keep = $hist -match [regex]::Escape("(backup $($d.FullName))")
            } else {
                $lg = $files | Where-Object { $_.Name -like 'Restore-*.log' } | Select-Object -First 1
                if (-not $lg) { $lg = Get-Item (Join-Path $logRoot ("Restore-{0}.log" -f ($d.Name -replace '-\d+$', ''))) -ErrorAction SilentlyContinue }
                if ($lg) { $keep = (Get-Content $lg.FullName -Raw) -match 'configuracao importada|lfsvc adicionado|NEW   G' }
            }
        }
        if ($keep) { $keptB++; continue }
        if ($WhatIf) { Write-Host "WHATIF limpar backup sem alteracoes: $($d.FullName)" -ForegroundColor Yellow; $removedB++; continue }
        Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue; $removedB++
    }
    foreach ($pat in 'Restore-*.log','Verify-*.log','Repair-And-Enable-*.log','Pending-Step-2*.log','Check-UserLocation-*.log') {
        $old = @(Get-ChildItem $logRoot -File -Filter $pat -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -Skip $KeepLogs)
        foreach ($f in $old) {
            if ($WhatIf) { Write-Host "WHATIF remover log antigo: $($f.Name)" -ForegroundColor Yellow } else { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }
            $removedL++
        }
    }
    $msg = "Limpeza final: {0} backup(s) sem alteracoes {1}, {2} backup(s) de alteracoes mantidos, {3} log(s) antigos {1} (mantidos os {4} mais recentes de cada tipo)." -f $removedB, $(if ($WhatIf) { 'a remover' } else { 'removidos' }), $keptB, $removedL, $KeepLogs
    Write-Host $msg -ForegroundColor Green
    if (-not $WhatIf) { "[{0}] {1}" -f (Get-Date -Format 's'), $msg | Out-File $histFile -Append -Encoding UTF8 }
}

# ----------------------------------------------------------------------------------------------
# Grupo svchost do lfsvc, lido do proprio ImagePath (agnostico de versao):
#   Win10 19041-19045: "svchost.exe -k netsvcs -p"
#   Win11 24H2/25H2  : "svchost.exe -k netsvcsRedirectionGuard -p"
# Retorna @{ Group; Exists (valor existe em Svchost); Members; Contains }
# ----------------------------------------------------------------------------------------------
function Get-LfsvcSvchostGroup {
    $ip = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\lfsvc' -Name ImagePath -ErrorAction SilentlyContinue).ImagePath
    if (-not $ip -or $ip -notmatch '(?i)-k\s+(\S+)') { return $null }
    $g = $Matches[1]
    $v = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Svchost' -Name $g -ErrorAction SilentlyContinue).$g
    [pscustomobject]@{ Group = $g; Exists = ($null -ne $v); Members = @($v); Contains = [bool](@($v) | Where-Object { $_ -ieq 'lfsvc' }) }
}

# Estado de inicializacao de um servico: registro (Start) E configuracao carregada no SCM.
# O SCM so rele o registro no boot; se Start foi alterado direto no registro (debloat/edicao manual),
# o SCM continua com o valor antigo (ex.: Disabled -> sc start falha com 1058) ate reiniciar ou ate um "sc config".
function Get-SvcStartInfo {
    param([Parameter(Mandatory = $true)][string]$Name)
    $reg = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$Name" -Name Start -ErrorAction SilentlyContinue).Start
    $w = Get-CimInstance Win32_Service -Filter "Name='$Name'" -ErrorAction SilentlyContinue
    $scm = if ($w) { [string]$w.StartMode } else { $null }   # Auto | Manual | Disabled | Boot | System
    [pscustomobject]@{
        Name     = $Name
        Reg      = $reg
        Scm      = $scm
        Disabled = ($reg -eq 4) -or ($scm -eq 'Disabled')
        Mismatch = ($null -ne $reg) -and ($null -ne $scm) -and (($reg -eq 4) -ne ($scm -eq 'Disabled'))
    }
}

# ======================================================================  HIVES DE USUARIO
# A parte "por usuario" (HKCU) e aplicada em TODOS os perfis da maquina:
#   - perfis com sessao aberta: direto em HKEY_USERS\<SID>
#   - perfis sem sessao: NTUSER.DAT carregado temporariamente (reg load HKU\RL_<SID>) e descarregado depois
#   - perfil modelo Default (C:\Users\Default\NTUSER.DAT): copiado para todo usuario NOVO no primeiro logon
$KitCamRel = 'SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location'
$KitPolRel = 'SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors'

function Get-KitUserHives {
    $pl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($k in Get-ChildItem $pl -ErrorAction SilentlyContinue) {
        $sid = $k.PSChildName
        # contas locais / dominio / Microsoft (S-1-5-21-*) e Entra ID (S-1-12-1-*); ignora contas de sistema e chaves .bak
        if ($sid -notmatch '^S-1-(5-21|12-1)(-\d+)+$') { continue }
        $dir = [Environment]::ExpandEnvironmentVariables([string](Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue).ProfileImagePath)
        if (-not $dir) { continue }
        $name = Split-Path $dir -Leaf
        try { $name = (New-Object Security.Principal.SecurityIdentifier($sid)).Translate([Security.Principal.NTAccount]).Value } catch { }
        $list.Add([pscustomobject]@{ Kind = 'Usuario'; Name = $name; Sid = $sid; NtUser = (Join-Path $dir 'NTUSER.DAT'); Root = $null; Mounted = $false; Skip = $false; Status = '' })
    }
    $def = [string](Get-ItemProperty $pl -ErrorAction SilentlyContinue).Default
    $def = if ($def) { [Environment]::ExpandEnvironmentVariables($def) } else { Join-Path $env:SystemDrive 'Users\Default' }
    $list.Add([pscustomobject]@{ Kind = 'Modelo'; Name = 'Default (novos usuarios)'; Sid = 'Default'; NtUser = (Join-Path $def 'NTUSER.DAT'); Root = $null; Mounted = $false; Skip = $false; Status = '' })
    return $list
}

function Mount-KitUserHive($h) {
    if ($h.Sid -ne 'Default' -and (Test-Path "Registry::HKEY_USERS\$($h.Sid)")) { $h.Root = "HKEY_USERS\$($h.Sid)"; $h.Status = 'sessao aberta'; return $true }
    if (-not (Test-Path -LiteralPath $h.NtUser)) { $h.Status = 'NTUSER.DAT ausente (perfil sem dados) - ignorado'; $h.Skip = $true; return $false }
    $mn = 'RL_' + ($h.Sid -replace '[^\w-]', '_')
    if (Test-Path "Registry::HKEY_USERS\$mn") { [GC]::Collect(); [GC]::WaitForPendingFinalizers(); & reg.exe unload "HKU\$mn" 2>&1 | Out-Null }   # sobra de execucao interrompida
    $o = & reg.exe load "HKU\$mn" "$($h.NtUser)" 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { $h.Status = "nao foi possivel carregar o NTUSER.DAT ($(($o -replace '\s+', ' ').Trim()))"; return $false }
    $h.Root = "HKEY_USERS\$mn"; $h.Mounted = $true; $h.Status = 'NTUSER.DAT carregado'
    return $true
}

function Dismount-KitUserHive($h) {
    if (-not $h.Mounted) { return }
    $mn = $h.Root -replace '^HKEY_USERS\\', ''
    for ($i = 0; $i -lt 6; $i++) {
        [GC]::Collect(); [GC]::WaitForPendingFinalizers()
        & reg.exe unload "HKU\$mn" 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $h.Mounted = $false; return }
        Start-Sleep -Milliseconds 500
    }
    Write-Host "AVISO: nao foi possivel descarregar HKU\$mn ($($h.Name)) - sera liberado no proximo reinicio." -ForegroundColor Yellow
}

# Estado de localizacao de cada perfil (somente leitura)
function Get-KitUserLocationState {
    foreach ($h in Get-KitUserHives) {
        $ok = Mount-KitUserHive $h
        $v = $null; $np = $null; $pk = $false
        if ($ok) {
            try {
                $v  = (Get-ItemProperty "Registry::$($h.Root)\$KitCamRel" -ErrorAction SilentlyContinue).Value
                $np = (Get-ItemProperty "Registry::$($h.Root)\$KitCamRel\NonPackaged" -ErrorAction SilentlyContinue).Value
                $pk = Test-Path "Registry::$($h.Root)\$KitPolRel"
            } finally { Dismount-KitUserHive $h }
        }
        [pscustomobject]@{ Name = $h.Name; Kind = $h.Kind; Sid = $h.Sid; Loaded = $ok; Skip = $h.Skip; Status = $h.Status; Value = $v; NonPackaged = $np; PolicyKey = $pk
                           Label = ('{0} [{1}]' -f $h.Name, $h.Kind) }
    }
}

# Reimporta um .reg exportado de um hive de usuario, trocando a raiz gravada no arquivo pela raiz atual
function Import-KitUserReg([string]$File, [string]$OldRoot, [string]$NewRoot) {
    $t = [IO.File]::ReadAllText($File)
    $t = [regex]::Replace($t, '\[' + [regex]::Escape($OldRoot) + '\\', '[' + $NewRoot.Replace('$', '$$') + '\', 'IgnoreCase')
    $tmp = Join-Path $env:TEMP ('rl-' + [guid]::NewGuid().ToString('N') + '.reg')
    [IO.File]::WriteAllText($tmp, $t, [Text.Encoding]::Unicode)
    & reg.exe import $tmp 2>&1 | Out-Null; $rc = $LASTEXITCODE
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    return ($rc -eq 0)
}

# ======================================================================  CHAVES PROTEGIDAS (TrustedInstaller)
# HKLM\SOFTWARE\Microsoft\SystemSettings\SettingId pertence ao TrustedInstaller: nem o Administrador cria subchaves.
# Em vez de tomar posse/alterar ACL, usa o privilegio de restauracao (SeRestorePrivilege, que todo Administrador
# possui mas fica desligado) e abre a chave com REG_OPTION_BACKUP_RESTORE. A chave criada herda a ACL do pai
# (igual as chaves irmas); dono e permissoes do Windows NAO sao alterados. O privilegio e desligado ao final.
if (-not ('KitRegPriv' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class KitRegPriv {
    [StructLayout(LayoutKind.Sequential)] struct LUID { public uint Lo; public int Hi; }
    [StructLayout(LayoutKind.Sequential)] struct TOKEN_PRIVILEGES { public uint Count; public LUID Luid; public uint Attr; }
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool LookupPrivilegeValue(string system, string name, out LUID luid);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll, ref TOKEN_PRIVILEGES state, uint len, IntPtr prev, IntPtr retLen);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)] static extern int RegCreateKeyEx(UIntPtr hKey, string subKey, int reserved, string cls, uint options, uint sam, IntPtr sa, out IntPtr result, out uint disposition);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)] static extern int RegSetValueEx(IntPtr hKey, string name, int reserved, uint type, byte[] data, int len);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)] static extern int RegDeleteValue(IntPtr hKey, string name);
    [DllImport("advapi32.dll")] static extern int RegCloseKey(IntPtr h);
    [DllImport("ntdll.dll")] static extern int NtDeleteKey(IntPtr h);
    static readonly UIntPtr HKLM = new UIntPtr(0x80000002u);
    const uint REG_OPTION_BACKUP_RESTORE = 4, KEY_ALL_ACCESS = 0xF003F, KEY_WOW64_64KEY = 0x100;

    public static bool SetPrivilege(string name, bool enable) {
        IntPtr tok;
        if (!OpenProcessToken(GetCurrentProcess(), 0x28, out tok)) return false;   // TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY
        try {
            LUID l; if (!LookupPrivilegeValue(null, name, out l)) return false;
            TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES(); tp.Count = 1; tp.Luid = l; tp.Attr = enable ? 2u : 0u;
            if (!AdjustTokenPrivileges(tok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero)) return false;
            return Marshal.GetLastWin32Error() == 0;   // 1300 = privilegio nao existe no token
        } finally { CloseHandle(tok); }
    }
    static IntPtr Open(string sub, out uint disposition) {
        IntPtr h;
        int rc = RegCreateKeyEx(HKLM, sub, 0, null, REG_OPTION_BACKUP_RESTORE, KEY_ALL_ACCESS | KEY_WOW64_64KEY, IntPtr.Zero, out h, out disposition);
        if (rc != 0) throw new System.ComponentModel.Win32Exception(rc);
        return h;
    }
    // true = chave criada agora; false = ja existia
    public static bool CreateKey(string sub) { uint d; IntPtr h = Open(sub, out d); RegCloseKey(h); return d == 1; }
    public static void SetString(string sub, string name, string data, bool expand) {
        uint d; IntPtr h = Open(sub, out d);
        try {
            byte[] b = Encoding.Unicode.GetBytes(data + "\0");
            int rc = RegSetValueEx(h, name, 0, expand ? 2u : 1u, b, b.Length);
            if (rc != 0) throw new System.ComponentModel.Win32Exception(rc);
        } finally { RegCloseKey(h); }
    }
    public static void DeleteValue(string sub, string name) {
        uint d; IntPtr h = Open(sub, out d);
        try { int rc = RegDeleteValue(h, name); if (rc != 0 && rc != 2) throw new System.ComponentModel.Win32Exception(rc); } finally { RegCloseKey(h); }
    }
    public static void DeleteKey(string sub) {   // chave sem subchaves
        uint d; IntPtr h = Open(sub, out d);
        try { int st = NtDeleteKey(h); if (st != 0) throw new Exception("NtDeleteKey falhou: 0x" + st.ToString("X8")); } finally { RegCloseKey(h); }
    }
}
'@
}

function Set-KitRestorePrivilege([bool]$Enable) {
    $ok = [KitRegPriv]::SetPrivilege('SeRestorePrivilege', $Enable)
    [void][KitRegPriv]::SetPrivilege('SeBackupPrivilege', $Enable)
    return $ok
}

# Restaura uma entrada do location-registry.json em chave protegida: cria chaves/valores AUSENTES, nunca altera existentes.
# Registra em $CreatedLog: "PKEY HKLM\<chave>" e "PVAL HKLM\<chave>|<valor>" (usados pelo Rollback-Location -RemoveCreatedRegistry).
function Restore-KitProtectedEntry($Entry, [string]$SysRoot, [string]$CreatedLog) {
    $res = [pscustomobject]@{ Keys = 0; Values = 0; Kept = 0; Error = $null }
    $hk = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', 'Registry64')
    try {
        foreach ($k in $Entry.Keys) {
            $ro = $hk.OpenSubKey($k.Path, $false)
            if (-not $ro) {
                if ([KitRegPriv]::CreateKey($k.Path)) { Add-Content $CreatedLog "PKEY HKLM\$($k.Path)" -Encoding UTF8; $res.Keys++ }
                $ro = $hk.OpenSubKey($k.Path, $false)
            }
            foreach ($v in @($k.Values)) {
                if ($v.Type -notin 'String', 'ExpandString') { throw "tipo $($v.Type) nao suportado em chave protegida ($($v.Name))" }
                if ($ro -and $null -ne $ro.GetValue([string]$v.Name, $null, 'DoNotExpandEnvironmentNames')) { $res.Kept++; continue }
                $data = [string]$v.Data -replace '(?i)^X:\\Windows', $SysRoot
                [KitRegPriv]::SetString($k.Path, [string]$v.Name, $data, ($v.Type -eq 'ExpandString'))
                Add-Content $CreatedLog ("PVAL HKLM\{0}|{1}" -f $k.Path, $v.Name) -Encoding UTF8; $res.Values++
            }
            if ($ro) { $ro.Close() }
        }
    } catch { $res.Error = $_.Exception.Message }
    return $res
}
