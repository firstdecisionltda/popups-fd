<#
.SYNOPSIS
    Instala (ou reinstala do zero) o sistema de popups/wallpaper/tela de bloqueio da First Decision.

.DESCRIPTION
    Pensado para rodar pela sessão SYSTEM do Sophos (também funciona como administrador).
    Pode ser rodado de novo na mesma máquina: cada execução é uma reinstalação limpa.
    1. Escolhe o usuário certo: o do console, ignorando contas de suporte/administração. Se só
       houver conta de suporte logada, deixa a instalação para o próximo logon de outro usuário.
    2. Limpeza (como SYSTEM): remove TODAS as tarefas do sistema, novas e antigas (inclusive as
       criadas no nome de outro usuário, que o usuário comum não consegue apagar), e apaga o cache
       (scripts, manifest, imagens). Os logs são mantidos.
    3. Baixa o manifest e o launcher do repositório público e CONFERE o SHA-256 do launcher.
    4. Roda o launcher com -Bootstrap COMO O USUÁRIO ESCOLHIDO (tarefa temporária). Ele baixa tudo
       de novo conferindo hash e cria as tarefas dos popups e da sincronização no nome dele.
    5. Cria a tarefa SYSTEM da tela de bloqueio (boot + a cada hora) e a roda uma vez.
    6. Confere tudo e grava uma linha final RESULTADO no log.
    Códigos de saída: 0 = instalado e conferido; 1 = erro; 2 = instalou com pendência;
                      3 = aguardando logon de um usuário (nada instalado ainda).
    Log: C:\ProgramData\FirstDecision\Instalador.log
#>
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$Raw            = "https://raw.githubusercontent.com/firstdecisionltda/popups-fd/main"
$Base           = "C:\ProgramData\FirstDecision"
$LauncherDir    = Join-Path $Base "Launcher"
$Launcher       = Join-Path $LauncherDir "Update-PopupScripts.ps1"
$Oculto         = Join-Path $LauncherDir "InstalarOculto.vbs"
$CacheDir       = Join-Path $Base "PopupScripts"
$VersaoFile     = Join-Path $CacheDir "current_version.txt"
$WallpaperLocal = Join-Path $CacheDir "Atualizar-Wallpaper.ps1"
$TarefaTemp     = "FD-Instalacao-Temp"
$TarefaSync     = "FirstDecision-LauncherSync"
$TarefaBloqueio = "FirstDecision-TelaBloqueio"
$LogFile        = Join-Path $Base "Instalador.log"
# Contas que nunca recebem a instalação (as tarefas dos popups ficam no perfil de quem instala).
$ContasIgnoradas = '(^|\\)(suporte|administrador|administrator|admin)$'
# Tarefas do sistema (atuais e aposentadas). A da GPO ("FirstDecision - Launcher Popup Central")
# não entra: a GPO a recria e ela só chama o launcher local.
$TarefasDoSistema = @("FD-Task-*", "FD-Popups-*", $TarefaSync, "FirstDecision-BootstrapInicial", $TarefaTemp, $TarefaBloqueio, "TASK POPUP - FD", "teste popup")

function Log([string]$m, [string]$n = "INFO") {
    $l = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $n, $m
    Write-Host $l
    try { Add-Content -Path $LogFile -Value $l -ErrorAction Stop } catch { }
}
function Sha256([byte[]]$b) { ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($b))).Replace("-", "") }
function ShaArquivo([string]$p) { if (Test-Path $p) { (Get-FileHash $p -Algorithm SHA256).Hash } else { "" } }
function Baixar([string]$caminho) {
    $wc = New-Object Net.WebClient
    $wc.Headers.Add("User-Agent", "FD-Instalador")
    $wc.Headers.Add("Cache-Control", "no-cache")
    $wc.DownloadData("$Raw/$caminho`?v=$(Get-Date -Format 'yyyyMMddHHmmss')$(Get-Random)")
}

try {
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Rode como SYSTEM ou administrador."
    }
    New-Item -ItemType Directory -Path $LauncherDir -Force | Out-Null
    Log "===== Início. Computador: $env:COMPUTERNAME ====="

    # 1) usuário certo: primeiro o do console; senão, outro com área de trabalho aberta.
    $comExplorer = @(Get-Process -Name explorer -IncludeUserName -ErrorAction SilentlyContinue | Where-Object { $_.UserName -and $_.UserName -notmatch 'SYSTEM$' } | Select-Object -ExpandProperty UserName -Unique)
    $console = "$((Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName)"
    $candidatos = @($comExplorer | Where-Object { $_ -notmatch $ContasIgnoradas })
    $ignorados = @($comExplorer | Where-Object { $_ -match $ContasIgnoradas })
    if ($ignorados.Count -gt 0) { Log "Sessões de suporte ignoradas: $($ignorados -join ', ')." "WARN" }
    $usuario = $null
    if ($console -and $candidatos -contains $console) { $usuario = $console }
    elseif ($candidatos.Count -gt 0) { $usuario = $candidatos[0] }
    if ($candidatos.Count -gt 1) { Log "Mais de um usuário logado ($($candidatos -join ', ')); escolhido: $usuario." "WARN" }

    # 2) manifest + launcher conferido (antes de apagar qualquer coisa: sem internet, nada muda)
    $mb = Baixar "manifest.json"
    if ($mb.Length -ge 3 -and $mb[0] -eq 0xEF -and $mb[1] -eq 0xBB -and $mb[2] -eq 0xBF) { $mb = $mb[3..($mb.Length - 1)] }
    $manifest = [Text.Encoding]::UTF8.GetString($mb) | ConvertFrom-Json
    $esperado = "$($manifest.launcher.sha256)".ToUpper()
    if ($esperado.Length -ne 64) { throw "Manifest sem hash do launcher." }
    Log "Manifest versão $($manifest.version)."
    $lb = $null
    foreach ($t in 1..3) {
        $lb = Baixar "Update-PopupScripts.ps1"
        if ((Sha256 $lb) -eq $esperado) { break }
        Log "Hash do launcher não confere (tentativa $t); o GitHub pode estar com cópia antiga. Aguardando." "WARN"
        $lb = $null; Start-Sleep -Seconds 20
    }
    if (-not $lb) { throw "Launcher baixado não confere com o hash do manifest. Nada foi alterado." }

    # 3) limpeza completa como SYSTEM
    foreach ($nome in $TarefasDoSistema) {
        foreach ($tk in @(Get-ScheduledTask -TaskName $nome -ErrorAction SilentlyContinue)) {
            try { Stop-ScheduledTask -TaskPath $tk.TaskPath -TaskName $tk.TaskName -ErrorAction SilentlyContinue } catch { }
            Unregister-ScheduledTask -TaskPath $tk.TaskPath -TaskName $tk.TaskName -Confirm:$false -ErrorAction SilentlyContinue
            if (Get-ScheduledTask -TaskPath $tk.TaskPath -TaskName $tk.TaskName -ErrorAction SilentlyContinue) { Log "Não consegui remover a tarefa $($tk.TaskPath)$($tk.TaskName)." "WARN" }
            else { Log "Tarefa removida: $($tk.TaskPath)$($tk.TaskName) (era de $($tk.Principal.UserId)$($tk.Principal.GroupId))." }
        }
    }
    # Processos do sistema ainda abertos (sincronização ou popup em andamento) prenderiam arquivos.
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(wscript|powershell)\.exe$' -and $_.CommandLine -match 'FirstDecision\\(Launcher|PopupScripts)' -and $_.ProcessId -ne $PID } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 2
    Get-ChildItem $LauncherDir -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Get-ChildItem $CacheDir -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne "Logs" } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    $sobras = @(Get-ChildItem $LauncherDir -Force -ErrorAction SilentlyContinue) + @(Get-ChildItem $CacheDir -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne "Logs" })
    if ($sobras.Count -gt 0) { Log "Arquivos que não puderam ser apagados (serão sobrescritos): $($sobras.Name -join ', ')." "WARN" }
    else { Log "Cache e launcher antigos apagados (logs mantidos)." }

    # 4) launcher novo + permissões para o usuário comum gravar
    New-Item -ItemType Directory -Path $LauncherDir, $CacheDir -Force | Out-Null
    [IO.File]::WriteAllBytes($Launcher, $lb)
    & icacls.exe $LauncherDir /grant "*S-1-5-32-545:(OI)(CI)M" /T *> $null
    & icacls.exe $CacheDir /grant "*S-1-5-32-545:(OI)(CI)M" /T *> $null
    Log "Launcher gravado e conferido (SHA-256 OK)."

    # 5) tarefa SYSTEM da tela de bloqueio. A tela de bloqueio é política de máquina (HKLM): só o
    # Atualizar-Wallpaper.ps1 rodando como SYSTEM a aplica. Tolera o arquivo ainda não existir.
    $acaoSys = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command `"if (Test-Path '$WallpaperLocal') { & '$WallpaperLocal' }; exit 0`""
    $gatilhos = @(
        (New-ScheduledTaskTrigger -AtStartup),
        (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) -RepetitionInterval (New-TimeSpan -Hours 1) -RepetitionDuration (New-TimeSpan -Days 3650))
    )
    $princSys = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $cfgSys = New-ScheduledTaskSettingsSet -Hidden -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    Register-ScheduledTask -TaskName $TarefaBloqueio -Action $acaoSys -Trigger $gatilhos -Principal $princSys -Settings $cfgSys -Force | Out-Null
    Log "Tarefa SYSTEM '$TarefaBloqueio' criada (boot + a cada hora)."

    # 6) tarefa temporária que roda o -Bootstrap como o usuário escolhido
    # O caminho do launcher não tem espaço, então a linha de comando vai SEM aspas (aspas dentro de
    # string VBScript quebram a sintaxe e deixam o wscript parado).
    $cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Launcher -Bootstrap"
    if ($cmd -match '"') { throw "Linha de comando com aspas; não gerado." }
    # Guardas no próprio .vbs: não instala em conta de suporte e não reinstala se já instalado
    # (a tarefa de logon do caso "pendente" fica e dispararia em todo logon).
    $vbs = @(
        'u = LCase(CreateObject("WScript.Network").UserName)',
        'If u = "suporte" Or u = "administrador" Or u = "administrator" Or u = "admin" Then WScript.Quit',
        "If CreateObject(""Scripting.FileSystemObject"").FileExists(""$VersaoFile"") Then WScript.Quit",
        "CreateObject(""WScript.Shell"").Run ""$cmd"", 0, False"
    ) -join "`r`n"
    [IO.File]::WriteAllText($Oculto, $vbs + "`r`n", (New-Object Text.UTF8Encoding($false)))
    $acao = New-ScheduledTaskAction -Execute "wscript.exe" -Argument """$Oculto"""
    $cfg = New-ScheduledTaskSettingsSet -Hidden -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 10)

    if (-not $usuario) {
        # Ninguém (ou só suporte) logado: o próximo logon de um usuário real dispara a instalação
        # (o .vbs sai sem fazer nada no logon do suporte).
        $princ = New-ScheduledTaskPrincipal -GroupId "S-1-5-32-545" -RunLevel Limited
        Register-ScheduledTask -TaskName $TarefaTemp -Action $acao -Trigger (New-ScheduledTaskTrigger -AtLogOn) -Principal $princ -Settings $cfg | Out-Null
        Log "RESULTADO: PENDENTE - nenhum usuário real logado. Limpeza feita; a instalação conclui no próximo logon do usuário." "WARN"
        exit 3
    }

    $princ = New-ScheduledTaskPrincipal -UserId $usuario -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $TarefaTemp -Action $acao -Principal $princ -Settings $cfg | Out-Null
    Log "Instalando para $usuario (o launcher espera ~60 s antes de baixar)."
    Start-ScheduledTask -TaskName $TarefaTemp

    # 7) espera a instalação do usuário: tarefa de sincronização + versão + tarefas dos popups
    $agendados = @($manifest.scripts | Where-Object { $_.run -eq $true -and $_.trigger })
    $limite = (Get-Date).AddSeconds(300)
    $ok = $false
    while ((Get-Date) -lt $limite) {
        Start-Sleep -Seconds 5
        $v = "$(Get-Content $VersaoFile -ErrorAction SilentlyContinue | Select-Object -First 1)".Trim()
        if ((Get-ScheduledTask -TaskName $TarefaSync -ErrorAction SilentlyContinue) -and $v -eq $manifest.version -and @(Get-ScheduledTask -TaskName "FD-Task-*" -ErrorAction SilentlyContinue).Count -ge $agendados.Count) { $ok = $true; Start-Sleep -Seconds 10; break }
    }

    # 8) tela de bloqueio agora (a imagem já foi baixada pelo launcher)
    if (Test-Path $WallpaperLocal) {
        Start-ScheduledTask -TaskName $TarefaBloqueio
        $limite = (Get-Date).AddSeconds(90)
        do { Start-Sleep -Seconds 3 } while ((Get-ScheduledTask -TaskName $TarefaBloqueio).State -eq "Running" -and (Get-Date) -lt $limite)
    }

    # 9) conferência final
    $problemas = @()
    if (-not $ok) { $problemas += "instalação do usuário não concluiu em 5 min (veja $CacheDir\Logs)" }
    $sync = Get-ScheduledTask -TaskName $TarefaSync -ErrorAction SilentlyContinue
    if (-not $sync) { $problemas += "falta a tarefa $TarefaSync" }
    elseif ($sync.Principal.UserId -and $usuario -notmatch "(^|\\)$([regex]::Escape(($sync.Principal.UserId -split '\\')[-1]))$") { $problemas += "$TarefaSync está no nome de $($sync.Principal.UserId)" }
    foreach ($s in $agendados) {
        $nomeTarefa = "FD-Task-" + [IO.Path]::GetFileNameWithoutExtension($s.name)
        $tk = Get-ScheduledTask -TaskName $nomeTarefa -ErrorAction SilentlyContinue
        if (-not $tk) { $problemas += "falta a tarefa $nomeTarefa" }
        elseif ($tk.Settings.StartWhenAvailable) { $problemas += "$nomeTarefa com StartWhenAvailable ligado" }
    }
    foreach ($s in @($manifest.scripts | Where-Object { $_.run -eq $true })) {
        if ((ShaArquivo (Join-Path $CacheDir $s.name)) -ne "$($s.sha256)".ToUpper()) { $problemas += "$($s.name) ausente ou com hash diferente" }
    }
    foreach ($a in @($manifest.assets)) {
        if ((ShaArquivo (Join-Path $CacheDir "Assets\$($a.localName)")) -ne "$($a.sha256)".ToUpper()) { $problemas += "$($a.localName) ausente ou com hash diferente" }
    }
    if ((ShaArquivo $Launcher) -ne $esperado) { $problemas += "launcher local com hash diferente" }
    $info = Get-ScheduledTaskInfo -TaskName $TarefaBloqueio -ErrorAction SilentlyContinue
    if (-not $info -or $info.LastTaskResult -ne 0) { $problemas += "tela de bloqueio: última execução com resultado $($info.LastTaskResult)" }
    $imgPolitica = (Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization" -Name LockScreenImage -ErrorAction SilentlyContinue).LockScreenImage
    if ($imgPolitica -ne (Join-Path $CacheDir "Assets\wallpaper.jpg")) { $problemas += "política LockScreenImage não gravada ($imgPolitica)" }
    if (@(Get-ScheduledTask -TaskName "TASK POPUP - FD" -ErrorAction SilentlyContinue).Count -gt 0) { $problemas += "tarefa antiga TASK POPUP - FD ainda existe" }

    if ($problemas.Count -eq 0) {
        Unregister-ScheduledTask -TaskName $TarefaTemp -Confirm:$false -ErrorAction SilentlyContinue
        Remove-Item $Oculto -Force -ErrorAction SilentlyContinue
        $tarefas = @(Get-ScheduledTask -TaskName "FD-Task-*" -ErrorAction SilentlyContinue | ForEach-Object { $_.TaskName })
        Log "RESULTADO: OK - usuário $usuario, versão $($manifest.version), tarefas $($tarefas -join ', '), tela de bloqueio aplicada. Check-in no SharePoint em até ~20 min."
        exit 0
    }
    Log "RESULTADO: COM PENDÊNCIA - $($problemas -join '; '). A tarefa temporária fica para nova tentativa no próximo logon." "WARN"
    exit 2
} catch {
    Log "RESULTADO: ERRO - $($_.Exception.Message)" "ERROR"
    exit 1
}
