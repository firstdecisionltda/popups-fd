<#
.SYNOPSIS
    Instala o sistema de popups/wallpaper da First Decision numa máquina que ainda não tem.

.DESCRIPTION
    Pensado para rodar pela sessão SYSTEM do Sophos (também funciona como administrador).
    1. Baixa o manifest do repositório público e lê o hash esperado do launcher.
    2. Baixa o launcher e CONFERE o SHA-256. Se não bater, não instala nada.
    3. Grava o launcher em C:\ProgramData\FirstDecision\Launcher.
    4. Roda o launcher com -Bootstrap COMO O USUÁRIO LOGADO, por uma tarefa temporária
       (se rodasse como SYSTEM, as tarefas dos popups ficariam em outra sessão e ninguém veria
       o popup). Sem ninguém logado, a tarefa espera o próximo logon.
    5. Confere se a instalação apareceu (tarefa de sincronização + versão do manifest) e
       remove a tarefa temporária.
    Pode ser rodado de novo na mesma máquina sem duplicar nada.
    Log: C:\ProgramData\FirstDecision\Instalador.log
#>
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$Raw          = "https://raw.githubusercontent.com/firstdecisionltda/popups-fd/main"
$Base         = "C:\ProgramData\FirstDecision"
$LauncherDir  = Join-Path $Base "Launcher"
$Launcher     = Join-Path $LauncherDir "Update-PopupScripts.ps1"
$Oculto       = Join-Path $LauncherDir "InstalarOculto.vbs"
$VersaoFile   = Join-Path $Base "PopupScripts\current_version.txt"
$TarefaTemp   = "FD-Instalacao-Temp"
$TarefaSync   = "FirstDecision-LauncherSync"
$LogFile      = Join-Path $Base "Instalador.log"

function Log([string]$m, [string]$n = "INFO") {
    $l = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $n, $m
    Write-Host $l
    try { Add-Content -Path $LogFile -Value $l -ErrorAction Stop } catch { }
}
function Sha256([byte[]]$b) { ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($b))).Replace("-", "") }
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
    Log "Início. Computador: $env:COMPUTERNAME"

    # 1) manifest -> hash esperado do launcher
    $mb = Baixar "manifest.json"
    if ($mb.Length -ge 3 -and $mb[0] -eq 0xEF -and $mb[1] -eq 0xBB -and $mb[2] -eq 0xBF) { $mb = $mb[3..($mb.Length - 1)] }
    $manifest = [Text.Encoding]::UTF8.GetString($mb) | ConvertFrom-Json
    $esperado = "$($manifest.launcher.sha256)".ToUpper()
    if ($esperado.Length -ne 64) { throw "Manifest sem hash do launcher." }
    Log "Manifest versão $($manifest.version); hash esperado do launcher $($esperado.Substring(0,12))..."

    # 2) launcher conferido por hash
    $lb = $null
    foreach ($t in 1..3) {
        $lb = Baixar "Update-PopupScripts.ps1"
        if ((Sha256 $lb) -eq $esperado) { break }
        Log "Hash do launcher não confere (tentativa $t); o GitHub pode estar com cópia antiga. Aguardando." "WARN"
        $lb = $null; Start-Sleep -Seconds 20
    }
    if (-not $lb) { throw "Launcher baixado não confere com o hash do manifest. Nada foi instalado." }
    [IO.File]::WriteAllBytes($Launcher, $lb)
    & icacls.exe $LauncherDir /grant "*S-1-5-32-545:(OI)(CI)M" /T *> $null
    Log "Launcher gravado e conferido (SHA-256 OK)."

    # 3) tarefa temporária que roda o -Bootstrap como o usuário logado
    # O caminho do launcher não tem espaço, então a linha de comando vai SEM aspas (aspas dentro de
    # string VBScript quebram a sintaxe e deixam o wscript parado).
    $cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Launcher -Bootstrap"
    if ($cmd -match '"') { throw "Linha de comando com aspas; não gerado." }
    [IO.File]::WriteAllText($Oculto, "CreateObject(""WScript.Shell"").Run ""$cmd"", 0, False`r`n", (New-Object Text.UTF8Encoding($false)))

    # Limpa restos de tentativas anteriores (tarefa temporária e wscript preso).
    Unregister-ScheduledTask -TaskName $TarefaTemp -Confirm:$false -ErrorAction SilentlyContinue
    Get-CimInstance Win32_Process -Filter "Name='wscript.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match 'InstalarOculto' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    $acao = New-ScheduledTaskAction -Execute "wscript.exe" -Argument """$Oculto"""
    $cfg = New-ScheduledTaskSettingsSet -Hidden -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 10)

    # Ignora contas de suporte/administração (as tarefas dos popups ficam no perfil de quem instala,
    # então instalar como "suporte" deixaria o usuário real sem popup). Se só elas estiverem logadas,
    # cai no ramo "ninguém logado": a instalação conclui no próximo logon do usuário real.
    $logado = @(Get-Process -Name explorer -IncludeUserName -ErrorAction SilentlyContinue | Where-Object { $_.UserName -and $_.UserName -notmatch 'SYSTEM$' -and $_.UserName -notmatch '(^|\\)(suporte|administrador|administrator)$' } | Select-Object -ExpandProperty UserName -Unique)
    $ignorados = @(Get-Process -Name explorer -IncludeUserName -ErrorAction SilentlyContinue | Where-Object { $_.UserName -and $_.UserName -match '(^|\\)(suporte|administrador|administrator)$' } | Select-Object -ExpandProperty UserName -Unique)
    if ($ignorados.Count -gt 0) { Log "Sessões de suporte ignoradas: $($ignorados -join ', ')." "WARN" }
    if ($logado.Count -gt 0) {
        # Dono da tarefa = o usuário logado (iniciada na hora, sem gatilho). Grupo "Usuários" não
        # aceita Start-ScheduledTask manual (erro "arquivo não encontrado").
        $princ = New-ScheduledTaskPrincipal -UserId $logado[0] -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName $TarefaTemp -Action $acao -Principal $princ -Settings $cfg | Out-Null
        Log "Tarefa temporária '$TarefaTemp' criada para $($logado[0]). Iniciando a instalação agora."
        Start-ScheduledTask -TaskName $TarefaTemp
    } else {
        # Ninguém logado: qualquer usuário que fizer logon dispara a instalação.
        $princ = New-ScheduledTaskPrincipal -GroupId "S-1-5-32-545" -RunLevel Limited
        Register-ScheduledTask -TaskName $TarefaTemp -Action $acao -Trigger (New-ScheduledTaskTrigger -AtLogOn) -Principal $princ -Settings $cfg | Out-Null
        Log "Ninguém logado. A instalação ocorre no próximo logon (tarefa temporária '$TarefaTemp' fica aguardando)." "WARN"
    }

    # 3b) tarefa SYSTEM da tela de bloqueio (substitui a da GPO). A tela de bloqueio é política de
    # máquina (HKLM): só o Atualizar-Wallpaper.ps1 rodando como SYSTEM consegue aplicá-la, e o
    # launcher do usuário não. A tarefa tolera o arquivo ainda não existir (o launcher o baixa em
    # seguida) e roda no boot e de hora em hora, igual à da GPO. Idempotente (-Force).
    $WallpaperLocal = Join-Path $Base "PopupScripts\Atualizar-Wallpaper.ps1"
    $TarefaBloqueio = "FirstDecision-TelaBloqueio"
    $acaoSys = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command `"if (Test-Path '$WallpaperLocal') { & '$WallpaperLocal' }`""
    $gatilhos = @(
        (New-ScheduledTaskTrigger -AtStartup),
        (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) -RepetitionInterval (New-TimeSpan -Hours 1) -RepetitionDuration (New-TimeSpan -Days 3650))
    )
    $princSys = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $cfgSys = New-ScheduledTaskSettingsSet -Hidden -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    Register-ScheduledTask -TaskName $TarefaBloqueio -Action $acaoSys -Trigger $gatilhos -Principal $princSys -Settings $cfgSys -Force | Out-Null
    Log "Tarefa SYSTEM '$TarefaBloqueio' criada (boot + a cada hora)."

    # 4) confere o resultado (o bootstrap espera ~60 s antes de sincronizar)
    $ok = $false
    if ($logado.Count -gt 0) {
        $limite = (Get-Date).AddSeconds(240)
        while ((Get-Date) -lt $limite) {
            Start-Sleep -Seconds 5
            if ((Get-ScheduledTask -TaskName $TarefaSync -ErrorAction SilentlyContinue) -and (Test-Path $VersaoFile) -and (Get-ScheduledTask -TaskName "FD-Task-*" -ErrorAction SilentlyContinue)) { $ok = $true; Start-Sleep -Seconds 5; break }
        }
    }

    if ($ok) {
        if (Test-Path $WallpaperLocal) { Start-ScheduledTask -TaskName $TarefaBloqueio -ErrorAction SilentlyContinue; Log "Tela de bloqueio: tarefa SYSTEM iniciada agora." }
        Unregister-ScheduledTask -TaskName $TarefaTemp -Confirm:$false -ErrorAction SilentlyContinue
        Remove-Item $Oculto -Force -ErrorAction SilentlyContinue
        $tarefas = @(Get-ScheduledTask -TaskName "FD-Task-*" -ErrorAction SilentlyContinue | ForEach-Object { $_.TaskName })
        Log "INSTALADO. Versão do manifest local: $((Get-Content $VersaoFile -ErrorAction SilentlyContinue | Select-Object -First 1)). Tarefas dos popups: $($tarefas.Count) ($($tarefas -join ', '))."
        Log "O check-in aparece na lista do SharePoint até o fim do ciclo seguinte (~20 min)."
    } elseif ($logado.Count -gt 0) {
        Log "A instalação não apareceu em 4 min. Veja C:\ProgramData\FirstDecision\PopupScripts\Logs. A tarefa temporária foi mantida para nova tentativa no próximo logon." "WARN"
        exit 2
    } else {
        Log "PENDENTE: conclui sozinho no próximo logon de um usuário."
    }
} catch {
    Log "ERRO: $($_.Exception.Message)" "ERROR"
    exit 1
}
