# Restore-Location — kit de reparo do Windows Location (lfsvc)

Kit reutilizável para restaurar o **Serviço de Geolocalização (`lfsvc`)** e a pilha de localização do
Windows 10 em instalações modificadas/"debloated". **O kit é autossuficiente**: não depende de ISO, `install.wim`, DISM,
internet nem de programa instalado — tudo que é necessário está em `Profiles\<perfil>\` (`Files\`, `Registry\`, `Tasks\`,
`Catalogs\`) e vai junto no repositório.

> Os binários de `Profiles\Win10-19041\Files\` são arquivos originais da Microsoft (10.0.19041.x, extraídos da mídia oficial
> do Windows 10 22H2 pt-BR); o `manifest.csv` traz caminho, versão e SHA256 de cada um e o kit confere o hash antes de copiar.
> No Windows 11 o perfil é parcial e não usa binários.

---

## ▶ Como usar (1 clique)

Na máquina a reparar, copie a pasta `C:\Restore-Location` e dê **duplo clique em `REPARAR-E-HABILITAR.cmd`**
(na raiz do kit). Ele pede elevação e executa `Scripts\Repair-And-Enable.ps1`, que **primeiro diagnostica**
(somente leitura) e depois **executa apenas as etapas necessárias**:

| Etapa | Script | Executa somente se… |
|---|---|---|
| A | `Restore-Location.ps1` | faltar algum arquivo, a configuração do `lfsvc`/`netsvcs`, algum registro COM/WinRT/sistema, catálogo de assinatura ou tarefa agendada de localização |
| B | `Enable-LocationPolicy.ps1` | ConsentStore ≠ Allow (dispositivo/usuário/apps desktop) ou `lfsvc\Service\Configuration\Status` ≠ 1 |
| C | `Remove-LocationPolicies.ps1` | existir política de localização/sensores (`LocationAndSensors`, `LetAppsAccessLocation*`, PolicyManager `AllowLocation`) |
| D | `Verify-Location.ps1 -Functional` | sempre (somente leitura) |
| E | Limpeza final (`Invoke-KitHousekeeping`) | sempre, exceto `-CheckOnly`: descarta backups de execuções que não alteraram nada e mantém só os 10 logs mais recentes de cada tipo |

Dentro da etapa A, cada arquivo e cada chave são validados individualmente: o que já existe é mantido (nunca sobrescrito).
Numa máquina já reparada, o resultado é "Nenhuma correção necessária" + verificação.

Opções (`Scripts\Repair-And-Enable.ps1`): `-CheckOnly` (só diagnóstico/plano, não altera nada),
`-NoEnable` (não mexe em privacidade/políticas), `-Force` (executa A, B e C mesmo sem necessidade; continuam idempotentes).
Log: `Logs\Repair-And-Enable-<data>.log`. **Reinicie** após a etapa C para a página de Configurações refletir.
O fim do log traz um bloco **RESULTADO FINAL** (SUCESSO / SUCESSO COM AVISOS / FALHA / FALHA (ABORTADO)) com o resultado de cada etapa,
os motivos e o código de saída (0 = sucesso, 1 = falha, 2/3 = abortado); a linha também vai para `Logs\Repair-History.log`.

### Abrangência: máquina inteira + todos os usuários (atuais e futuros)

| Parte | Onde | Alcance |
|---|---|---|
| Arquivos, serviço `lfsvc`/`camsvc`, svchost, COM, ConsentStore do dispositivo, políticas HKLM | HKLM / System32 | máquina inteira |
| ConsentStore `location` e `NonPackaged` = Allow (etapa B) | hive de **cada** usuário | todos os perfis em `ProfileList` (com sessão aberta: `HKEY_USERS\<SID>`; sem sessão: `NTUSER.DAT` carregado temporariamente como `HKU\RL_<SID>` e descarregado em seguida) |
| Política `Policies\...\LocationAndSensors` do usuário (etapa C) | hive de **cada** usuário | idem |
| Usuários **criados depois** | `C:\Users\Default\NTUSER.DAT` (perfil modelo) | as etapas B e C também gravam no perfil modelo, que o Windows copia para todo usuário novo |

- Não depende de quem roda o `.cmd`: mesmo elevando com outra conta de administrador, todos os perfis são tratados.
- Perfil sem `NTUSER.DAT` é ignorado (informativo). Se um hive não puder ser carregado, a etapa registra ERRO e o resultado final fica FALHA.
- Backup/rollback: `Backup\Policy-*\user-values.csv` (etapa B) e `Backup\Policies-*\user-hives.csv` + `*-user-*.reg` (etapa C); o `-Revert` recarrega cada perfil e restaura.
- No Windows 11, um usuário novo ainda vê no primeiro logon a tela "Escolha as configurações de privacidade"; o que ele escolher ali prevalece (é decisão do usuário).
- A verificação (`Verify-Location.ps1`) lista o estado de cada perfil, incluindo `Default (novos usuarios)`.

### Serviço desativado só na memória do SCM (erro 1058)
O SCM só relê `Services\<svc>\Start` no boot. Se o registro diz Manual (3) mas o SCM ainda tem "Disabled", o `sc start` falha com 1058.
O diagnóstico agora compara registro **e** SCM; a etapa B (e a etapa A logo após importar `lfsvc-restaurar.reg`) sincroniza via `sc config`.

---

## Perfis por versão do Windows

Os dados específicos de versão ficam em `Profiles\<perfil>\` e o perfil é escolhido **automaticamente pelo build**
(`Scripts\KitProfile.ps1`). Atenção: no Windows 11 o registro continua dizendo "Windows 10" em `ProductName`;
por isso a seleção usa o build (≥ 22000 = Windows 11).

| Perfil | Builds | Arquivos | Registro do serviço | Registro COM | Consentimento | Remoção de políticas |
|---|---|---|---|---|---|---|
| `Win10-19041` | 19041–19045 (Win10 2004…22H2) | ✅ | ✅ | ✅ | ✅ | ✅ |
| `Win11` | 22000+ (Win11) | diagnóstico | diagnóstico | diagnóstico | ✅ | ✅ |

**Windows 11 (perfil parcial)** – executa somente as etapas que não dependem de versão:
- **Remove as políticas** de localização/sensores (`LocationAndSensors`, `LetAppsAccessLocation*`, PolicyManager `AllowLocation`),
  que deixam a página *Privacidade e segurança › Localização* "gerenciada pela organização" — devolvendo ao usuário
  o controle de ligar/desligar pela interface;
- **Libera o consentimento** (ConsentStore = Allow e `lfsvc\Service\Configuration\Status = 1`, este só se o serviço existir);
- **Diagnostica** (sem alterar) arquivos, serviço e a classe COM `lfsvc`. Se algo estiver faltando, o lançador lista
  como "FALTA (perfil nao corrige)": nesse caso é preciso criar um perfil `Win11-<build>` com dados extraídos de um
  `install.wim` do mesmo build (mesmo método usado no Win10). Binários/registro do Win10 **nunca** são aplicados no Win11.
- Ainda **não testado** em Windows 11.

Novo perfil: crie `Profiles\<nome>\profile.json` (MinBuild/MaxBuild/Arch/Features) e, se `Files`/`ServiceRegistry`/`ComRegistry`
forem `true`, os respectivos `Files\manifest.csv` + binários e `Registry\lfsvc-restaurar.reg` / `location-registry.json`.

## 1. Problema

| Sintoma | Situação inicial |
|---|---|
| `Get-Service lfsvc` | serviço inexistente (chave `Services\lfsvc` praticamente vazia) |
| `C:\Windows\System32\lfsvc.dll` | ausente |
| Após restaurar registro + `lfsvc.dll` | `sc start lfsvc` → `START_PENDING` → `STOPPED`, **`WIN32_EXIT_CODE 126`** (módulo não encontrado) |
| Após corrigir o 126 | serviço sobe e **encerra em < 0,3 s** com código 0 |
| Configurações › Privacidade › Localização | desativada e "gerenciada pela organização"; Chrome/Edge: "bloqueado pelo sistema" |
| API WinRT `Geolocator.RequestAccessAsync` | `0x80040154 – Classe não registrada` |

## 2. Causas identificadas (comprovadas, uma por vez)

1. **Erro 126 — `LocationFramework.dll` removido.**
   Análise PE (imports + delay-imports) mostrou que `lfsvc.dll` tem **import estático** de
   `LocationFramework.dll` — a única dependência não-API-Set ausente. Todas as dependências estáticas do
   próprio `LocationFramework.dll` existiam. Restaurar **somente** esse arquivo levou o código de saída de 126 → 0.
2. **Serviço encerrando logo após iniciar — registro COM removido.**
   Os 46 componentes do framework (`Services\lfsvc\Components\*\ClassId`) são classes COM
   (`InprocServer32 = LocationFramework.dll`). Comparando com o hive `SOFTWARE` da imagem original,
   o debloat havia removido **78 CLSIDs** (x64 + WOW64) e **36 interfaces** (proxy/stub).
   Após recriá-los (aditivamente), o `lfsvc` passou a **permanecer em RUNNING**.
3. **Apps/navegadores sem acesso — classe COM "lfsvc" removida.**
   A API WinRT (`Geolocation.dll`, usada por Chrome, Edge e Configurações) cria a classe COM
   `{08D9DFDF-C6F7-404A-A20F-66EEC0A609CD}` ("lfsvc"), hospedada pelo próprio serviço
   (`AppID {020FB939-…}`, `LocalService = lfsvc`, com Access/LaunchPermission) e com TypeLib
   `{B25DF0F7-…}` "Windows Geolocation Service". O debloat removeu as três. Identificada procurando, nos binários
   originais, os GUIDs das 1.380 classes ausentes. Após recriá-las: `RequestAccessAsync` deixou de falhar.
4. **Localização negada por política/privacidade** (configuração do debloat):
   `ConsentStore\location = Deny` (HKLM, HKCU, NonPackaged); `lfsvc\Service\Configuration\Status` ausente;
   `Policies\Microsoft\Windows\LocationAndSensors` (DisableSensors=1, DisableLocationScripting=1, …) e
   `PolicyManager\current\device\System\AllowLocation = 0`. As políticas tornam a página "gerenciada pela
   organização" mesmo para administradores. Após liberar o consentimento e **remover** essas políticas (com backup),
   Chrome obteve a posição e o Verify passou a `Permission=Granted` com latitude/longitude.

## 3. Arquivos removidos pelo debloat e restaurados

Origem: imagem original do Windows 10 Pro pt-BR (arquivos 10.0.19041.3636; idênticos byte a byte aos da ISO 22H2 19045.3803).
Todos validados por SHA256 (`Profiles\Win10-19041\Files\manifest.csv`). A lista foi conferida contra os manifestos WinSxS dos
componentes `Microsoft-Windows-Geolocation-*`, `MobilePC-Location-API` e `SettingsHandlers-Geolocation` da imagem.

| Grupo | Arquivo | Versão | Função |
|---|---|---|---|
| 0 | `System32\lfsvc.dll` | 10.0.19041.1 | ServiceDll do serviço |
| **1** | **`System32\LocationFramework.dll`** | 10.0.19041.3636 | **implementação do serviço – causa do erro 126** |
| 2 | `System32\pt-BR\lfsvc.dll.mui`, `System32\pt-BR\locationframework.dll.mui` | 19041.1 | nome/descrição/recursos pt-BR |
| 3 | `System32\LocationWinPalMisc.dll`, `System32\LocationApi.dll`, `System32\LocationFrameworkPS.dll`, `System32\LocationFrameworkInternalPS.dll` | 19041.3636 | componentes, Location API (Win32/.NET), proxies COM |
| 3 | `SysWOW64\LocationApi.dll`, `SysWOW64\LocationFrameworkPS.dll`, `SysWOW64\LocationFrameworkInternalPS.dll` | 19041.3636 | idem para processos 32-bit |
| 3 | `System32\Geolocation.dll` (+ `pt-BR\Geolocation.dll.mui`), `SysWOW64\Geolocation.dll` | 19041.3636 | WinRT `Windows.Devices.Geolocation` (apps e navegadores 64 e 32-bit) |
| 4 | `System32\SettingsHandlers_Geolocation.dll` (+ `.mui`), `System32\LocationNotificationWindows.exe` (+ `.mui`) | 19041.x | página de Configurações e ícone "localização em uso" |
| 4 | `System32\WindowsActionDialog.exe` (+ `.mui`) | 19041.3636 | diálogo de ação de localização (tarefa `Location\WindowsActionDialog`) |
| 9 (opcional) | `PolicyDefinitions\LocationProviderAdm.admx` (+ `pt-BR\...adml`) | — | modelo de política do gpedit (só com `-IncludeOptional`) |

Arquivos **preservados** quando já existem (versões mais novas do sistema): `System32\Geolocation.dll` (19041.6033 na VM de teste),
`SetNetworkLocation*.dll`, `CapabilityAccessManager*.dll`, `SensorService.dll` etc.

**Catálogos de assinatura** (`Profiles\Win10-19041\Catalogs\`, 6 arquivos `.cat`): os binários acima não têm assinatura embutida;
só são reconhecidos como assinados pela Microsoft se o catálogo do pacote deles estiver registrado. A etapa A registra os
catálogos ausentes (`CryptCATAdminAddCatalog`), e os arquivos restaurados passam de `NotSigned` a `Valid`.

**Tarefas agendadas** (`Profiles\Win10-19041\Tasks\`): `\Microsoft\Windows\Location\Notifications` (gatilho WNF; é ela que
inicia o `LocationNotificationWindows.exe` — sem a tarefa o ícone "localização em uso" nunca aparece) e
`\Microsoft\Windows\Location\WindowsActionDialog`. Registradas somente se ausentes e se o executável existir.

Ausentes, mas **fora do kit** (não fazem parte da cadeia do `lfsvc`): `cldapi.dll`, `MdmCommon.dll`, `SensorsApi.dll`, `sensrsvc.dll`.

## 4. Alterações de registro

| Item | Como | Fonte |
|---|---|---|
| `HKLM\SYSTEM\CurrentControlSet\Services\lfsvc` (+ Parameters, Components, TriggerInfo, Security…) | importado **somente se ausente/inconsistente** | `Registry\lfsvc-restaurar.reg` |
| `Svchost\netsvcs` contém `lfsvc` | adicionado **somente se ausente**, preservando as demais entradas | — |
| 78 CLSIDs + 36 Interfaces COM de Location | cria **somente chaves/valores ausentes**; nunca altera valor existente; só aplica se o DLL referenciado existir; `X:\Windows` → `%SystemRoot%` real | `Profiles\Win10-19041\Registry\location-registry.json` |
| 5 `SystemSettings\SettingId\SystemSettings_Privacy_*Location*` | criados **somente se ausentes**, com `SeRestorePrivilege` (chave protegida pelo TrustedInstaller; dono/ACL **não** alterados — a chave herda a ACL do pai); rollback por `Rollback-Location -RemoveCreatedRegistry` (`PKEY`/`PVAL` em `created-registry.txt`) | `Profiles\Win10-19041\Registry\location-registry.json` |
| CLSID `{08D9DFDF…}` "lfsvc" + AppID `{020FB939…}` (LocalService/permissões) + TypeLib `{B25DF0F7…}` | cria somente se ausentes | `Profiles\Win10-19041\Registry\location-registry.json` |
| Location API clássica (`LocationApi.dll`): ProgIDs `LocationApi`, `DefaultLocationApi`, `LocationDisp.*`, interfaces (proxy/stub) e TypeLib `{4486DF98…}`, x64 e WOW64 | cria somente chaves/valores ausentes (privilégio de restauração; dono/ACL inalterados). Sem elas `New-Object -ComObject LocationDisp.LatLongReportFactory` falha com 0x80040154 | `location-registry.json` (entradas `"Source":"manifest"`) |
| WinRT `Windows.Devices.Geolocation.*` (ActivatableClassId, CLSID, interfaces), x64 e **WOW6432Node** (apps 32-bit) | idem | idem |
| Sistema: notificação `Windows.SystemToast.LocationManager`, BackgroundModel (brokers e `EventSettings` 150/600 = geofence), fonte `EventLog\System\Lfsvc`, publisher/canal de eventos `{4d13548f…}`, CSP SUPL, definições de capability/política de localização | idem | idem |
| Privacidade (ConsentStore = Allow no dispositivo e em **todos os perfis + Default**; `lfsvc\Service\Configuration\Status = 1`) | `Scripts\Enable-LocationPolicy.ps1`, com backup e `-Revert` | — |
| Políticas de localização/sensores do debloat | **removidas** por `Scripts\Remove-LocationPolicies.ps1`, com backup e `-Revert` | — |

## 5. Procedimento automático

PowerShell **64-bit como Administrador**:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
cd C:\Restore-Location\Scripts

.\Restore-Location.ps1 -WhatIf      # diagnóstico: mostra o que faria, sem alterar
.\Restore-Location.ps1              # repara (idempotente; pode rodar várias vezes)
.\Verify-Location.ps1               # verificação completa
.\Verify-Location.ps1 -Functional   # + teste funcional (GeoCoordinateWatcher)

# OPCIONAL – somente se quiser a localização LIGADA (altera privacidade/política):
.\Enable-LocationPolicy.ps1 -WhatIf
.\Enable-LocationPolicy.ps1
```

Sem digitar comandos: duplo clique em `Scripts\Run-AsAdmin.cmd` (auto-eleva, executa `Scripts\Pending-Step.ps1`
= Restore + Verify, grava `Logs\Pending-Step-last.log`).

Parâmetros úteis do `Restore-Location.ps1`: `-Group 0,1` (restauração gradual), `-IncludeOptional` (grupo 9: modelo ADMX),
`-SkipComRegistry`, `-NoServiceTest`. Com `-WhatIf` nada é alterado, mas o log `Logs\Restore-<ts>.log` é gravado.

O script: exige Administrador e PowerShell 64-bit; valida Windows 10 build 19041–19045 x64; cria backup em
`Backup\<timestamp>\`; valida o SHA256 de cada arquivo do kit; **nunca sobrescreve** arquivo existente;
aplica ACL/owner (TrustedInstaller) iguais aos binários do sistema; testa o serviço; informa se reinicialização é necessária.

## 6. Procedimento manual (equivalente)

1. Copie para `%SystemRoot%` cada arquivo de `Profiles\Win10-19041\Files\` que **não existir** no destino (confira o SHA256 com `Profiles\Win10-19041\Files\manifest.csv`).
2. Se `Services\lfsvc\Parameters\ServiceDll` não existir: `reg import Profiles\Win10-19041\Registry\lfsvc-restaurar.reg` e reinicie.
3. Garanta `lfsvc` em `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Svchost` → `netsvcs` (MULTI_SZ).
4. Recrie os CLSIDs/Interfaces ausentes listados em `Profiles\Win10-19041\Registry\location-registry.json` (trocando `X:\Windows` por `C:\Windows`).
5. `sc start lfsvc` → `sc queryex lfsvc` deve mostrar `RUNNING`.

## 7. Rollback

Cada execução **que altera algo** grava em `Backup\<timestamp>\` (execuções sem alteração descartam o próprio backup): exports de registro, `netsvcs-before.txt`, `files-before.csv`,
`created-files.txt`, `created-registry.txt` e `changes.txt` (inclui as linhas `TASK`/`CATALOG` do que foi registrado).

```powershell
.\Rollback-Location.ps1 -BackupFolder C:\Restore-Location\Backup\<timestamp> -WhatIf
.\Rollback-Location.ps1 -BackupFolder C:\Restore-Location\Backup\<timestamp> -RemoveCreatedRegistry -RemoveTasksAndCatalogs
.\Enable-LocationPolicy.ps1 -Revert          # desfaz a liberação de privacidade (ConsentStore/Status)
.\Remove-LocationPolicies.ps1 -Revert       # reimporta as políticas removidas
```

O rollback **move** (não apaga) apenas arquivos criados pelo kit cujo hash confere, e remove apenas chaves/valores
que o próprio kit criou. Para desfazer uma restauração feita em vários passos, execute o rollback de cada pasta de backup, da mais recente para a mais antiga.

## 8. Builds testadas

| Sistema | Resultado |
|---|---|
| Windows 10 Pro 22H2 **19045.6811** x64 pt-BR (VM, debloated) | `lfsvc` RUNNING estável, inclusive após reinicialização; reexecução sem alterações e sem erros (idempotente); resultado **SUCESSO**, Verify **PASS** sem avisos (todos os binários `sig=Valid`, tarefas e catálogos registrados); teste funcional `Permission=Granted` com latitude/longitude; `LocationDisp.LatLongReportFactory` e WinRT `Geolocator` ativam em processos 64 e 32-bit; Chrome (browserleaks.com/geo) obtém a posição |

Binários do kit: 10.0.19041.1 / 10.0.19041.3636 (compatíveis com 2004/20H2/21H1/21H2/22H2 — builds 19041–19045).
Outras builds são recusadas pelo script.

## 9. Limitações

- **Sem posição na VM**: o teste funcional chega a `Permission=Granted` / `Status=Initializing`, mas uma VM sem
  Wi-Fi/GNSS não tem fonte de posição. Em hardware com Wi-Fi ou com "Local padrão" definido, a posição é obtida.
- **5 itens da página de Configurações** (botão "Definir padrão" do Local padrão, ícone de localização, botão "Limpar"
  do histórico, status de geofencing) dependem de chaves em `SystemSettings\SettingId`, protegida pelo TrustedInstaller.
  Sem elas, os botões aparecem como **barras cinzas vazias**. A etapa A cria essas chaves com o privilégio de
  restauração (`SeRestorePrivilege`), sem tomar posse nem alterar ACL. **Feche e reabra Configurações** depois.
- **Assinatura**: os binários restaurados só aparecem como `Valid` depois que a etapa A registra os catálogos do perfil
  (`Catalogs\*.cat`); se o registro de um catálogo falhar (aviso no log), o arquivo fica `NotSigned`, mas a integridade
  continua garantida por SHA256.
- **`Control\WMI\Security`**: o descritor de segurança do provedor de eventos é criado só se ausente; os demais valores
  dessa chave não são tocados.
- **Atualizações**: os arquivos restaurados não estão registrados no Component Store (WinSxS/CBS) — o Windows Update
  não os atualizará. Eles permanecem na versão 19041.3636.
- **Idioma**: o kit contém apenas recursos **pt-BR**. Em outros idiomas os binários funcionam, mas nome/descrição do
  serviço aparecem como `lfsvc`. O `DisplayName` pt-BR ("Serviço de Geolocalização") só passa a aparecer após reinicializar (verificado nesta VM).
- **Event Log**: nesta VM o log System havia sido limpo pelo debloat (sem eventos do SCM), por isso o diagnóstico foi feito por análise PE e comparação de registro.
- `DisableSensors = 1` e `DisableLocationScripting = 1` foram mantidos (não são necessários para a localização).

## 10. Logs

| Arquivo | Conteúdo |
|---|---|
| `Logs\Repair-History.log` | histórico legível das decisões e execuções |
| `Logs\Diag-<ts>\` | diagnóstico inicial (inventário, WIM, dependências PE, comparação) |
| `Logs\Restore-<ts>.log` / `Logs\Verify-<ts>.log` | cada execução |
| `Logs\Pending-Step-*.log` | saídas das etapas executadas via `Run-AsAdmin.cmd` |

## 11. Como verificar o reparo

```powershell
sc.exe queryex lfsvc                 # STATE: 4 RUNNING, WIN32_EXIT_CODE 0
.\Verify-Location.ps1 -Functional    # Overall: PASS
```

Critério: `Files`, `lfsvc registry`, `ServiceDll`, `netsvcs`, `COM registry` (inclui ProgIDs, interfaces, TypeLib e WinRT),
`Service registration`, `Service start` = PASS. Avisos (WARN) de política/privacidade/Configurações, `System registry`,
`Scheduled tasks` e `Signature catalogs` são informativos (não impedem a localização de funcionar).

## Estrutura do kit

```
C:\Restore-Location\
  REPARAR-E-HABILITAR.cmd      lancador de 1 clique (diagnostica + executa so o necessario)
  Profiles\
    Win10-19041\  profile.json
                  Files\     binarios + manifest.csv (SHA256)
                  Registry\  lfsvc-restaurar.reg, location-registry.json, location-tasks.json
                  Tasks\     XML das tarefas agendadas \Microsoft\Windows\Location\*
                  Catalogs\  catalogos de assinatura (.cat) dos pacotes que contem os binarios
    Win11\        profile.json (perfil parcial: consentimento + remocao de politicas)
  Scripts\     KitProfile.ps1, Repair-And-Enable.ps1, Restore-Location.ps1, Enable-LocationPolicy.ps1,
               Remove-LocationPolicies.ps1, Verify-Location.ps1, Rollback-Location.ps1, Check-UserLocation.ps1,
               Run-AsAdmin.cmd, Pending-Step.ps1
  Backup\  Logs\  gerados em cada maquina (fora do repositorio)
```

Para levar a outra máquina, copie `REPARAR-E-HABILITAR.cmd`, `Profiles\`, `Scripts\` e este README.

As ferramentas de desenvolvimento **não fazem parte do kit** (dependem de uma ISO/`install.esd` original e do 7-Zip):
`Extract-Image.ps1` extrai da imagem os manifestos WinSxS, os hives e os catálogos, e `Build-LocationProfile.ps1` gera a partir
deles os arquivos, as entradas `"Source":"manifest"` do `location-registry.json`, as tarefas e os catálogos do perfil. Para criar
um **novo perfil** (ex.: Win11 completo) é preciso uma imagem do mesmo build e repetir esse processo, além do diagnóstico PE e da
comparação do hive `SOFTWARE` descritos nas seções 2–4.
