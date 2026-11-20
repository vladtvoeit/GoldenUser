#requires -Version 5.1
<#
    GoldenUser - снимок и восстановление эталонного профиля локального пользователя Windows 10/11.

    Сценарий:
      1. На новом ноутбуке настраиваете пользователя (по умолчанию "user") с ПУСТЫМ паролем:
         обои, ярлыки, сетевые диски, принтеры, Office запущен хотя бы раз.
      2. Выходите из "user", входите под администратором, запускаете этот инструмент,
         нажимаете "Снять эталон". Копия профиля ложится в C:\Golden\<user>\.
      3. Через год: входите под администратором (TeamViewer), нажимаете "Восстановить":
         профиль возвращается к снимку, пароль сбрасывается на пустой, старый профиль
         уезжает в C:\Backups\<user>_<дата>, ноутбук перезагружается.

    Снимок и восстановление делаются на ОДНОМ И ТОМ ЖЕ компьютере (одинаковый SID),
    поэтому Credential Manager, сохранённые пароли и DPAPI-данные остаются рабочими,
    если пароль "user" на момент снимка и после сброса одинаковый (пустой).

    Сборка в один .exe:  Install-Module ps2exe;  Invoke-ps2exe .\GoldenUser.ps1 .\GoldenUser.exe -requireAdmin -noConsole
#>

param(
    [string]$User       = 'user',
    [string]$GoldenRoot = 'C:\Golden',
    [string]$BackupRoot = 'C:\Backups'
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ------------------------------------------------------------------ настройки
# Папки с мусором, которые НЕ попадают в эталон (сравнение по имени папки, на любой глубине).
# WindowsApps - псевдонимы выполнения приложений (App Execution Aliases): reparse-точки, которые
# нельзя скопировать как файлы (robocopy: ERROR 1920); Windows пересоздаёт их при входе пользователя.
$Script:ExcludeDirs  = @('Temp', 'INetCache', 'WER', 'Cache', 'Code Cache', 'GPUCache', 'cache2', 'CrashDumps', 'CacheStorage', 'ShaderCache', 'WindowsApps')
$Script:ExcludeFiles = @('*.tmp', '~$*')

# ------------------------------------------------------------------ права администратора
$Script:IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $Script:IsAdmin) {
    if ($PSCommandPath) {
        Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -File `"$PSCommandPath`" -User `"$User`" -GoldenRoot `"$GoldenRoot`" -BackupRoot `"$BackupRoot`""
        exit
    }
    [System.Windows.Forms.MessageBox]::Show('Запустите программу от имени администратора.', 'GoldenUser', 'OK', 'Error') | Out-Null
    exit 1
}

# Вывод консольных утилит (net, robocopy) на русской Windows идёт в OEM-кодировке (CP866).
# Без консоли (ps2exe -noConsole) PowerShell по умолчанию читает его как ANSI - выставляем явно.
try { [Console]::OutputEncoding = [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage) } catch { }

# ------------------------------------------------------------------ GUI
[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.Text          = 'GoldenUser - эталонный профиль пользователя'
$form.Size          = New-Object System.Drawing.Size(760, 600)
$form.MinimumSize   = New-Object System.Drawing.Size(640, 480)
$form.StartPosition = 'CenterScreen'
$form.Font          = New-Object System.Drawing.Font('Segoe UI', 9)

function New-Label($text, $x, $y, $w) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.Location = New-Object System.Drawing.Point($x, $y); $l.Size = New-Object System.Drawing.Size($w, 20); $l.TextAlign = 'MiddleLeft'
    $form.Controls.Add($l); $l
}
function New-TextBox($text, $x, $y, $w) {
    $t = New-Object System.Windows.Forms.TextBox
    $t.Text = $text; $t.Location = New-Object System.Drawing.Point($x, $y); $t.Size = New-Object System.Drawing.Size($w, 23)
    $t.Anchor = 'Top,Left,Right'
    $form.Controls.Add($t); $t
}
function New-CheckBox($text, $x, $y, $w, $checked) {
    $c = New-Object System.Windows.Forms.CheckBox
    $c.Text = $text; $c.Location = New-Object System.Drawing.Point($x, $y); $c.Size = New-Object System.Drawing.Size($w, 22); $c.Checked = $checked
    $form.Controls.Add($c); $c
}
function New-Button($text, $x, $y, $w) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text; $b.Location = New-Object System.Drawing.Point($x, $y); $b.Size = New-Object System.Drawing.Size($w, 32)
    $form.Controls.Add($b); $b
}

New-Label 'Пользователь:'      12  14 120 | Out-Null
$txtUser   = New-TextBox $User       140  12 200
$txtUser.Anchor = 'Top,Left'
New-Label 'Папка эталонов:'    12  44 120 | Out-Null
$txtGolden = New-TextBox $GoldenRoot 140  42 590
New-Label 'Папка резервных копий:' 12 74 125 | Out-Null
$txtBackup = New-TextBox $BackupRoot 140  72 590

$chkPwd    = New-CheckBox 'Сбросить пароль пользователя на пустой'              12 104 360 $true
$chkPin    = New-CheckBox 'Сбросить PIN (Windows Hello) - для всех учёток ПК'   12 128 360 $false
$chkBackup = New-CheckBox 'Сохранить старый профиль в папку резервных копий'   380 104 360 $true
$chkReboot = New-CheckBox 'Перезагрузить компьютер после восстановления/очистки' 380 128 360 $true

$btnCheck    = New-Button 'Проверить'              12  162 104
$btnSnapshot = New-Button 'Снять эталон'           122 162 120
$btnRestore  = New-Button 'ВОССТАНОВИТЬ'           248 162 150
$btnRestore.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$btnClean    = New-Button 'Очистить профиль'       404 162 150
$btnOpen     = New-Button 'Папка эталонов'         560 162 170

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Multiline = $true; $txtLog.ScrollBars = 'Vertical'; $txtLog.ReadOnly = $true; $txtLog.WordWrap = $false
$txtLog.Font = New-Object System.Drawing.Font('Consolas', 9)
$txtLog.Location = New-Object System.Drawing.Point(12, 204)
$txtLog.Size = New-Object System.Drawing.Size(718, 320)
$txtLog.Anchor = 'Top,Bottom,Left,Right'
$form.Controls.Add($txtLog)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Location = New-Object System.Drawing.Point(12, 532); $lblStatus.Size = New-Object System.Drawing.Size(718, 22)
$lblStatus.Anchor = 'Bottom,Left,Right'; $lblStatus.Text = 'Готово.'
$form.Controls.Add($lblStatus)

# ------------------------------------------------------------------ служебные функции
function DoEvents { [System.Windows.Forms.Application]::DoEvents() }

function Log([string]$Message, [string]$Level = 'INFO') {
    $line = '[{0}] {1} {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level.PadRight(5), $Message
    $txtLog.AppendText($line + "`r`n")
    if ($Script:LogFile) { try { Add-Content -LiteralPath $Script:LogFile -Value $line -Encoding UTF8 } catch { } }
    DoEvents
}
function Warn([string]$m) { Log $m 'WARN' }
function Fail([string]$m) { Log $m 'ERROR' }

function Set-Status([string]$text) { $lblStatus.Text = $text; DoEvents }

function Set-Busy([bool]$busy) {
    foreach ($b in @($btnCheck, $btnSnapshot, $btnRestore, $btnClean, $btnOpen)) { $b.Enabled = -not $busy }
    $form.UseWaitCursor = $busy
    DoEvents
}

function Confirm([string]$text, [string]$title = 'Подтверждение') {
    $r = [System.Windows.Forms.MessageBox]::Show($form, $text, $title, 'YesNo', 'Warning', 'Button2')
    return ($r -eq 'Yes')
}

function Assert-SafeFolder([string]$path, [string]$label) {
    # Запрещаем корень диска и системные папки: на них нельзя менять ACL и складывать эталон.
    if (-not [IO.Path]::IsPathRooted($path)) { throw "$label должна быть абсолютным путём (например, C:\Golden): '$path'." }
    $full = [IO.Path]::GetFullPath($path).TrimEnd('\')
    $rootOfDrive = [IO.Path]::GetPathRoot($full).TrimEnd('\')
    if ($full -ieq $rootOfDrive) { throw "$label не может быть корнем диска ($path). Укажите подпапку, например ${rootOfDrive}\Golden." }
    $forbidden = @($env:SystemRoot, "$env:SystemDrive\Users", $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData) | Where-Object { $_ }
    foreach ($f in $forbidden) {
        $f = $f.TrimEnd('\')
        if ($full -ieq $f -or $full.StartsWith("$f\", [StringComparison]::OrdinalIgnoreCase)) { throw "$label не может находиться в системной папке $f." }
    }
    return $full
}

function Get-Paths {
    $name   = $txtUser.Text.Trim()
    $root   = $txtGolden.Text.Trim()
    $backup = $txtBackup.Text.Trim()
    if (-not $name) { throw 'Не указано имя пользователя.' }
    if (-not $root) { throw 'Не указана папка эталонов.' }
    $root = Assert-SafeFolder $root 'Папка эталонов'
    if ($backup) { $backup = Assert-SafeFolder $backup 'Папка резервных копий' }
    [pscustomobject]@{
        Name       = $name
        GoldenRoot = $root
        Golden     = Join-Path $root $name
        Profile    = Join-Path (Join-Path $root $name) 'Profile'
        Manifest   = Join-Path (Join-Path $root $name) 'manifest.json'
        AclFile    = Join-Path (Join-Path $root $name) 'acl.txt'
        BackupRoot = $backup
        LogDir     = Join-Path $root 'logs'
    }
}

function Ensure-GoldenRoot([string]$root, [switch]$SetAcl) {
    $created = $false
    if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null; $created = $true }
    # Только SYSTEM и Администраторы, наследование отключено. SID-ы, чтобы не зависеть от языка Windows.
    # ACL меняем только при создании папки или при снятии эталона - кнопка "Проверить" прав не трогает.
    if ($created -or $SetAcl) {
        & icacls.exe "$root" /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' /q | Out-Null
    }
    $logDir = Join-Path $root 'logs'
    if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $Script:LogFile = Join-Path $root 'GoldenUser.log'
}

function Get-TargetUser([string]$name, [switch]$AllowNoProfile) {
    $lu = Get-LocalUser -Name $name -ErrorAction Stop
    $sid = $lu.SID.Value
    $me  = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if ($me -eq $sid) { throw "Вы вошли как '$name'. Запускайте инструмент из другой (административной) учётной записи." }
    $prof = Get-CimInstance Win32_UserProfile -Filter "SID='$sid'" -ErrorAction Stop
    if (-not $prof -and -not $AllowNoProfile) { throw "У пользователя '$name' сейчас нет профиля на этом ПК (он ни разу не входил или профиль очищен). Войдите под ним один раз и выйдите, затем повторите." }
    [pscustomobject]@{
        Name    = $lu.Name
        Sid     = $sid
        Path    = $(if ($prof) { $prof.LocalPath.TrimEnd('\') } else { $null })
        Enabled = $lu.Enabled
        Loaded  = $(if ($prof) { [bool]$prof.Loaded } else { $false })
        Source  = [string]$lu.PrincipalSource
    }
}

function Test-HiveLoaded([string]$sid) {
    # NTUSER.DAT -> HKU\<SID>, UsrClass.dat -> HKU\<SID>_Classes; оба должны быть выгружены
    return ((Test-Path -LiteralPath "Registry::HKEY_USERS\$sid") -or (Test-Path -LiteralPath "Registry::HKEY_USERS\${sid}_Classes"))
}

function Stop-UserProcesses($u) {
    try {
        $procs = Get-Process -IncludeUserName -ErrorAction SilentlyContinue |
            Where-Object { $_.UserName -and ($_.UserName -split '\\')[-1] -ieq $u.Name }
        foreach ($pr in @($procs)) {
            Warn "Завершаю процесс $($pr.ProcessName) (PID $($pr.Id)) пользователя $($u.Name)"
            Stop-Process -Id $pr.Id -Force -ErrorAction SilentlyContinue
        }
    } catch { }
}

function Get-UserSessions([string]$name) {
    $ids = @()
    $out = & quser.exe 2>$null
    if (-not $out) { return $ids }
    foreach ($raw in ($out | Select-Object -Skip 1)) {
        $line = $raw -replace '^\s*>', ' '
        # USERNAME  [SESSIONNAME]  ID  STATE ...
        if ($line -match '^\s*(\S+)\s+(?:(\S+)\s+)?(\d+)\s+(\S+)') {
            if ($Matches[1] -ieq $name) { $ids += [int]$Matches[3] }
        }
    }
    return $ids
}

function Ensure-LoggedOff($u) {
    $sessions = Get-UserSessions $u.Name
    foreach ($id in $sessions) {
        Log "Завершаю сеанс #$id пользователя $($u.Name) (несохранённые документы будут потеряны)..."
        & logoff.exe $id 2>$null
    }
    if ($sessions) { Start-Sleep -Seconds 5; DoEvents }
    # Фоновые процессы пользователя (OneDrive, Teams, задачи планировщика) держат файлы в AppData
    # даже после выхода - завершаем безусловно.
    Stop-UserProcesses $u
    $deadline = (Get-Date).AddSeconds(90)
    $tick = 0
    while ((Test-HiveLoaded $u.Sid) -and (Get-Date) -lt $deadline) {
        Set-Status 'Жду выгрузки профиля пользователя...'
        Start-Sleep -Milliseconds 1000; DoEvents
        if ((++$tick % 15) -eq 0) { Stop-UserProcesses $u }
    }
    if (Test-HiveLoaded $u.Sid) {
        throw "Куст реестра пользователя $($u.Name) всё ещё загружен. Перезагрузите ПК, войдите ТОЛЬКО под администратором и повторите."
    }
    Log "Пользователь $($u.Name) не в системе, профиль выгружен."
}

function Invoke-Robocopy([string]$Src, [string]$Dst, [string[]]$Options, [string]$LogName) {
    $Src = $Src.TrimEnd('\'); $Dst = $Dst.TrimEnd('\')
    $rlog = Join-Path (Get-Paths).LogDir ("{0}_{1}.log" -f $LogName, (Get-Date -Format 'yyyyMMdd_HHmmss'))
    # /UNILOG - журнал в Unicode, чтобы русские строки читались независимо от кодовой страницы
    $rcArgs = @("`"$Src`"", "`"$Dst`"") + $Options + @('/R:1', '/W:1', '/NP', '/NFL', '/NDL', '/NJH', "/UNILOG:`"$rlog`"")
    Log ("robocopy " + ($rcArgs -join ' '))
    $p = Start-Process -FilePath robocopy.exe -ArgumentList ($rcArgs -join ' ') -PassThru -WindowStyle Hidden
    while (-not $p.HasExited) { Start-Sleep -Milliseconds 400; DoEvents }
    $p.WaitForExit()
    try {
        Get-Content -LiteralPath $rlog -Tail 12 -Encoding Unicode -ErrorAction Stop |
            Where-Object { $_ -match '^\s*\S[^:]*:\s+\d' } |
            ForEach-Object { Log ('  ' + ($_ -replace '\s{2,}', ' ').Trim()) }
    } catch { }
    Log "robocopy завершён с кодом $($p.ExitCode) (0-7 = успех, >=8 = были ошибки, подробности: $rlog)"
    return $p.ExitCode
}

function Invoke-Icacls([string[]]$IcaclsArgs) {
    # icacls по большому профилю работает минуты - крутим цикл сообщений, чтобы окно не "висело"
    $p = Start-Process -FilePath icacls.exe -ArgumentList ($IcaclsArgs -join ' ') -PassThru -WindowStyle Hidden
    while (-not $p.HasExited) { Start-Sleep -Milliseconds 300; DoEvents }
    $p.WaitForExit()
    return $p.ExitCode
}

function Get-Junctions([string]$Root) {
    # Соединения (junction) и символические ссылки на папки внутри профиля:
    # robocopy /XJ их не копирует, поэтому запоминаем и пересоздаём при восстановлении.
    # Обход своей очередью, НЕ заходя внутрь reparse point: иначе петля
    # AppData\Local\Application Data -> AppData\Local уводит в бесконечную рекурсию.
    $list  = New-Object System.Collections.Generic.List[object]
    $queue = New-Object System.Collections.Generic.Queue[string]
    $queue.Enqueue($Root)
    $n = 0
    while ($queue.Count -gt 0) {
        $dir = $queue.Dequeue()
        $children = Get-ChildItem -LiteralPath $dir -Directory -Force -ErrorAction SilentlyContinue
        foreach ($d in @($children)) {
            if ($d.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                if ($d.LinkType -eq 'Junction' -or $d.LinkType -eq 'SymbolicLink') {
                    $target = @($d.Target)[0]
                    if ($target) {
                        $list.Add([pscustomobject]@{
                            Path       = $d.FullName.Substring($Root.Length).TrimStart('\')
                            Target     = [string]$target
                            Type       = [string]$d.LinkType
                            Attributes = [string]$d.Attributes
                        })
                    }
                }
            } else {
                $queue.Enqueue($d.FullName)
            }
        }
        if ((++$n % 200) -eq 0) { DoEvents }
    }
    return @($list | Sort-Object Path -Unique)
}

function Restore-Junctions([string]$Root, $Junctions) {
    $n = 0
    foreach ($j in @($Junctions)) {
        if (-not $j -or -not $j.Path -or -not $j.Target) { continue }
        $full = Join-Path $Root $j.Path
        if (Test-Path -LiteralPath $full) { continue }
        $parent = Split-Path $full -Parent
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        $flag = if ($j.Type -eq 'SymbolicLink') { '/D' } else { '/J' }
        & cmd.exe /c "mklink $flag `"$full`" `"$($j.Target)`"" 2>&1 | Out-Null
        if (-not (Test-Path -LiteralPath $full)) { Warn "Не удалось создать ссылку $full -> $($j.Target)"; continue }
        $n++
        $attrs = [string]$j.Attributes
        if ($attrs -match 'System') {
            # Служебные ссылки Windows (Application Data, Local Settings, My Documents...):
            # у самой ссылки стоит запрет на чтение списка папки для всех (чтобы обходчики не зацикливались)
            # и атрибуты Hidden+System. /l - применить к самой ссылке, не к цели.
            # Сначала атрибуты, потом запрет; запрещаем только RD (list directory), а не SYNCHRONIZE (S),
            # иначе attrib/rmdir/Get-Item к самой ссылке получают "отказано в доступе".
            & attrib.exe +h +s "$full" /l 2>&1 | Out-Null
            & icacls.exe "$full" /deny '*S-1-1-0:(RD)' /l /q 2>&1 | Out-Null
        } elseif ($attrs -match 'Hidden') {
            & attrib.exe +h "$full" /l 2>&1 | Out-Null
        }
    }
    Log "Пересоздано ссылок/соединений: $n"
}

function Remove-JunctionsIn([string]$Root) {
    # Убираем соединения из старого профиля: они указывают абсолютными путями в НОВЫЙ профиль,
    # и неосторожное удаление папки могло бы пройти по ним.
    foreach ($j in (Get-Junctions $Root)) {
        $full = Join-Path $Root $j.Path
        & cmd.exe /c "rmdir `"$full`"" 2>&1 | Out-Null
    }
}

function Repair-ProfileList([string]$sid, [string]$path) {
    $pl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
    $k = Join-Path $pl $sid; $bak = "$k.bak"
    if (Test-Path -LiteralPath $bak) {
        if (Test-Path -LiteralPath $k) { Remove-Item -LiteralPath $bak -Recurse -Force; Warn 'Удалён ключ ProfileList\<SID>.bak (признак "временного профиля").' }
        else { Rename-Item -LiteralPath $bak -NewName $sid; Warn 'Ключ ProfileList\<SID>.bak переименован обратно в <SID>.' }
    }
    if (Test-Path -LiteralPath $k) {
        Set-ItemProperty -LiteralPath $k -Name State -Value 0 -Type DWord -ErrorAction SilentlyContinue
        Set-ItemProperty -LiteralPath $k -Name RefCount -Value 0 -Type DWord -ErrorAction SilentlyContinue
        Set-ItemProperty -LiteralPath $k -Name ProfileImagePath -Value $path -Type ExpandString -ErrorAction SilentlyContinue
    }
}

function Reset-Password([string]$name) {
    Log "Сбрасываю пароль пользователя $name на пустой..."
    $ok = $false
    try {
        Set-LocalUser -Name $name -Password (New-Object System.Security.SecureString) -PasswordNeverExpires $true -UserMayChangePassword $true -ErrorAction Stop
        $ok = $true
    } catch {
        Warn "Set-LocalUser: $($_.Exception.Message). Пробую через net user..."
        & net.exe user "$name" '""' 2>&1 | Out-Null
        $ok = ($LASTEXITCODE -eq 0)
    }
    if ($ok) {
        try {
            $adsi = [ADSI]"WinNT://$env:COMPUTERNAME/$name,user"
            $adsi.PasswordExpired = 0
            $adsi.SetInfo()
        } catch { Warn "Не удалось снять флаг 'сменить пароль при входе': $($_.Exception.Message)" }
        Log 'Пароль сброшен на пустой.'
    } else {
        Fail 'Пароль НЕ сброшен. Вероятно, политика требует минимальную длину пароля. Выполните: net accounts /minpwlen:0 и повторите сброс.'
    }
    return $ok
}

function Reset-Pin {
    $ngc = Join-Path $env:windir 'ServiceProfiles\LocalService\AppData\Local\Microsoft\Ngc'
    if (-not (Test-Path -LiteralPath $ngc)) { Log 'Папка Ngc не найдена, PIN не настроен.'; return }
    Log 'Сбрасываю PIN Windows Hello (папка Ngc)...'
    & icacls.exe "$ngc" /setowner '*S-1-5-32-544' /t /c /q 2>&1 | Out-Null
    & icacls.exe "$ngc" /grant '*S-1-5-32-544:(OI)(CI)F' /t /c /q 2>&1 | Out-Null
    $err = 0
    Get-ChildItem -LiteralPath $ngc -Force | ForEach-Object {
        try { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop } catch { $err++ }
    }
    if ($err) { Warn "PIN: не удалось удалить $err элемент(ов). Повторите после перезагрузки." } else { Log 'PIN удалён для всех учётных записей ПК.' }
}

function Stop-Indexer { try { Stop-Service WSearch -Force -ErrorAction Stop; Log 'Служба Windows Search остановлена.' } catch { } }
function Start-Indexer { try { Start-Service WSearch -ErrorAction Stop } catch { } }

function Format-Size([double]$bytes) {
    if ($bytes -ge 1GB) { return ('{0:N1} ГБ' -f ($bytes / 1GB)) }
    if ($bytes -ge 1MB) { return ('{0:N0} МБ' -f ($bytes / 1MB)) }
    return ('{0:N0} КБ' -f ($bytes / 1KB))
}

# ------------------------------------------------------------------ операции
function Do-Check {
    $p = Get-Paths
    Ensure-GoldenRoot $p.GoldenRoot
    Log '---------- Проверка ----------'
    $u = Get-TargetUser $p.Name -AllowNoProfile
    Log "Пользователь:   $($u.Name)   SID: $($u.Sid)   включён: $($u.Enabled)   тип: $($u.Source)"
    Log ("Папка профиля:  " + $(if ($u.Path) { $u.Path } else { 'профиля нет - будет создан чистый при следующем входе' }))
    $sess = Get-UserSessions $u.Name
    Log ("Сеансы в системе: " + $(if ($sess) { $sess -join ', ' } else { 'нет' }) + "   куст реестра загружен: " + (Test-HiveLoaded $u.Sid))
    $drive = (Get-Item -LiteralPath $p.GoldenRoot).PSDrive
    Log ("Свободно на диске {0}: {1}" -f $drive.Name, (Format-Size $drive.Free))
    if (Test-Path -LiteralPath $p.Manifest) {
        $m = Get-Content -LiteralPath $p.Manifest -Raw -Encoding UTF8 | ConvertFrom-Json
        Log "Эталон:         $($p.Golden)"
        Log "  снят:         $($m.Date)   на ПК: $($m.Computer)   Windows $($m.WindowsBuild)"
        Log "  размер:       $($m.SizeHuman)   файлов: $($m.Files)   соединений: $(@($m.Junctions).Count)"
        if ($m.Sid -ne $u.Sid) { Fail '  SID в эталоне НЕ совпадает с текущим SID пользователя! Восстанавливать нельзя.' }
        elseif (-not $u.Path) { Warn "  SID совпадает, но профиля сейчас нет. Чтобы восстановить из эталона, один раз войдите под $($u.Name) и выйдите (Windows создаст профиль), затем нажмите ВОССТАНОВИТЬ." }
        else { Log '  SID совпадает - восстановление возможно.' }
    } else {
        Warn "Эталон для '$($u.Name)' ещё не снят ($($p.Golden))."
    }
    $pol = & net.exe accounts 2>$null | Where-Object { $_ -match '(length|длина)' } | Select-Object -First 1
    if ($pol) { Log "Политика паролей (минимальная длина): $(($pol -split ':')[-1].Trim())  (нужно 0 или None/Нет, иначе пустой пароль не установится)" }
    Log 'Проверка завершена.'
}

function Do-Snapshot {
    $p = Get-Paths
    Ensure-GoldenRoot $p.GoldenRoot -SetAcl
    Log '========== СНЯТИЕ ЭТАЛОНА =========='
    $u = Get-TargetUser $p.Name
    Log "Пользователь $($u.Name) ($($u.Sid)), профиль $($u.Path)"

    if (Test-Path -LiteralPath $p.Manifest) {
        if (-not (Confirm "Эталон для '$($u.Name)' уже существует:`n$($p.Golden)`n`nПерезаписать его текущим состоянием профиля?")) { Warn 'Отменено.'; return }
    } else {
        if (-not (Confirm "Снять эталон профиля '$($u.Name)' в`n$($p.Golden)?`n`nУбедитесь, что:`n - пароль пользователя ПУСТОЙ (иначе сохранённые пароли после сброса не откроются);`n - сетевые диски и принтеры подключены;`n - Office запускался под этим пользователем;`n - в профиле нет лишнего мусора (Загрузки, кэш).")) { Warn 'Отменено.'; return }
    }

    Ensure-LoggedOff $u
    Stop-Indexer
    try {
        if (-not (Test-Path -LiteralPath $p.Golden)) { New-Item -ItemType Directory -Path $p.Golden -Force | Out-Null }
        # Старый манифест убираем ДО копирования: прерванный снимок не должен считаться целым эталоном.
        if (Test-Path -LiteralPath $p.Manifest) { Remove-Item -LiteralPath $p.Manifest -Force; Log 'Старый manifest.json удалён - эталон будет считаться готовым только после завершения.' }

        Set-Status 'Копирую профиль в эталон...'
        $opts = @('/MIR', '/COPY:DAT', '/DCOPY:DAT', '/B', '/XJ') + @('/XD') + ($Script:ExcludeDirs | ForEach-Object { "`"$_`"" }) + @('/XF') + $Script:ExcludeFiles
        $rc = Invoke-Robocopy $u.Path $p.Profile $opts 'snapshot'
        if ($rc -ge 8) { throw "robocopy вернул код $rc - эталон может быть неполным. Смотрите лог." }

        Set-Status 'Сохраняю права доступа (ACL)...'
        if (Test-Path -LiteralPath $p.AclFile) { Remove-Item -LiteralPath $p.AclFile -Force }
        Invoke-Icacls @("`"$($u.Path)`"", '/save', "`"$($p.AclFile)`"", '/t', '/c', '/q') | Out-Null
        if (-not (Test-Path -LiteralPath $p.AclFile)) { throw 'Не удалось сохранить ACL профиля (icacls /save).' }
        Log "ACL сохранены: $($p.AclFile)"

        Set-Status 'Собираю список соединений (junction)...'
        $junctions = @(Get-Junctions $u.Path)
        Log "Найдено соединений/ссылок внутри профиля: $($junctions.Count)"

        Set-Status 'Подсчитываю размер эталона...'
        $stat  = Get-ChildItem -LiteralPath $p.Profile -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum
        $size  = [double]$stat.Sum
        $files = [int]$stat.Count
        $os = Get-CimInstance Win32_OperatingSystem
        $manifest = [ordered]@{
            Tool         = 'GoldenUser'
            Version      = 1
            User         = $u.Name
            Sid          = $u.Sid
            ProfilePath  = $u.Path
            Computer     = $env:COMPUTERNAME
            Date         = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            WindowsBuild = "$($os.Caption) $($os.Version)"
            Size         = $size
            SizeHuman    = (Format-Size $size)
            Files        = $files
            Junctions    = $junctions
        }
        $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $p.Manifest -Encoding UTF8
        Log "Манифест записан: $($p.Manifest)"
        Log ("ЭТАЛОН СНЯТ: {0}, {1} файлов. Папка: {2}" -f (Format-Size $size), $files, $p.Golden)
        Set-Status 'Эталон снят.'
    } finally {
        Start-Indexer
    }
}

function Do-Restore {
    $p = Get-Paths
    Ensure-GoldenRoot $p.GoldenRoot
    Log '========== ВОССТАНОВЛЕНИЕ ЭТАЛОНА =========='
    $u = Get-TargetUser $p.Name

    if (-not (Test-Path -LiteralPath $p.Manifest)) { throw "Эталон для '$($u.Name)' не найден: $($p.Manifest)" }
    if (-not (Test-Path -LiteralPath $p.Profile))  { throw "Папка эталона не найдена: $($p.Profile)" }
    if (-not (Test-Path -LiteralPath $p.AclFile))  { throw "Файл ACL эталона не найден: $($p.AclFile)" }
    $m = Get-Content -LiteralPath $p.Manifest -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($m.Sid -ne $u.Sid) { throw "SID в эталоне ($($m.Sid)) не совпадает с SID пользователя ($($u.Sid)). Это эталон другого ПК или другой учётной записи." }
    if ($m.Computer -ne $env:COMPUTERNAME) { Warn "Имя ПК в эталоне ($($m.Computer)) отличается от текущего ($env:COMPUTERNAME)." }
    if ($m.ProfilePath -ne $u.Path) { Warn "Путь профиля в эталоне ($($m.ProfilePath)) отличается от текущего ($($u.Path))." }

    $actions = "Будет выполнено для пользователя '$($u.Name)':`n`n" +
        " 1. Принудительный выход пользователя из системы.`n" +
        " 2. Текущий профиль $($u.Path)`n    " + $(if ($chkBackup.Checked) { "перемещается в $($p.BackupRoot)\$($u.Name)_<дата>" } else { 'УДАЛЯЕТСЯ БЕЗ РЕЗЕРВНОЙ КОПИИ' }) + "`n" +
        " 3. Восстанавливается эталон от $($m.Date) ($($m.SizeHuman)).`n" +
        $(if ($chkPwd.Checked)    { " 4. Пароль сбрасывается на пустой.`n" } else { '' }) +
        $(if ($chkPin.Checked)    { " 5. Сбрасывается PIN Windows Hello (у всех учёток).`n" } else { '' }) +
        $(if ($chkReboot.Checked) { " 6. Компьютер перезагружается.`n" } else { '' }) +
        "`nПродолжить?"
    if (-not (Confirm $actions 'ВОССТАНОВЛЕНИЕ ЭТАЛОНА')) { Warn 'Отменено.'; return }
    if ($chkBackup.Checked -and -not $p.BackupRoot) { throw 'Включено сохранение старого профиля, но папка резервных копий не указана.' }

    Ensure-LoggedOff $u
    Stop-Indexer
    $oldPath = $null
    $moved = $false      # старый профиль переименован
    $committed = $false  # новый профиль скопирован целиком - откат больше не нужен
    try {
        # --- 1. убираем текущий профиль с дороги (переименование = мгновенно, на том же диске)
        $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        if ($chkBackup.Checked) {
            if (-not (Test-Path -LiteralPath $p.BackupRoot)) { New-Item -ItemType Directory -Path $p.BackupRoot -Force | Out-Null }
            & icacls.exe "$($p.BackupRoot)" /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' /q | Out-Null
            $oldPath = Join-Path $p.BackupRoot "$($u.Name)_$stamp"
        } else {
            $oldPath = "$($u.Path).old_$stamp"
        }
        if (Test-Path -LiteralPath $oldPath) { $oldPath = "${oldPath}_$(Get-Random -Maximum 9999)" }
        $sameDrive = ([IO.Path]::GetPathRoot($oldPath) -ieq [IO.Path]::GetPathRoot($u.Path))
        if (-not $sameDrive) { throw "Папка резервных копий должна быть на том же диске, что и профиль ($([IO.Path]::GetPathRoot($u.Path)))." }

        Set-Status 'Переношу текущий профиль...'
        for ($i = 1; $i -le 5 -and -not $moved; $i++) {
            try { Move-Item -LiteralPath $u.Path -Destination $oldPath -Force -ErrorAction Stop; $moved = $true }
            catch { Warn "Попытка $i/5: папка профиля занята ($($_.Exception.Message)). Жду 3 с..."; Start-Sleep -Seconds 3; DoEvents }
        }
        if (-not $moved) { throw "Не удалось переместить $($u.Path). Закройте проводник/программы, открывающие эту папку, и повторите." }
        Log "Старый профиль перемещён: $oldPath"

        # --- 2. копируем эталон на место
        Set-Status 'Копирую эталон в профиль...'
        New-Item -ItemType Directory -Path $u.Path -Force | Out-Null
        $rc = Invoke-Robocopy $p.Profile $u.Path @('/E', '/COPY:DAT', '/DCOPY:DAT', '/B', '/XJ') 'restore'
        if ($rc -ge 8) { throw "robocopy вернул код $rc - эталон скопирован не полностью. Старый профиль возвращён на место, ничего не удалено." }
        $committed = $true
        # Старый профиль больше не нужен как источник отката: убираем из него соединения,
        # которые абсолютными путями указывают в НОВЫЙ профиль.
        Remove-JunctionsIn $oldPath

        # Папки, исключённые из эталона, но обязательные для работы (TEMP/TMP указывают сюда)
        foreach ($rel in @('AppData\Local\Temp', 'AppData\Local\Microsoft\Windows\INetCache', 'AppData\Local\Microsoft\Windows\WER', 'AppData\Local\Microsoft\WindowsApps')) {
            New-Item -ItemType Directory -Path (Join-Path $u.Path $rel) -Force -ErrorAction SilentlyContinue | Out-Null
        }

        # --- 3. права доступа: восстанавливаем сохранённые ACL, владелец - пользователь
        Set-Status 'Восстанавливаю права доступа...'
        $usersDir = Split-Path $u.Path -Parent
        Invoke-Icacls @("`"$usersDir`"", '/restore', "`"$($p.AclFile)`"", '/c', '/q') | Out-Null
        Invoke-Icacls @("`"$($u.Path)`"", '/setowner', "*$($u.Sid)", '/t', '/c', '/q') | Out-Null
        # на корне профиля - страховка стандартным набором прав
        Invoke-Icacls @("`"$($u.Path)`"", '/inheritance:r', '/grant:r', '*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F', "*$($u.Sid):(OI)(CI)F", '/q') | Out-Null
        Log 'ACL восстановлены.'

        # --- 4. соединения внутри профиля
        Restore-Junctions $u.Path $m.Junctions

        # --- 5. реестр ProfileList
        Repair-ProfileList $u.Sid $u.Path
        Log 'ProfileList проверен.'

        # --- 6. резервная копия: закрываем доступ пользователю (или удаляем)
        if ($chkBackup.Checked) {
            Set-Status 'Закрываю доступ к резервной копии...'
            Invoke-Icacls @("`"$oldPath`"", '/remove:g', "*$($u.Sid)", '/t', '/c', '/q') | Out-Null
            Invoke-Icacls @("`"$oldPath`"", '/inheritance:r', '/grant:r', '*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F', '/q') | Out-Null
            Log "Резервная копия старого профиля: $oldPath (доступ только администраторам)"
        } else {
            Set-Status 'Удаляю старый профиль...'
            & cmd.exe /c "rmdir /s /q `"$oldPath`"" 2>&1 | Out-Null
            if (Test-Path -LiteralPath $oldPath) { Warn "Старый профиль удалён не полностью: $oldPath - удалите вручную после перезагрузки (rmdir /s /q)." } else { Log 'Старый профиль удалён.' }
        }

        # --- 7. пароль и PIN
        $pwdOk = $true
        if ($chkPwd.Checked) { $pwdOk = [bool](Reset-Password $u.Name) }
        if ($chkPin.Checked) { Reset-Pin }

        Log "ВОССТАНОВЛЕНИЕ ЗАВЕРШЕНО. Эталон от $($m.Date)."
        Set-Status 'Готово.'
    } catch {
        if ($moved -and -not $committed) {
            # Откат: убираем недокопированный новый профиль и возвращаем старый на место
            Warn 'Ошибка на этапе копирования - откатываю: возвращаю старый профиль на место...'
            try {
                if (Test-Path -LiteralPath $u.Path) { & cmd.exe /c "rmdir /s /q `"$($u.Path)`"" 2>&1 | Out-Null }
                Move-Item -LiteralPath $oldPath -Destination $u.Path -Force -ErrorAction Stop
                Log "Старый профиль возвращён: $($u.Path)"
            } catch {
                Fail "ОТКАТ НЕ УДАЛСЯ: старый профиль лежит в $oldPath, верните его вручную в $($u.Path). $($_.Exception.Message)"
            }
        }
        throw
    } finally {
        Start-Indexer
    }

    if (-not $pwdOk) {
        [System.Windows.Forms.MessageBox]::Show($form,
            "Профиль восстановлен, но пароль пользователя '$($u.Name)' НЕ сброшен на пустой.`n`nБез этого пользователь не войдёт, а сохранённые пароли (сетевые диски, Credential Manager) не откроются.`n`nВыполните в консоли администратора:`n  net accounts /minpwlen:0`n  net user `"$($u.Name)`" `"`"`n`nПерезагрузка отменена - сделайте её вручную после сброса пароля.",
            'GoldenUser - пароль не сброшен', 'OK', 'Warning') | Out-Null
        Warn 'Перезагрузка отменена: сначала сбросьте пароль.'
        return
    }

    if ($chkReboot.Checked) {
        Log 'Перезагрузка через 15 секунд...'
        & shutdown.exe /r /t 15 /c "GoldenUser: профиль восстановлен, перезагрузка" | Out-Null
    } else {
        Warn 'Перезагрузите компьютер перед тем, как входить под пользователем.'
    }
}

function Report-OutsideProfile($u) {
    # Следы предыдущего владельца, которые лежат ВНЕ профиля и удалением профиля не чистятся.
    # Только сообщаем - решение за администратором.
    $found = 0
    try {
        $isAdmin = Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop | Where-Object { $_.SID.Value -eq $u.Sid }
        if ($isAdmin) { Warn "Пользователь $($u.Name) состоит в группе Администраторы. Убрать: Remove-LocalGroupMember -SID S-1-5-32-544 -Member `"$($u.Name)`""; $found++ }
    } catch { Warn "Не удалось проверить группу Администраторы: $($_.Exception.Message)" }
    if ($u.Source -eq 'MicrosoftAccount') {
        Warn "Учётная запись $($u.Name) привязана к учётной записи Microsoft прежнего владельца. Очистка профиля её НЕ отвязывает: вход по-прежнему идёт по паролю Microsoft. Надёжнее удалить учётку и создать локального $($u.Name) заново (эталон после этого снимать заново)."
        $found++
    }
    try {
        $tasks = Get-ScheduledTask -ErrorAction Stop | Where-Object {
            $id = [string]$_.Principal.UserId
            $id -and (($id -split '\\')[-1] -ieq $u.Name -or $id -eq $u.Sid)
        }
        foreach ($t in @($tasks)) { Warn "Задача планировщика от имени $($u.Name): $($t.TaskPath)$($t.TaskName)"; $found++ }
    } catch { Warn "Не удалось проверить задачи планировщика: $($_.Exception.Message)" }
    if (-not $found) { Log 'Следов пользователя вне профиля (права администратора, учётка Microsoft, задачи планировщика) не найдено.' }
}

function Get-ProfileListImagePath([string]$sid, [string]$suffix = '') {
    $k = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid$suffix"
    try {
        $v = (Get-ItemProperty -LiteralPath $k -Name ProfileImagePath -ErrorAction Stop).ProfileImagePath
        if ($v) { return [Environment]::ExpandEnvironmentVariables([string]$v).TrimEnd('\') }
    } catch { }
    return $null
}

function Get-CleanTargets($u) {
    # Все папки, которые могут быть профилем этого пользователя:
    #  - путь из Win32_UserProfile;
    #  - ProfileImagePath из ProfileList\<SID> и из ProfileList\<SID>.bak
    #    (при временном профиле настоящая папка указана только в .bak, а в <SID> - C:\Users\TEMP);
    #  - стандартный C:\Users\<имя> (осиротевшая папка без записи в реестре).
    $usersRoot = (Split-Path $env:PUBLIC -Parent).TrimEnd('\')
    $protected = @($usersRoot, $env:PUBLIC, (Join-Path $usersRoot 'Default'), (Join-Path $usersRoot 'Default User'), (Join-Path $usersRoot 'All Users'), $env:USERPROFILE) |
        Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') }
    $candidates = @($u.Path, (Get-ProfileListImagePath $u.Sid), (Get-ProfileListImagePath $u.Sid '.bak'), (Join-Path $usersRoot $u.Name))
    $result = New-Object System.Collections.Generic.List[string]
    foreach ($c in $candidates) {
        if (-not $c) { continue }
        $c = $c.TrimEnd('\')
        if (-not (Test-Path -LiteralPath $c)) { continue }
        # Защита от странных значений в реестре: только подпапки C:\Users, кроме служебных и текущего админа
        if (-not $c.StartsWith("$usersRoot\", [StringComparison]::OrdinalIgnoreCase)) { Warn "Пропускаю $c - не внутри $usersRoot."; continue }
        if ($protected | Where-Object { $_ -ieq $c }) { Warn "Пропускаю служебную папку $c."; continue }
        if (-not ($result | Where-Object { $_ -ieq $c })) { $result.Add($c) }
    }
    return @($result)
}

function Remove-ProfileListKeys([string]$sid) {
    $pl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
    foreach ($k in @("$pl\$sid", "$pl\$sid.bak")) {
        if (Test-Path -LiteralPath $k) { Remove-Item -LiteralPath $k -Recurse -Force -ErrorAction SilentlyContinue; Warn "Удалён оставшийся ключ $k" }
    }
    $pg = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileGuid'
    if (Test-Path -LiteralPath $pg) {
        Get-ChildItem -LiteralPath $pg -ErrorAction SilentlyContinue | ForEach-Object {
            if ((Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue).SidString -eq $sid) {
                Remove-Item -LiteralPath $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Do-Clean {
    $p = Get-Paths
    Ensure-GoldenRoot $p.GoldenRoot
    Log '========== ОЧИСТКА ПРОФИЛЯ (как новый пользователь) =========='
    $u = Get-TargetUser $p.Name -AllowNoProfile
    if ($chkBackup.Checked -and -not $p.BackupRoot) { throw 'Включено сохранение старого профиля, но папка резервных копий не указана.' }

    $targets = @(Get-CleanTargets $u)
    $isMsa = ($u.Source -eq 'MicrosoftAccount')

    $actions = ''
    if ($isMsa) {
        $actions += "ВНИМАНИЕ: '$($u.Name)' привязан к учётной записи Microsoft прежнего владельца.`n" +
            "Очистка профиля эту привязку НЕ снимает, а пароль такой учётки нельзя сбросить на пустой:`n" +
            "новый сотрудник не сможет войти. Надёжнее удалить учётку и создать локального '$($u.Name)' заново.`n`n"
    }
    $actions += "Будет выполнено для пользователя '$($u.Name)':`n`n" +
        " 1. Принудительный выход пользователя из системы.`n"
    if ($targets.Count) {
        $actions += " 2. " + $(if ($chkBackup.Checked) { "Копируются в $($p.BackupRoot), затем " } else { '' }) +
            "УДАЛЯЮТСЯ ПОЛНОСТЬЮ (рабочий стол, документы, загрузки, настройки программ,`n    сохранённые пароли, сетевые диски, принтеры, обои):`n" +
            (($targets | ForEach-Object { "      $_" }) -join "`n") + "`n"
    } else {
        $actions += " 2. Папок профиля на диске нет - удалять нечего.`n"
    }
    $actions += " 3. При следующем входе Windows создаст новый чистый профиль.`n" +
        $(if ($chkPwd.Checked)    { " 4. Пароль сбрасывается на пустой.`n" } else { '' }) +
        $(if ($chkPin.Checked)    { " 5. Сбрасывается PIN Windows Hello (у всех учёток).`n" } else { '' }) +
        $(if ($chkReboot.Checked) { " 6. Компьютер перезагружается.`n" } else { '' }) +
        "`nУчётная запись, её имя и SID сохраняются. Эталон в $($p.Golden) (если есть) не трогается.`n`nПродолжить?"
    if (-not (Confirm $actions 'ОЧИСТКА ПРОФИЛЯ')) { Warn 'Отменено.'; return }

    Ensure-LoggedOff $u
    Stop-Indexer
    $pwdOk = $true
    try {
        $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'

        # --- 1. страховочная копия каждой найденной папки
        #     (копируем, а не переносим: удалять профиль должна сама Windows)
        if ($chkBackup.Checked -and $targets.Count) {
            if (-not (Test-Path -LiteralPath $p.BackupRoot)) { New-Item -ItemType Directory -Path $p.BackupRoot -Force | Out-Null }
            & icacls.exe "$($p.BackupRoot)" /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' /q | Out-Null
            foreach ($t in $targets) {
                $bak = Join-Path $p.BackupRoot ("{0}_clean_{1}_{2}" -f $u.Name, $stamp, (Split-Path $t -Leaf))
                Set-Status "Копирую $t в резервную копию..."
                # Исключаем только конкретные системные папки по полному пути: исключение по имени
                # (Temp, Cache) задело бы и пользовательские Desktop\Temp, Documents\Cache и т.п.
                # WindowsApps - псевдонимы приложений, robocopy их не копирует (ERROR 1920).
                $xd = @('AppData\Local\Microsoft\WindowsApps', 'AppData\Local\Temp', 'AppData\Local\Microsoft\Windows\INetCache') |
                    ForEach-Object { "`"$(Join-Path $t $_)`"" }
                $opts = @('/E', '/COPY:DAT', '/DCOPY:DAT', '/B', '/XJ', '/XD') + $xd
                $rc = Invoke-Robocopy $t $bak $opts 'clean_backup'
                if ($rc -ge 8) {
                    if (-not (Confirm "Резервная копия $t сделана не полностью (robocopy код $rc, подробности в журнале).`n`nВсё равно удалить профиль?")) { Warn 'Отменено: профиль не тронут.'; return }
                }
                Invoke-Icacls @("`"$bak`"", '/remove:g', "*$($u.Sid)", '/t', '/c', '/q') | Out-Null
                Log "Резервная копия: $t -> $bak (доступ только администраторам)"
            }
        }

        # --- 2. удаление профиля средствами Windows (папка + куст реестра + ProfileList)
        if ($u.Path) {
            Set-Status 'Удаляю профиль...'
            try {
                Get-CimInstance Win32_UserProfile -Filter "SID='$($u.Sid)'" -ErrorAction Stop | Remove-CimInstance -ErrorAction Stop
                Log 'Профиль удалён средствами Windows.'
            } catch {
                Warn "Windows не удалила профиль целиком: $($_.Exception.Message). Дочищаю вручную..."
            }
        }

        # --- 3. дочистка: все найденные папки, включая осиротевшие и путь из ProfileList\<SID>.bak
        $blocked = @()
        foreach ($t in $targets) {
            if (-not (Test-Path -LiteralPath $t)) { continue }
            Remove-JunctionsIn $t
            & cmd.exe /c "rmdir /s /q `"$t`"" 2>&1 | Out-Null
            if (-not (Test-Path -LiteralPath $t)) { Log "Удалено: $t"; continue }
            # Что-то занято - убираем папку с дороги, чтобы новый профиль создался именно в C:\Users\<user>,
            # а не в C:\Users\<user>.<ИМЯПК>.
            $del = "$t.del_$stamp"
            try { Rename-Item -LiteralPath $t -NewName (Split-Path $del -Leaf) -ErrorAction Stop; Warn "Часть файлов занята - $t переименована в $del. Удалите её после перезагрузки: rmdir /s /q `"$del`"" }
            catch { $blocked += $t }
        }
        if ($blocked) {
            # Ключи ProfileList НЕ трогаем: пока папка на месте, при повторном запуске она найдётся по реестру.
            throw "Не удалось удалить или переименовать: $($blocked -join '; '). Записи ProfileList оставлены как есть. Перезагрузите ПК, войдите только под администратором и повторите очистку."
        }
        Remove-ProfileListKeys $u.Sid

        # --- 4. проверка
        $pl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
        $default = Join-Path (Split-Path $env:PUBLIC -Parent) $u.Name
        $left = @()
        if (Test-Path -LiteralPath $default)              { $left += $default }
        if (Test-Path -LiteralPath "$pl\$($u.Sid)")       { $left += "ProfileList\$($u.Sid)" }
        if (Test-Path -LiteralPath "$pl\$($u.Sid).bak")   { $left += "ProfileList\$($u.Sid).bak" }
        if ($left) { throw "Профиль удалён не полностью, осталось: $($left -join '; '). Перезагрузите ПК и повторите очистку - иначе при входе будет временный профиль." }
        Log 'Проверка: папки профиля и записей ProfileList нет - при входе будет создан новый профиль.'

        # --- 5. следы вне профиля, пароль, PIN
        Report-OutsideProfile $u
        if ($chkPwd.Checked) { $pwdOk = [bool](Reset-Password $u.Name) }
        if ($chkPin.Checked) { Reset-Pin }

        Log "ОЧИСТКА ЗАВЕРШЕНА. При следующем входе $($u.Name) получит чистый профиль."
        if (Test-Path -LiteralPath $p.Manifest) { Warn "Для $($u.Name) есть старый эталон ($($p.Golden)). После настройки нового профиля снимите эталон заново." }
        Set-Status 'Готово.'
    } finally {
        Start-Indexer
    }

    if (-not $pwdOk) {
        $how = if ($isMsa) {
            "Учётная запись привязана к Microsoft - её пароль на пустой не сбрасывается.`nУдалите учётку и создайте локального '$($u.Name)' заново:`n  Remove-LocalUser -Name `"$($u.Name)`"`n  New-LocalUser -Name `"$($u.Name)`" -NoPassword`n  Add-LocalGroupMember -SID S-1-5-32-545 -Member `"$($u.Name)`""
        } else {
            "Выполните в консоли администратора:`n  net accounts /minpwlen:0`n  net user `"$($u.Name)`" `"`""
        }
        [System.Windows.Forms.MessageBox]::Show($form,
            "Профиль очищен, но пароль пользователя '$($u.Name)' НЕ сброшен на пустой.`n`n$how`n`nПерезагрузка отменена - сделайте её вручную после этого.",
            'GoldenUser - пароль не сброшен', 'OK', 'Warning') | Out-Null
        Warn 'Перезагрузка отменена: сначала разберитесь с паролем.'
        return
    }
    if ($chkReboot.Checked) {
        Log 'Перезагрузка через 15 секунд...'
        & shutdown.exe /r /t 15 /c "GoldenUser: профиль очищен, перезагрузка" | Out-Null
    } else {
        Warn 'Перезагрузите компьютер перед тем, как входить под пользователем.'
    }
}

# ------------------------------------------------------------------ обработчики
function Run-Safely([scriptblock]$Action) {
    Set-Busy $true
    try { & $Action }
    catch {
        Fail $_.Exception.Message
        Set-Status 'Ошибка. Смотрите журнал.'
        [System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'GoldenUser - ошибка', 'OK', 'Error') | Out-Null
    }
    finally { Set-Busy $false }
}

$btnCheck.Add_Click({    Run-Safely { Do-Check } })
$btnSnapshot.Add_Click({ Run-Safely { Do-Snapshot } })
$btnRestore.Add_Click({  Run-Safely { Do-Restore } })
$btnClean.Add_Click({    Run-Safely { Do-Clean } })
$btnOpen.Add_Click({
    try { $p = Get-Paths; Ensure-GoldenRoot $p.GoldenRoot; Start-Process explorer.exe "`"$($p.GoldenRoot)`"" } catch { Fail $_.Exception.Message }
})

$form.Add_Shown({
    try {
        $p = Get-Paths; Ensure-GoldenRoot $p.GoldenRoot
        Log "GoldenUser запущен от $env:USERDOMAIN\$env:USERNAME на $env:COMPUTERNAME. Журнал: $($Script:LogFile)"
    } catch { Fail $_.Exception.Message }
})

[void]$form.ShowDialog()
