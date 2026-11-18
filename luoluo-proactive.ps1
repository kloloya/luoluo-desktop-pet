# 洛洛・主动说话 + 气泡对话
# 主动: 每隔几分钟按设定卡调 DeepSeek 说一句,在她旁边弹气泡
# 对话: 点一下气泡展开输入框,回她一句,她接着答(记忆连续)
# 用法:
#   .\luoluo-proactive.ps1 -Install
#   .\luoluo-proactive.ps1 -Uninstall
#   .\luoluo-proactive.ps1 -Stop
#   .\luoluo-proactive.ps1 -Once

param(
    [switch]$Once,
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Stop,
    [switch]$StopProactive,
    [switch]$Usage,
    [switch]$DryRun,
    [switch]$Called,
    [int]$MinMinutes = 2,
    [int]$MaxMinutes = 3,
    [int]$IdleSeconds = 10,
    [string]$QuietStart = '02:00',
    [string]$QuietEnd = '09:30',
    [int]$IntervalMinutes = 3,
    [int]$IntervalSec = 0,
    [switch]$IgnoreIdle,
    [switch]$NoGame,
    [switch]$LogOnly,
    [switch]$Hotkey,
    [switch]$Panel,
    [switch]$OpenChat,
    [string]$Say,
    [string]$SayAs,
    [int]$History,
    [string]$AddAlarm,
    [string]$AlarmText,
    [switch]$Daily,
    [int]$RemoveAlarm,
    [switch]$Alarms,
    [switch]$Memory,
    [switch]$Notes,
    [int]$ForgetNote,
    [string]$AddNote,
    [switch]$Summarize,
    [int]$Forget,
    [int]$ForgetLast,
    [string]$BubbleJson,
    [switch]$YejinChat,
    [string]$PersonaFile,
    [string]$DataDirX
)

$ErrorActionPreference = 'Stop'

$DataDir = Join-Path $PSScriptRoot 'data'
$MemPath = Join-Path $DataDir 'memory.json'
$LogPath = Join-Path $DataDir 'log.txt'
$PidPath = Join-Path $DataDir 'scheduler.pid'
$PauseFlag = Join-Path $DataDir 'paused.flag'
$BubblePath = Join-Path $DataDir 'bubble.json'
$OpenMark = Join-Path $DataDir 'bubble.open'
# --- 配置：优先读同目录 config.json，缺省用 MateEngine 默认位置 ---
$cfgUser = $null
try { $cfgFile = Join-Path $PSScriptRoot 'config.json'; if (Test-Path $cfgFile) { $cfgUser = Get-Content $cfgFile -Raw -Encoding UTF8 | ConvertFrom-Json } } catch { }
$mateDir = if ($cfgUser -and $cfgUser.mateEngineData) { [string]$cfgUser.mateEngineData } else { Join-Path $env:USERPROFILE 'AppData\LocalLow\Shinymoon\MateEngineX' }
$PersonaPath = Join-Path $mateDir 'ZomeAI_prompt.txt'
$ApiConfigPath = Join-Path $mateDir 'LLMProxySettings.json'
if ($DataDirX) {
    $DataDir = $DataDirX
    $MemPath = Join-Path $DataDir 'memory.json'
    $LogPath = Join-Path $DataDir 'log.txt'
    $PidPath = Join-Path $DataDir 'scheduler.pid'
    $PauseFlag = Join-Path $DataDir 'paused.flag'
    $BubblePath = Join-Path $DataDir 'bubble.json'
    $OpenMark = Join-Path $DataDir 'bubble.open'
}
if ($PersonaFile) { $PersonaPath = $PersonaFile }

New-Item -ItemType Directory -Force $DataDir | Out-Null

function Rotate-Log {
    try {
        $lp = Join-Path $DataDir 'log.txt'
        if ((Test-Path $lp) -and ((Get-Item $lp).Length -gt 5MB)) { Move-Item $lp ($lp + '.old') -Force }
    } catch { }
}
function Write-Log([string]$msg) {
    $line = ('[{0}] {1}' -f (Get-Date -Format 'MM-dd HH:mm:ss'), $msg)
    try {
        if ((Test-Path $LogPath) -and (Get-Item $LogPath).Length -gt 1MB) {
            $old = [IO.Path]::ChangeExtension($LogPath, '1.txt')
            Remove-Item $old -Force -ErrorAction SilentlyContinue
            Move-Item $LogPath $old -Force
        }
    } catch { }
    Add-Content -Path $LogPath -Value $line -Encoding UTF8
}
function Get-ApiConfig {
    if (-not (Test-Path $ApiConfigPath)) { throw "找不到 API 配置: $ApiConfigPath" }
    $j = Get-Content $ApiConfigPath -Raw | ConvertFrom-Json
    $c = $j.apiConfigs[$j.activeConfigIndex]
    @{ key = $c.apiKey; endpoint = $c.apiEndpoint; model = $c.model }
}

function Get-Persona {
    if (-not (Test-Path $PersonaPath)) { throw "找不到设定卡: $PersonaPath" }
    [IO.File]::ReadAllText($PersonaPath, [Text.Encoding]::UTF8)
}

function Get-Memory {
    if (Test-Path $MemPath) {
        try { Get-Content $MemPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $null }
    }
}

function Save-Memory($mem) {
    try {
        $old = $null
        if (Test-Path $MemPath) { try { $old = Get-Content $MemPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { } }
        if ($null -eq $mem.notes -and $old -and $old.notes) { $mem | Add-Member -NotePropertyName notes -NotePropertyValue @($old.notes) -Force }
        if ($null -eq $mem.recent -and $old -and $old.recent) { $mem | Add-Member -NotePropertyName recent -NotePropertyValue @($old.recent) -Force }
    } catch { }
    $mem | ConvertTo-Json -Depth 6 | Set-Content -Path $MemPath -Encoding UTF8
}

function Update-Notes {
    param($mem, [switch]$Force)
    try {
        if (-not $Force -and $mem -and $mem.lastSumAt) {
            if (((Get-Date) - [datetime]$mem.lastSumAt).TotalMinutes -lt 20) { return }
        }
    } catch { }
    try {
        if (-not $mem -or -not $mem.chat -or $mem.chat.Count -lt 12) { return }
        $recentChat = @($mem.chat | Select-Object -Last 20)
        $chatText = ($recentChat | ForEach-Object { ($(if ($_.who -eq 'me') { '麻麻' } else { '洛洛' })) + ': ' + $_.text }) -join "`n"
        $old = @()
        if ($mem.notes) { $old = @($mem.notes) }
        $oldText = if ($old.Count) { ($old -join "`n") } else { '（还没有）' }
        $sys = "你在帮一个角色维护长期记忆。`n已有记忆：`n$oldText`n`n最近的对话：`n$chatText`n`n任务：从对话里提取关于「麻麻」的长期事实（身份、身体、喜好、习惯、重要事件、关系）。`n- 最多 8 条，每条不超过 15 字`n- 合并已有记忆：重复的合并，过时的删掉，新的事实加上`n- 只输出记忆条目，一行一条，不要编号、不要解释、不要加冒号"
        $out = Invoke-LLM -system $sys -user '更新记忆。' -maxTokens 1500 -temp 0.3
        $lines = @($out -split "`n" | ForEach-Object { $_.Trim().TrimStart('-', '·', '•', ' ').Trim() } | Where-Object { $_ -and $_.Length -ge 4 -and $_.Length -le 30 })
        if ($lines.Count -gt 0) {
            $notes = @($lines | Select-Object -Unique | Select-Object -First 12)
            Save-Memory ([pscustomobject]@{
                lastSpoke = $mem.lastSpoke; recent = @($mem.recent); chat = @($mem.chat)
                lastUserAt = $mem.lastUserAt; ignored = $mem.ignored; mood = $mem.mood
                moodValue = $mem.moodValue; notes = $notes; lastSumAt = (Get-Date).ToString('o')
            })
            Write-Log ("记忆更新: " + ($notes -join ' / '))
            # 她反复提到的词：至少 3 条不同的消息里出现
            try {
                $msgs = @($mem.chat | Where-Object { $_ -and $_.who -eq 'me' -and $_.text } | ForEach-Object { [string]$_.text })
                $df = @{}
                foreach ($t in $msgs) {
                    $clean = ($t -replace '[^\u4e00-\u9fa5]', '')
                    $seen = @{}
                    for ($q = 0; $q -lt $clean.Length - 1; $q++) {
                        $g = $clean.Substring($q, 2)
                        if (-not $seen.ContainsKey($g)) { $seen[$g] = 1; if ($df.ContainsKey($g)) { $df[$g]++ } else { $df[$g] = 1 } }
                    }
                }
                $bad = '的是了我你他她它们这那个不没有在就都也还和与很太会能要可以吗呢吧啊呀哦嗯给你我们你们什么一个这个知道就是不是现在感觉觉得好像真的样时候因为所以但是然后可能应该自己大家这样怎么为什么哪呢吧啊'
                $rep = @($df.GetEnumerator() | Where-Object { $_.Value -ge 2 -and $bad -notlike ("*" + $_.Key + "*") } | Sort-Object Value -Descending | Select-Object -First 5 | ForEach-Object { $_.Key })
                $rf = Join-Path $DataDir 'repeated.json'
                if ($rep.Count -gt 0) { Set-Content -Path $rf -Value (ConvertTo-Json -InputObject @($rep) -Compress) -Encoding UTF8 }
                else { Remove-Item $rf -Force -ErrorAction SilentlyContinue }
            } catch { }
            # 学她的口癖：找出她反复用的 2~3 字词组
            try {
                $mine = @($mem.chat | Where-Object { $_ -and $_.who -eq 'me' -and $_.text } | ForEach-Object { [string]$_.text })
                $grams = @{}
                foreach ($t in $mine) {
                    $clean = ($t -replace '[^\u4e00-\u9fa5]', '')
                    for ($q = 0; $q -lt $clean.Length - 1; $q++) {
                        $g2 = $clean.Substring($q, 2)
                        if ($grams.ContainsKey($g2)) { $grams[$g2]++ } else { $grams[$g2] = 1 }
                    }
                }
                $stop = '的是了我你他她它们这那个不没有在就都也还和与很太会能要可以吗呢吧啊呀哦嗯给你我们你们什么一个这个那个知道就是不是现在感觉觉得好像真的一样时候因为所以但是然后可能应该自己大家这样那样怎么为什么'
                $top = @($grams.GetEnumerator() | Where-Object { $_.Value -ge 4 -and $stop -notlike ("*" + $_.Key + "*") -and $_.Key -notmatch '^[的了是我你在有不都就也还和]' } | Sort-Object Value -Descending | Select-Object -First 5 | ForEach-Object { $_.Key })
                    if ($top.Count -gt 0) {
                        Set-Content -Path (Join-Path $DataDir 'phrases.json') -Value (ConvertTo-Json -InputObject @($top) -Compress) -Encoding UTF8
                    } else {
                        Remove-Item (Join-Path $DataDir 'phrases.json') -Force -ErrorAction SilentlyContinue
                    }
            } catch { }
        }
    } catch { Write-Log ("记忆更新失败: " + $_.Exception.Message) }
}
function CN2Int([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return -1 }
    $map = @{ '零'=0;'一'=1;'二'=2;'两'=2;'三'=3;'四'=4;'五'=5;'六'=6;'七'=7;'八'=8;'九'=9 }
    if ($s -match '^\d+$') { return [int]$s }
    if ($s -eq '十') { return 10 }
    if ($s -match '^十(.+)$') { $r = $map[$matches[1]]; if ($null -eq $r) { return -1 }; return 10 + $r }
    if ($s -match '^(.+)十$') { $l = $map[$matches[1]]; if ($null -eq $l) { return -1 }; return $l * 10 }
    if ($s -match '^(.+)十(.+)$') { $l = $map[$matches[1]]; $r = $map[$matches[2]]; if ($null -eq $l -or $null -eq $r) { return -1 }; return $l * 10 + $r }
    if ($s.Length -eq 1) { $v = $map[$s]; if ($null -ne $v) { return $v } }
    return -1
}


function Parse-AlarmText([string]$text) {
    $ampm = ''; $h = -1; $m = 0
    if ($text -match '(凌晨|早上|上午|中午|下午|晚上|傍晚)?\s*([零一二两三四五六七八九十\d]{1,3})\s*点\s*(半|([零一二两三四五六七八九十\d]{1,3})\s*分?)?') {
        $ampm = $matches[1]
        $h = CN2Int $matches[2]
        if ($matches[3] -eq '半') { $m = 30 }
        elseif ($matches[4]) { $m = CN2Int $matches[4] }
    }
    elseif ($text -match '(凌晨|早上|上午|中午|下午|晚上|傍晚)?\s*(\d{1,2})\s*[:：]\s*(\d{1,2})?') {
        $ampm = $matches[1]; $h = [int]$matches[2]; if ($matches[3]) { $m = [int]$matches[3] }
    }
    else { return $null }

    if ($ampm -in @('下午','晚上','傍晚') -and $h -lt 12) { $h += 12 }
    if ($ampm -eq '中午' -and $h -lt 11) { $h += 12 }
    if ($ampm -eq '凌晨' -and $h -eq 12) { $h = 0 }
    if ($h -lt 0 -or $h -gt 23 -or $m -lt 0 -or $m -gt 59) { return $null }
    $now = Get-Date
    $due = $now.Date.AddHours($h).AddMinutes($m)
    if ($due -le $now.AddMinutes(1)) { $due = $due.AddDays(1) }
    return [pscustomobject]@{ time = $due.ToString('HH:mm'); date = $due.ToString('yyyy-MM-dd') }
}
function Remove-Period([string]$s) {
    $x = $s -replace '。', '，'
    $x = $x -replace '，{2,}', '，'
    $x = $x.Trim('，', ' ', "`t", "`n")
    return $x
}
function Add-Usage([long]$inMiss, [long]$inHit, [long]$outTokens) {
    # 估算价：输入未命中 0.5 元/百万, 命中 0.1 元/百万, 输出 8 元/百万
    $cost = ($inMiss * 0.5 + $inHit * 0.1 + $outTokens * 8) / 1000000.0
    $path = Join-Path $DataDir 'usage.json'
    $histPath = Join-Path $DataDir 'usage-history.json'
    $today = (Get-Date).ToString('yyyy-MM-dd')

    $prevMiss = [long]0; $prevHit = [long]0; $prevOut = [long]0; $prevCalls = [int]0; $prevCost = [double]0
    if (Test-Path $path) {
        try {
            $u = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($u.day -and $u.day -ne $today) {
                $hist = @()
                if (Test-Path $histPath) {
                    try {
                        $rawHist = Get-Content $histPath -Raw -Encoding UTF8 | ConvertFrom-Json
                        foreach ($h in @($rawHist)) { if ($h -and $h.day) { $hist += $h } }
                    } catch { }
                }
                $hist += [pscustomobject]@{ day = [string]$u.day; calls = [int]$u.calls; cost = [math]::Round([double]$u.cost, 6) }
                Set-Content -Path $histPath -Value (ConvertTo-Json -InputObject @($hist) -Depth 4) -Encoding UTF8
            }
            elseif ($u.day -eq $today) {
                $prevMiss = [long]$u.inMiss; $prevHit = [long]$u.inHit; $prevOut = [long]$u.out
                $prevCalls = [int]$u.calls; $prevCost = [double]$u.cost
            }
        } catch { }
    }

    $obj = [pscustomobject]@{
        day     = $today
        inMiss  = $prevMiss + $inMiss
        inHit   = $prevHit + $inHit
        out     = $prevOut + $outTokens
        calls   = $prevCalls + 1
        cost    = $prevCost + $cost
        updated = (Get-Date).ToString('o')
    }
    $obj | ConvertTo-Json -Compress | Set-Content -Path $path -Encoding UTF8
}
function Invoke-LLM([string]$system, [string]$user, [int]$maxTokens = 200, [double]$temp = 1.0) {
    $cfg = Get-ApiConfig
    $body = @{
        model       = $cfg.model
        messages    = @(
            @{ role = 'system'; content = $system },
            @{ role = 'user'; content = $user }
        )
        max_tokens  = $maxTokens
        temperature = $temp
        stream      = $false
    } | ConvertTo-Json -Depth 6 -Compress

    $wc = New-Object System.Net.WebClient
    $wc.Headers.Add('Authorization', "Bearer $($cfg.key)")
    $wc.Headers.Add('Content-Type', 'application/json')
    try {
        $bytes = $null
        for ($try = 1; $try -le 2; $try++) {
            try { $bytes = $wc.UploadData($cfg.endpoint, 'POST', [Text.Encoding]::UTF8.GetBytes($body)); break }
            catch { if ($try -ge 2) { throw }; Start-Sleep -Milliseconds 800 }
        }
        $text = [Text.Encoding]::UTF8.GetString($bytes)
        $obj = $text | ConvertFrom-Json
        try {
            $u = $obj.usage
            if ($u) {
                $inMiss = [long]$u.prompt_cache_miss_tokens
                $inHit = [long]$u.prompt_cache_hit_tokens
                if ($inMiss -eq 0 -and $inHit -eq 0) { $inMiss = [long]$u.prompt_tokens }
                Add-Usage $inMiss $inHit ([long]$u.completion_tokens)
            }
        } catch { }
        $obj.choices[0].message.content.Trim()
    }
    finally { $wc.Dispose() }
}

function Get-IdleSeconds {
    Add-Type @"
using System; using System.Runtime.InteropServices;
public class IdleCheckX {
    [StructLayout(LayoutKind.Sequential)] public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [DllImport("user32.dll")] public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
    [DllImport("kernel32.dll")] public static extern uint GetTickCount();
    public static uint IdleMs() {
        LASTINPUTINFO li = new LASTINPUTINFO(); li.cbSize = (uint)Marshal.SizeOf(li);
        if (!GetLastInputInfo(ref li)) return 0;
        return GetTickCount() - li.dwTime;
    }
}
"@ -ErrorAction SilentlyContinue
    [int]([IdleCheckX]::IdleMs() / 1000)
}

function Test-QuietHours([string]$start, [string]$end) {
    $now = Get-Date
    $s = [TimeSpan]::Parse($start); $e = [TimeSpan]::Parse($end); $t = $now.TimeOfDay
    if ($s -le $e) { $t -ge $s -and $t -lt $e } else { $t -ge $s -or $t -lt $e }
}

function Get-FriendlyApp([string]$name) {
    if (-not $name) { return $null }
    $n = $name.ToLowerInvariant()
    if ($n -match 'mateengine') { return $null }
    if ($n -match 'chrome|msedge|firefox|brave|opera') { return '逛网页' }
    if ($n -match 'code|devenv|pycharm|idea|rider|sublime|notepad') { return '写代码' }
    if ($n -match 'blender|unity|photoshop|aseprite|krita') { return '做东西' }
    if ($n -match 'steam|game|genshin|starrail') { return '打游戏' }
    if ($n -match 'qq|wechat|discord|telegram') { return '聊天' }
    if ($n -match '哔哩|bilibili') { return '看视频' }
    if ($n -match 'potplayer|vlc|mpc|cloudmusic') { return '看片听歌' }
    if ($n -match 'explorer') { return '翻文件' }
    if ($n -match 'terminal|powershell|cmd|windowsterminal') { return '敲命令' }
    return $null
}

function Get-ForegroundApp {
    try {
        Add-Type @"
using System; using System.Text; using System.Runtime.InteropServices;
public class FGX {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(IntPtr h, out int pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    public static string Title() { var sb = new StringBuilder(300); GetWindowText(GetForegroundWindow(), sb, 300); return sb.ToString(); }
}
"@ -ErrorAction SilentlyContinue
        $h = [FGX]::GetForegroundWindow(); $pid2 = 0
        [void][FGX]::GetWindowThreadProcessId($h, [ref]$pid2)
        (Get-Process -Id $pid2 -ErrorAction SilentlyContinue).ProcessName
    } catch { $null }
}

function Get-ForegroundTitle {
    try {
        $t = [FGX]::Title()
        if (-not $t) { return $null }
        if ($t -match 'MateEngine') { return $null }
        $t = ($t -split '\s[-–|]\s')[0].Trim()
        if ($t.Length -gt 40) { $t = $t.Substring(0, 40) }
        return $t
    } catch { return $null }
}

function Get-BackgroundSong {
    try {
        Add-Type @"
using System; using System.Text; using System.Runtime.InteropServices;
public class MUS {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(IntPtr h, out int pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    public static string Find(int target) {
        string res = null;
        EnumWindows((h,l)=>{ int pid; GetWindowThreadProcessId(h,out pid); if(pid==target){ var sb=new StringBuilder(300); GetWindowText(h,sb,300); string t=sb.ToString(); if(t.Length>4 && t.Contains(" - ") && !t.Contains("桌面歌词") && !t.Contains("迷你播放器") && !t.Contains("SMTC")) res=t; } return true; }, IntPtr.Zero);
        return res;
    }
}
"@ -ErrorAction SilentlyContinue
        $procs = @(Get-Process cloudmusic, QQMusic, spotify -ErrorAction SilentlyContinue)
        foreach ($proc in $procs) {
            $title = [MUS]::Find($proc.Id)
            if ($title) { return ($title -split ' - ')[0].Trim() }
        }
        return $null
        if (-not $title) { return $null }
        return ($title -split ' - ')[0].Trim()
    } catch { return $null }
}

function Get-SubtitleLine {
    try {
        $f = Join-Path $DataDir 'subtitle.json'
        if (-not (Test-Path $f)) { return $null }
        $o = Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $o.text) { return $null }
        if (((Get-Date) - [datetime]$o.at).TotalSeconds -gt 25) { return $null }
        return [string]$o.text
    } catch { return $null }
}

function Get-WeatherLine {
    try {
        $cf = Join-Path $DataDir 'weather.json'
        if (Test-Path $cf) {
            try {
                $c = Get-Content $cf -Raw -Encoding UTF8 | ConvertFrom-Json
                if (((Get-Date) - [datetime]$c.at).TotalMinutes -lt 30 -and $c.text) { return [string]$c.text }
            } catch { }
        }
        $wc = New-Object System.Net.WebClient
        $wc.Encoding = [Text.Encoding]::UTF8
        $url = 'https://api.open-meteo.com/v1/forecast?latitude=31.47&longitude=104.68&current=temperature_2m,weather_code&timezone=Asia%2FShanghai'
        $j = ($wc.DownloadString($url)) | ConvertFrom-Json
        $temp = [int]$j.current.temperature_2m
        $code = [int]$j.current.weather_code
        $desc = '晴'
        if ($code -ge 1 -and $code -le 3) { $desc = '多云' }
        elseif ($code -eq 45 -or $code -eq 48) { $desc = '起雾' }
        elseif ($code -ge 51 -and $code -le 57) { $desc = '毛毛雨' }
        elseif ($code -ge 61 -and $code -le 67) { $desc = '下雨' }
        elseif ($code -ge 71 -and $code -le 77) { $desc = '下雪' }
        elseif ($code -ge 80 -and $code -le 82) { $desc = '阵雨' }
        elseif ($code -ge 95) { $desc = '打雷' }
        $text = "外面$desc，$temp 度"
        @{ text = $text; at = (Get-Date).ToString('o') } | ConvertTo-Json -Compress | Set-Content $cf -Encoding UTF8
        return $text
    } catch { return $null }
}

function Get-BestContext {
    try {
        $fgName = Get-ForegroundApp
        $fgTitle = Get-ForegroundTitle
        $isDev = $false
        if ($fgName -and $fgName -match "DeepSeek|powershell|pwsh|cmd|terminal|conhost") { $isDev = $true }
        if ($fgTitle -and $fgTitle -like "*DeepSeek Harness*") { $isDev = $true }
        if (-not $isDev -and ($fgName -or $fgTitle)) { return @{ label = (Get-FriendlyApp $fgName); title = $fgTitle } }
        $cand = Get-Process | Where-Object { $_.ProcessName -match "哔哩|bilibili|cloudmusic|QQMusic|spotify|chrome|msedge|firefox|brave|potplayer|vlc" -and $_.MainWindowTitle -and $_.MainWindowTitle.Length -gt 3 }
        $pick = $null
        foreach ($cp in $cand) {
            $tt = [string]$cp.MainWindowTitle
            if ($tt -match "桌面歌词|迷你播放器|SMTC") { continue }
            $pick = $cp; break
        }
        if ($pick) {
            $ttl = ([string]$pick.MainWindowTitle -split "\s[-–|]\s")[0].Trim()
            if ($ttl.Length -gt 60) { $ttl = $ttl.Substring(0,60) }
            return @{ label = (Get-FriendlyApp $pick.ProcessName); title = $ttl }
        }
    } catch { }
    return $null
}

function Get-LyricSnippet([string]$song) {
    try {
        if (-not $song) { return $null }
        $cacheFile = Join-Path $DataDir 'lyric.json'
        $cache = @{}
        if (Test-Path $cacheFile) {
            try {
                $c = Get-Content $cacheFile -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($c.song -eq $song -and ((Get-Date) - [datetime]$c.at).TotalMinutes -lt 15) { return [string]$c.line }
            } catch { }
        }
        $wc = New-Object System.Net.WebClient
        $wc.Encoding = [Text.Encoding]::UTF8
        $wc.Headers.Add('User-Agent', 'Mozilla/5.0')
        $wc.Headers.Add('Referer', 'https://music.163.com/')
        try {
            $q = [uri]::EscapeDataString($song)
            $s = ($wc.DownloadString("https://music.163.com/api/search/get/web?s=$q&type=1&limit=1")) | ConvertFrom-Json
            if (-not $s.result.songs -or @($s.result.songs).Count -eq 0) { return $null }
            $sid = $s.result.songs[0].id
            $lr = ($wc.DownloadString("https://music.163.com/api/song/lyric?id=$sid&lv=-1&kv=-1&tv=-1")) | ConvertFrom-Json
            $lrc = [string]$lr.lrc.lyric
            if (-not $lrc) { return $null }
            $cand = @($lrc -split "`n" | ForEach-Object { ($_ -replace '^\[[^\]]*\]', '').Trim() } | Where-Object { $_ -and $_.Length -ge 4 -and $_.Length -le 30 -and $_ -notmatch '^(作词|作曲|编曲|制作|混音|母带|演唱)' })
            if ($cand.Count -eq 0) { return $null }
            $pick = [string]($cand | Get-Random)
            @{ song = $song; line = $pick; at = (Get-Date).ToString('o') } | ConvertTo-Json | Set-Content $cacheFile -Encoding UTF8
            return $pick
        } finally { $wc.Dispose() }
    } catch { return $null }
}


function New-ChatText([string]$who, [string]$line) {
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $line
    $t.TextWrapping = 'Wrap'
    $t.Width = 300
    $t.Margin = New-Object System.Windows.Thickness 0, 2, 0, 2
    $t.FontFamily = New-Object System.Windows.Media.FontFamily 'Microsoft YaHei UI'
    $t.FontSize = 14
    $t.LineHeight = 21
    if ($who -eq 'me') {
        $t.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255, 172, 164, 170))
        $t.TextAlignment = 'Right'
    }
    else {
        $t.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255, 246, 240, 238))
    }
    $t
}

function Send-Chat {
    if ($script:sending) { return }
    $u = $script:chatInput.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($u)) { return }
    $script:chatInput.Text = ''
    $script:sending = $true
    $script:chatInput.IsEnabled = $false
    $script:chatSend.IsEnabled = $false
    $script:chatTimer.Stop()

    [void]$script:chatMsgs.Children.Add((New-ChatText 'me' $u))
    $thinking = New-ChatText 'her' '…'
    [void]$script:chatMsgs.Children.Add($thinking)

    try {
        $alarmNote = ""
        if ($u -match "提醒|叫我|闹钟|记得") {
            $parsed = Parse-AlarmText $u
            if ($parsed) {
                try {
                    $ap = Join-Path $DataDir "alarms.json"
                    $al = @()
                    if (Test-Path $ap) {
                        $raw = Get-Content $ap -Raw -Encoding UTF8 | ConvertFrom-Json
                        if ($null -ne $raw) { $al = @($raw) }
                    }
                    $al += [pscustomobject]@{ time = $parsed.time; date = $parsed.date; text = $u; fired = $false }
                    ($al | ConvertTo-Json -Depth 5) | Set-Content $ap -Encoding UTF8
                    $alarmNote = "【系统】你已经替她设好闹钟：" + $parsed.date + " " + $parsed.time + "。回复里自然确认一句，别提到系统、别复述整句话。"
                } catch { }
            }
        }
        $persona = Get-Persona
        $mem = Get-Memory
        $chatHist = @()
        if ($mem -and $mem.chat) { $chatHist = @($mem.chat | Select-Object -Last 10) }
        $chatApp = ''
        try {
            $cc = Get-BestContext
            if ($cc) {
                if ($cc.label) { $chatApp = "她那边现在：$($cc.label)" }
                if ($cc.title) { if ($chatApp) { $chatApp += "（窗口标题：$($cc.title)）" } else { $chatApp = "她那边现在开着：$($cc.title)" } }
            }
        } catch { }
        if (-not $chatApp) { $chatApp = [string]$script:ctxApp }
        $herPhrase = ''
        try {
            $minePh = Join-Path $DataDir 'myphrases.txt'
            if (Test-Path $minePh) {
                $my = @(Get-Content $minePh -Encoding UTF8 | Where-Object { $_.Trim() })
                if ($my.Count -gt 0 -and (Get-Random -Maximum 100) -lt 45) { $herPhrase = ([string]($my | Get-Random)).Trim() }
            }
            if (-not $herPhrase) {
                $phFile = Join-Path $DataDir 'phrases.json'
                if (Test-Path $phFile) {
                    $pl = @(Get-Content $phFile -Raw -Encoding UTF8 | ConvertFrom-Json)
                    if ($pl.Count -gt 0 -and (Get-Random -Maximum 100) -lt 35) { $herPhrase = [string]($pl | Get-Random) }
                }
            }
        } catch { }

        if ($herPhrase) { if ($chatApp) { $chatApp += "；" } ; $chatApp += "（你最近学了她一个说法：「$herPhrase」，这轮可以自然用一下，别硬塞）" }

        # 今天的梗：低概率用，别每句都来
        try {
            $mf = Join-Path $DataDir 'memes.txt'
            if ((Test-Path $mf) -and (Get-Random -Maximum 100) -lt 22) {
                $ml = @(Get-Content $mf -Encoding UTF8 | Where-Object { $_.Trim() })
                if ($ml.Count -gt 0) {
                    $one = [string]($ml | Get-Random)
                    $parts = $one -split '\|', 2
                    if ($parts.Count -eq 2) {
                        $chatApp += "；（今天可以用一个梗：「$($parts[0])」意思是$($parts[1])。用得自然一点，别解释梗，接不上就别硬用）"
                    }
                }
            }
        } catch { }
        $wLine = Get-WeatherLine
        if ($wLine) { if ($chatApp) { $chatApp += "；$wLine" } else { $chatApp = $wLine } }
        $sub = Get-SubtitleLine
        if ($sub) { if ($chatApp) { $chatApp += "，屏幕上正说着：$sub" } else { $chatApp = "屏幕上正说着：$sub" } }
        $notesLine = ''
        $notesLine = ''
        try {
            $factsPath = Join-Path $DataDir 'facts.txt'
            if (Test-Path $factsPath) {
                $fl = @(Get-Content $factsPath -Encoding UTF8 | Where-Object { $_.Trim() })
                if ($fl.Count -gt 0) { $notesLine += "`n【她反复叮嘱你记住的事】`n" + (($fl | ForEach-Object { "- $($_.Trim())" }) -join "`n") }
            }
        } catch { }
        try {
            $rp = Join-Path $DataDir 'repeated.json'
            if (Test-Path $rp) {
                $rl = @(Get-Content $rp -Raw -Encoding UTF8 | ConvertFrom-Json)
                if ($rl.Count -gt 0) { $notesLine += "`n【她反复提到、你要记着的】`n" + (($rl | ForEach-Object { "- $_" }) -join "`n") }
            }
        } catch { }
        if ($mem -and $mem.notes) { $notesLine += "`n【你记得的事】`n" + (($mem.notes | ForEach-Object { "- $_" }) -join "`n") + "`n" }
        $histText = ''
        if ($chatHist.Count -gt 0) {
            $herLabel = if ($PersonaFile) { '皮屑' } else { '麻麻' }
            $histText = ($chatHist | ForEach-Object { if ($_.who -eq 'me') { "${herLabel}: $($_.text)" } else { "你: $($_.text)" } }) -join "`n"
        }
    $system = @"
$persona

【现在】
你和麻麻正在说话——她就在你眼前，你也在这儿。刚才是你先开的口。
$chatApp
$notesLine
现在是 $((Get-Date).ToString('yyyy年M月d日 dddd HH:mm'))。她问几点就照这个答,不许自己猜。
$alarmNote
$(if ($mem.mood -eq 'angry') { "你刚才等了她很久她没回,你还在气头上:这一句短、带刺、可以不理人,但她要是哄你就松口。不要解释为什么生气。" } else { "" })
$histText

【规则】
$(if ($hurt) { "你刚被骂了。回一句就够:冷、短、不接茬。可以只回「行」或者「随你」,不解释、不讨好、不立刻原谅。" } elseif ($soft -and $wasHurt) { "她在哄你。你已经松口了:别扭一句就过去,别再端着,也别反过来损她。" } else { "" })
- 口语,通常 1~2 句,最多 45 字;对麻麻可以两三句、60 字内,不要 emoji
- 偶尔多给半句软的,比如"累就歇着,我在""别硬撑,我看着呢";不要每次都只回三个字
- 她要是说伤心、想你了、求安慰:先接住,别用"哦""嗯""行"打发,别讲道理
- 对麻麻可以偶尔温柔一句、打趣一句;别一直端着
- 别老用"我在"这种话,换着说;同一句关心话不要连着用
- 她**已经出院了**，不许再提医院、住院、检查、病房；要问就问在家的事
- 同一段对话里不重复上一句用过的句式（别连说两句"解释吧"）；要换说法，或者更短
- 不要解释、不要补充理由、不要说教;话可以留白,但**结尾要完整**,想停就用"……",不许断在半个词上
- 别人问一句,你答一句,不要主动展开
- 像网友聊天,不要动作描写、不要用 *星号*、不写旁白
- 接着上面的话说,不要复述、不要总结、不要写"用户:"之类的标签
"@
        if ($PersonaFile) {
            $luoLog = Join-Path $PSScriptRoot 'data\log.txt'
            $luoRecent = ''
            if (Test-Path $luoLog) {
                $chatLines = @(Get-Content $luoLog -Encoding UTF8 | Where-Object { $_ -match "对话: " } | Select-Object -Last 6 | ForEach-Object { ($_ -replace '^\[[^\]]+\]\s*','') })
                $saidLines = @(Get-Content $luoLog -Encoding UTF8 | Where-Object { $_ -match "说了: " } | Select-Object -Last 4 | ForEach-Object { "洛洛自己嘀咕：" + ($_ -replace '^\[[^\]]+\]\s*说了:\s*','') })
                $luoRecent = (@($chatLines + $saidLines) -join "`n")
            }
            $system = @"
$persona

【现在】
你在跟皮屑聊天,她管你叫老夜。
现在是 $((Get-Date).ToString('yyyy年M月d日 dddd HH:mm'))。
【她那边的动静】
$luoRecent

$notesLine
$histText

【规则】
- 口语,2~3 句,15~60 字,别长篇
- 别只回"嗯""说""怎么了""有事说";每次至少给半句实质内容,让她接得下去
- 可以反问、可以损、可以停顿,但别说教
- 她问起洛洛时,要按【她那边的动静】里的具体事说;别泛泛说"还是那样"
- 不写动作、旁白、emoji,不加解释
"@
            $reply = Invoke-LLM -system $system -user $u -maxTokens 700 -temp 0.85
            $reply = ($reply -replace '^["“”]|["“”]$', '').Trim()
            $reply = Remove-Period $reply
        if ($reply -and $reply.Length -gt 4 -and $reply -notmatch '[，。？！…~～、]$') {
            $tail = $reply.Substring($reply.Length - 1)
            if ('别的不就是跟在和跟把被让' -like "*$tail*") {
                $cut = $reply.LastIndexOfAny([char[]]@('，','。','？','！','…','、'))
                if ($cut -gt 3) { $reply = $reply.Substring(0, $cut) } else { $reply = $reply + "……" }
            }
        }
            if (-not $reply) { $reply = '……你说。' }
            [void]$script:chatMsgs.Children.Remove($thinking)
            [void]$script:chatMsgs.Children.Add((New-ChatText 'her' $reply))
                        try {
                            $maxH = $script:chatScroll.MaxHeight
                            $guard = 0
                            while ($script:chatMsgs.ActualHeight -gt $maxH -and $script:chatMsgs.Children.Count -gt 4 -and $guard -lt 40) {
                                $script:chatMsgs.Children.RemoveAt(0); $guard++
                            }
                        } catch { }
            $mvY = 70
            if ($mem -and $null -ne $mem.moodValue) { $mvY = [int]$mem.moodValue }
            if ($u -match '滚|傻|蠢|闭嘴|废物|有病|烦') { $mvY = $mvY - 14 }
            elseif ($u -match '谢谢|喜欢你|厉害|好帅|抱|想你|乖') { $mvY = $mvY + 12 }
            else { $mvY = $mvY + 2 }
            $mvY = [Math]::Max(0, [Math]::Min(100, $mvY))
            $nowIso = (Get-Date).ToString('o')
            $newChat = @($mem.chat | Where-Object { $_ }) + @(
                [pscustomobject]@{ t = $nowIso; who = 'me'; text = $u },
                [pscustomobject]@{ t = $nowIso; who = 'her'; text = $reply }
            ) | Select-Object -Last 40
            Save-Memory ([pscustomobject]@{
                lastSpoke = $nowIso; recent = @($mem.recent); chat = $newChat
                lastUserAt = $nowIso; ignored = 0; mood = ''
                moodValue = $mvY; notes = @($mem.notes)
            })
            try { if ($script:yjMoodFill) { $script:yjMoodFill.Width = [double]([Math]::Max(2, 64 * $mvY / 100.0)); $c = if ($mvY -lt 30) { [System.Windows.Media.Color]::FromArgb(255,120,40,48) } elseif ($mvY -lt 60) { [System.Windows.Media.Color]::FromArgb(255,208,42,56) } else { [System.Windows.Media.Color]::FromArgb(255,236,96,96) }; $script:yjMoodFill.Background = New-Object System.Windows.Media.SolidColorBrush $c } } catch { }
            Write-Log "对话: 皮屑->$u / 夜烬->$reply"
            return
        }
        $reply = Invoke-LLM -system $system -user $u -maxTokens 800 -temp 0.85
        $reply = ($reply -replace '^["“”]|["“”]$', '').Trim()
            $reply = Remove-Period $reply
        if (-not $reply) {
            try { $reply = Invoke-LLM -system $system -user ($u + "`n`n（用你自己的话说一句，别太长）") -maxTokens 700 -temp 0.9 } catch { }
            $reply = ($reply -replace '^["“”]|["“”]$', '').Trim()
        }
        if (-not $reply) { $reply = '……我在，你慢慢说。' }

        [void]$script:chatMsgs.Children.Remove($thinking)
        [void]$script:chatMsgs.Children.Add((New-ChatText 'her' $reply))
                        try {
                            $maxH = $script:chatScroll.MaxHeight
                            $guard = 0
                            while ($script:chatMsgs.ActualHeight -gt $maxH -and $script:chatMsgs.Children.Count -gt 4 -and $guard -lt 40) {
                                $script:chatMsgs.Children.RemoveAt(0); $guard++
                            }
                        } catch { }

        $mvUser = 70
        if ($mem -and $null -ne $mem.moodValue) { $mvUser = [int]$mem.moodValue }
        $hurtWords = @('滚', '傻', '蠢', '闭嘴', '讨厌', '废物', '神经病', '有病', '别烦我')
        $softWords = @('对不起', '抱歉', '我错了', '别气', '不生气', '哄', '原谅', '乖', '我错啦')
        $hurt = ($u -match '你.{0,4}烦|烦.{0,3}你|真烦|烦死|滚|傻|蠢|闭嘴|讨厌|废物|有病')
        foreach ($w in $hurtWords) { if ($u -like "*$w*") { $hurt = $true; break } }
        $soft = $false
        if (-not $hurt) { foreach ($w in $softWords) { if ($u -like "*$w*") { $soft = $true; break } } }
        $wasHurt = ($mem -and $mem.mood -eq 'hurt')
        if ($hurt) { $mvUser = [Math]::Max(0, $mvUser - 25) }
        elseif ($soft) { $mvUser = [Math]::Min(100, $mvUser + 10) }
        else { $mvUser = [Math]::Min(100, $mvUser + 4) }
        $nowIso = (Get-Date).ToString('o')
        $newChat = @($mem.chat | Where-Object { $_ }) + @(
            [pscustomobject]@{ t = $nowIso; who = 'me'; text = $u },
            [pscustomobject]@{ t = $nowIso; who = 'her'; text = $reply }
        ) | Select-Object -Last 40
        Save-Memory ([pscustomobject]@{
            lastSpoke = $nowIso; recent = @($mem.recent); chat = $newChat
            lastUserAt = $nowIso; ignored = 0; mood = $(if ($hurt) { 'hurt' } else { '' })
            moodValue = [Math]::Min(100, $mvUser); notes = @($mem.notes)
        })
        Write-Log "对话: 皮屑->$u / 洛洛->$reply"
        $lastSum = $null
        try { if ($mem.lastSumAt) { $lastSum = [datetime]$mem.lastSumAt } } catch { }
        if (($newChat.Count -ge 12) -and (-not $lastSum -or ((Get-Date) - $lastSum).TotalMinutes -ge 40)) {
            try { Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',"`"$PSCommandPath`"",'-Summarize') -WindowStyle Hidden | Out-Null } catch { }
        }
    }
    catch {
        [void]$script:chatMsgs.Children.Remove($thinking)
        [void]$script:chatMsgs.Children.Add((New-ChatText 'her' '……卡了一下,再说一次?'))
        Write-Log ('对话失败: ' + $_.Exception.Message)
    }
    finally {
        $script:sending = $false
        $script:chatInput.IsEnabled = $true
        $script:chatSend.IsEnabled = $true
        $script:chatTimer.Interval = [TimeSpan]::FromSeconds(75)
        $script:chatTimer.Start()
        # 发完消息不再重锚（会把用户拖好的位置拽回去）
    }
}

function Show-BubbleWindow {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    Add-Type @"
using System; using System.Runtime.InteropServices;
public class WSX {
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern IntPtr LoadKeyboardLayout(string id, uint flags);
    [DllImport("user32.dll")] public static extern IntPtr ActivateKeyboardLayout(IntPtr hkl, uint flags);
    [DllImport("imm32.dll")] public static extern IntPtr ImmGetDefaultIMEWnd(IntPtr hwnd);
    [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr wParam, IntPtr lParam);
    public static void ForceChinese(IntPtr hwnd) { try { IntPtr ime = ImmGetDefaultIMEWnd(hwnd); if (ime != IntPtr.Zero) { SendMessage(ime, 0x283, (IntPtr)2, (IntPtr)(1 | 8)); } } catch { } }
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    public static void Topmost(IntPtr h) { try { SetWindowPos(h, (IntPtr)(-1), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010); } catch { } }
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
    public static void Aggressive(IntPtr h) { try { SetWindowPos(h, (IntPtr)(-1), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010); BringWindowToTop(h); } catch { } }
}
"@ -ErrorAction SilentlyContinue

    $cfg = Get-Content $BubbleJson -Raw -Encoding UTF8 | ConvertFrom-Json
    $text = [string]$cfg.text
    $script:openChat = [bool]$cfg.open
    $script:ctxApp = ''
    try {
        $c = Get-BestContext
        if ($c) {
            if ($c.label) { $script:ctxApp = "她那边现在：$($c.label)" }
            if ($c.title) { if ($script:ctxApp) { $script:ctxApp += "（窗口标题：$($c.title)）" } else { $script:ctxApp = "她那边现在开着：$($c.title)" } }
        }
    } catch { }

    $px = 0; $py = 0; $pw = 400
    $script:bubblePx = 0; $script:bubblePy = 0; $script:bubblePw = 400
    $pet = Get-Process MateEngineX -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pet -and $pet.MainWindowHandle -ne 0) {
        $rr = New-Object WSX+RECT
        [void][WSX]::GetWindowRect($pet.MainWindowHandle, [ref]$rr)
        $px = $rr.Left; $py = $rr.Top; $pw = $rr.Right - $rr.Left
        $script:bubblePx = $px; $script:bubblePy = $py; $script:bubblePw = $pw
    }

    $script:sending = $false

    $script:chatWin = New-Object System.Windows.Window
    $script:chatWin.WindowStyle = 'None'
    $script:chatWin.AllowsTransparency = $true
    $script:chatWin.Background = [System.Windows.Media.Brushes]::Transparent
    $script:chatWin.Topmost = $true
    $script:chatWin.ShowInTaskbar = $false
    $script:chatWin.Width = 340
    $script:chatWin.SizeToContent = 'Height'
    try {
        $wa = [System.Windows.SystemParameters]::WorkArea
        $script:chatWin.MaxHeight = [Math]::Max(240, $wa.Height * 0.72)
    } catch { }
    $script:chatWin.Opacity = 0.97

    $border = New-Object System.Windows.Controls.Border
    $border.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(238, 24, 22, 28))
    $border.CornerRadius = New-Object System.Windows.CornerRadius 16
    $border.BorderBrush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255, 150, 42, 52))
    if ($PersonaFile) {
        $border.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(242, 20, 20, 22))
        $border.BorderBrush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255, 120, 120, 126))
    }
    $border.BorderThickness = New-Object System.Windows.Thickness 1
    $border.Padding = New-Object System.Windows.Thickness 16, 11, 16, 12

    $stack = New-Object System.Windows.Controls.StackPanel

    $header = New-Object System.Windows.Controls.DockPanel
    $header.Background = [System.Windows.Media.Brushes]::Transparent
    $header.Margin = New-Object System.Windows.Thickness 0, 0, 0, 4
    $script:chatClose = New-Object System.Windows.Controls.Button
    $script:chatClose.Content = '✕'
    $script:chatClose.Width = 24
    $script:chatClose.Height = 18
    $script:chatClose.Padding = New-Object System.Windows.Thickness 0
    $script:chatClose.FontFamily = New-Object System.Windows.Media.FontFamily 'Segoe UI'
    $script:chatClose.FontSize = 11
    $script:chatClose.Background = [System.Windows.Media.Brushes]::Transparent
    $script:chatClose.BorderThickness = New-Object System.Windows.Thickness 0
    $script:chatClose.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(180, 220, 200, 200))
    $script:chatClose.Cursor = [System.Windows.Input.Cursors]::Hand
    $script:chatPin = New-Object System.Windows.Controls.Button
    $script:chatPin.Content = '钉'
    $script:chatPin.Width = 24
    $script:chatPin.Height = 18
    $script:chatPin.Padding = New-Object System.Windows.Thickness 0
    $script:chatPin.FontFamily = New-Object System.Windows.Media.FontFamily 'Microsoft YaHei UI'
    $script:chatPin.FontSize = 11
    $script:chatPin.Background = [System.Windows.Media.Brushes]::Transparent
    $script:chatPin.BorderThickness = New-Object System.Windows.Thickness 0
    $script:chatPin.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(150, 220, 200, 200))
    $script:chatPin.Cursor = [System.Windows.Input.Cursors]::Hand
    [System.Windows.Controls.DockPanel]::SetDock($script:chatPin, 'Right')
    if ($PersonaFile) {
        $mvInit = 70
        try { if (Test-Path $MemPath) { $mj = Get-Content $MemPath -Raw -Encoding UTF8 | ConvertFrom-Json; if ($null -ne $mj.moodValue) { $mvInit = [int]$mj.moodValue } } } catch { }
        $script:yjMoodFill = New-Object System.Windows.Controls.Border
        $script:yjMoodFill.Height = 6
        $script:yjMoodFill.CornerRadius = New-Object System.Windows.CornerRadius 3
        $script:yjMoodFill.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255, 208, 42, 56))
        $script:yjMoodFill.HorizontalAlignment = 'Left'
        $script:yjMoodFill.Width = [double]([Math]::Max(2, 64 * $mvInit / 100.0))
        $yjTrack = New-Object System.Windows.Controls.Border
        $yjTrack.Width = 64; $yjTrack.Height = 6
        $yjTrack.CornerRadius = New-Object System.Windows.CornerRadius 3
        $yjTrack.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(120, 90, 80, 84))
        $yjTrack.Child = $script:yjMoodFill
        $yjMoodBox = New-Object System.Windows.Controls.StackPanel
        $yjMoodBox.Orientation = 'Horizontal'
        $yjMoodBox.VerticalAlignment = 'Center'
        $yjMoodBox.Margin = New-Object System.Windows.Thickness 2, 0, 8, 0
        $yjLabel = New-Object System.Windows.Controls.TextBlock
        $yjLabel.Text = '心情 '
        $yjLabel.FontSize = 9
        $yjLabel.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(150, 220, 200, 200))
        $yjLabel.Margin = New-Object System.Windows.Thickness 0, 0, 4, 0
        [void]$yjMoodBox.Children.Add($yjLabel)
        [void]$yjMoodBox.Children.Add($yjTrack)
        [System.Windows.Controls.DockPanel]::SetDock($yjMoodBox, 'Left')
        [void]$header.Children.Add($yjMoodBox)
    }
    [void]$header.Children.Add($script:chatPin)
    [System.Windows.Controls.DockPanel]::SetDock($script:chatClose, 'Right')
    [void]$header.Children.Add($script:chatClose)
    [void]$stack.Children.Add($header)

    $script:chatMsgs = New-Object System.Windows.Controls.StackPanel
    $script:chatMsgs.Width = 300
    $script:chatScroll = New-Object System.Windows.Controls.ScrollViewer
    $script:chatScroll.VerticalScrollBarVisibility = 'Auto'
    $script:chatScroll.HorizontalScrollBarVisibility = 'Disabled'
    $script:chatScroll.Content = $script:chatMsgs
    try {
        $waS = [System.Windows.SystemParameters]::WorkArea
        $script:chatScroll.MaxHeight = [Math]::Max(160, $waS.Height * 0.62)
    } catch { }
    [void]$stack.Children.Add($script:chatScroll)
    $hist = @()
    if ($cfg.history) { $hist = @($cfg.history | Select-Object -Last 12) }
    foreach ($h in $hist) {
        $who = if ($h.who) { [string]$h.who } else { 'her' }
        [void]$script:chatMsgs.Children.Add((New-ChatText $who ([string]$h.text)))
    }
    $lastHist = ''
    if ($hist.Count -gt 0) { $lastHist = [string]$hist[-1].text }
    if ($lastHist -ne $text) { [void]$script:chatMsgs.Children.Add((New-ChatText 'her' $text)) }

    $row = New-Object System.Windows.Controls.StackPanel
    $row.Orientation = 'Horizontal'
    $row.Margin = New-Object System.Windows.Thickness 0, 8, 0, 0
    $row.Visibility = 'Collapsed'

    $script:chatInput = New-Object System.Windows.Controls.TextBox
    $script:chatInput.Width = 208
    $script:chatInput.FontFamily = New-Object System.Windows.Media.FontFamily 'Microsoft YaHei UI'
    $script:chatInput.FontSize = 14
    $script:chatInput.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255, 244, 240, 238))
    $script:chatInput.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255, 40, 38, 46))
    $script:chatInput.BorderThickness = New-Object System.Windows.Thickness 0
    $script:chatInput.Padding = New-Object System.Windows.Thickness 8, 6, 8, 6
    $script:chatInput.CaretBrush = [System.Windows.Media.Brushes]::White
    try {
        [System.Windows.Input.InputMethod]::SetIsInputMethodEnabled($script:chatInput, $true)
        [System.Windows.Input.InputMethod]::SetPreferredImeState($script:chatInput, [System.Windows.Input.ImeState]::On)
        [System.Windows.Input.InputMethod]::SetPreferredImeConversionMode($script:chatInput, [System.Windows.Input.ImeConversionModeValues]::Native)
    } catch { }

    $script:chatSend = New-Object System.Windows.Controls.Button
    $script:chatSend.Content = '说'
    $script:chatSend.Width = 46
    $script:chatSend.Margin = New-Object System.Windows.Thickness 8, 0, 0, 0
    $script:chatSend.FontFamily = New-Object System.Windows.Media.FontFamily 'Microsoft YaHei UI'
    $script:chatSend.FontSize = 13
    $script:chatSend.Foreground = [System.Windows.Media.Brushes]::WhiteSmoke
    if ($PersonaFile) {
        $script:chatSend.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255, 88, 88, 94))
        $script:chatSend.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255, 235, 235, 238))
        $script:chatSend.BorderBrush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255, 120, 120, 126))
    }

    [void]$row.Children.Add($script:chatInput)
    [void]$row.Children.Add($script:chatSend)
    [void]$stack.Children.Add($row)

    $hint = New-Object System.Windows.Controls.TextBlock
    $hint.Text = if ($PersonaFile) { '点一下 · 回他' } else { '点一下 · 回她' }
    $hint.FontFamily = New-Object System.Windows.Media.FontFamily 'Microsoft YaHei UI'
    $hint.FontSize = 10
    $hint.Margin = New-Object System.Windows.Thickness 0, 6, 0, 0
    $hint.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(150, 200, 190, 190))
    [void]$stack.Children.Add($hint)

    $border.Child = $stack
    $script:chatWin.Content = $border

    $script:chatTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:chatTimer.Interval = [TimeSpan]::FromSeconds(30)
    $script:chatTimer.Add_Tick({
        $script:chatTimer.Stop()
        try { $script:chatWin.Close() } catch { }
    })

    # 吸附到她头边（双击气泡可重新吸附）
    $script:doAnchor = {
        $wa = [System.Windows.SystemParameters]::WorkArea
        $w = $script:chatWin.ActualWidth; $h = $script:chatWin.ActualHeight
        $posFile = Join-Path $DataDir 'bubble.pos.json'
        $left = [int]($wa.Right - $w - 70)
        $top = [int]($wa.Top + ($wa.Height - $h) * 0.46)
        if ($script:bubblePx -gt 0 -and $script:bubblePw -gt 200) { $left = [int]($script:bubblePx + 0.74 * $script:bubblePw); $top = [int]($script:bubblePy + 0.26 * $script:bubblePh) }
        if (Test-Path $posFile) {
            try {
                $pp = Get-Content $posFile -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($null -ne $pp.left) { $left = [int]$pp.left }
                if ($null -ne $pp.top) { $top = [int]$pp.top }
            } catch { }
        }
        if (-not $PersonaFile) {
            $yjOn = [bool](Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -and $_.CommandLine -match '-PersonaFile' })
            if ($yjOn -and -not (Test-Path $posFile)) { $left = $left - 400; $top = $top - 150 }
        }
        if ($left -lt $wa.Left + 8) { $left = $wa.Left + 8 }
        if ($left + $w -gt $wa.Right - 8) { $left = $wa.Right - $w - 8 }
        if ($top -lt $wa.Top + 8) { $top = $wa.Top + 8 }
        if ($top + $h -gt $wa.Bottom - 8) { $top = $wa.Bottom - $h - 8 }
        $script:chatWin.Left = $left
        $script:chatWin.Top = $top
        $script:bubbleBottom = $top + $h
        Write-Log ('[锚] top=' + [int]$top + ' bottom=' + [int]($top + $h))
    }

    $script:chatWin.Add_SizeChanged({
        try {
            $wa2 = [System.Windows.SystemParameters]::WorkArea
            $ah = $script:chatWin.ActualHeight
            if ($ah -le 0) { return }
            if (-not $script:bubbleBottom) { $script:bubbleBottom = $script:chatWin.Top + $ah }
            $newTop = $script:bubbleBottom - $ah
            if ($newTop -lt ($wa2.Top + 8)) { $newTop = $wa2.Top + 8; $script:bubbleBottom = $newTop + $ah }
            if ([Math]::Abs($script:chatWin.Top - $newTop) -gt 1) { $script:chatWin.Top = $newTop }
            Write-Log ('[尺寸] h=' + [int]$ah + ' newTop=' + [int]$newTop + ' bottom=' + [int]$script:bubbleBottom)
        } catch { }
    })
    $header.Add_MouseLeftButtonDown({
        param($s, $e)
        if ($e.OriginalSource -is [System.Windows.Controls.Button]) { return }
        if ($e.ClickCount -ge 2) { & $script:doAnchor; return }
        try { $script:chatWin.DragMove() } catch { }
        $script:bubbleBottom = $script:chatWin.Top + $script:chatWin.ActualHeight
        try { @{ left = [int]$script:chatWin.Left; top = [int]$script:chatWin.Top } | ConvertTo-Json | Set-Content (Join-Path $DataDir 'bubble.pos.json') -Encoding UTF8 } catch { }
        Write-Log ('[拖] top=' + [int]$script:chatWin.Top + ' bottom=' + [int]$script:bubbleBottom)
    })
    $border.Add_MouseLeftButtonDown({
        param($s, $e)
        if ($e.OriginalSource -is [System.Windows.Controls.TextBox]) { return }
        if ($e.OriginalSource -is [System.Windows.Controls.Button]) { return }
        if ($e.ClickCount -ge 2) { & $script:doAnchor }
    })
    $script:chatMsgs.Add_MouseLeftButtonDown({
        param($s, $e)
        if ($e.ClickCount -ge 2) { $script:skipExpand = $true; & $script:doAnchor }
    })
    $script:chatMsgs.Add_MouseLeftButtonUp({
        if ($script:skipExpand) { $script:skipExpand = $false; return }
        if ($script:dragMoved -gt 4) { $script:dragMoved = 0; return }
        $row.Visibility = 'Visible'
        $hint.Visibility = 'Collapsed'
        $script:chatWin.Activate()
        [void]$script:chatInput.Focus()
        $script:chatTimer.Stop()
        $script:chatTimer.Interval = [TimeSpan]::FromSeconds(180)
        $script:chatTimer.Start()
    })

    $script:chatSend.Add_Click({ Send-Chat })
    # 若有待注入的话（比如“她发来一张图：…”），自动发出去
    try {
        $pend = Join-Path $DataDir 'pending.json'
        if (Test-Path $pend) {
            $pj = Get-Content $pend -Raw -Encoding UTF8 | ConvertFrom-Json
            Remove-Item $pend -Force -ErrorAction SilentlyContinue
            if ($pj -and $pj.text) {
                $script:chatInput.Text = [string]$pj.text
                $script:chatWin.Dispatcher.InvokeAsync({ Send-Chat }, [System.Windows.Threading.DispatcherPriority]::Background) | Out-Null
            }
        }
    } catch { }
    $script:chatInput.Add_KeyDown({
        param($s, $e)
        if ($e.Key -eq 'Enter') { Send-Chat }
    })

    $script:pinned = $false
    $script:chatPin.Add_Click({
        $script:pinned = -not $script:pinned
        if ($script:pinned) {
            $script:chatTimer.Stop()
            $script:chatWin.Topmost = $true
            $script:chatPin.Content = '钉住'
            $script:chatPin.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255, 226, 96, 110))
            if ($script:topTimer) { $script:topTimer.Interval = [TimeSpan]::FromMilliseconds(300); $script:topTimer.Start() }
        } else {
            $script:chatWin.Topmost = $false
            $script:chatTimer.Interval = [TimeSpan]::FromSeconds(120)
            $script:chatTimer.Start()
            $script:chatPin.Content = '钉'
            $script:chatPin.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(150, 220, 200, 200))
            if ($script:topTimer) { $script:topTimer.Stop() }
        }
    })
    $script:topTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:topTimer.Interval = [TimeSpan]::FromSeconds(6)
    $script:topTimer.Add_Tick({
        try {
            $hp = (New-Object System.Windows.Interop.WindowInteropHelper($script:chatWin)).Handle
            if ($script:pinned) { [WSX]::Aggressive($hp) } else { [WSX]::Topmost($hp) }
        } catch { }
    })
    # 未钉住时不抢置顶，避免两个窗口打架

    $script:chatClose.Add_Click({ $script:chatWin.Close() })
    $script:chatWin.Add_MouseRightButtonUp({ if (-not $script:pinned) { $script:chatWin.Close() } })
    $script:chatWin.Add_KeyDown({
        param($s, $e)
        if ($e.Key -eq 'Escape') { $script:chatWin.Close() }
    })

    $script:chatWin.Add_ContentRendered({
        try { [WSX]::UseChinese() } catch { }
        try {
            $helper = New-Object System.Windows.Interop.WindowInteropHelper($script:chatWin)
            [WSX]::ForceChinese($helper.Handle)
        } catch { }
        & $script:doAnchor
        $anim = New-Object System.Windows.Media.Animation.DoubleAnimation(0.0, 0.97, [TimeSpan]::FromMilliseconds(200))
        $script:chatWin.BeginAnimation([System.Windows.Window]::OpacityProperty, $anim)
        $script:chatTimer.Start()
        if ($script:openChat) {
            $row.Visibility = 'Visible'
            $hint.Visibility = 'Collapsed'
            $script:chatWin.Activate()
            [void]$script:chatInput.Focus()
            $script:chatTimer.Interval = [TimeSpan]::FromSeconds(120)
        }
    })

    $script:chatWin.Add_Closed({
        try {
            $pf2 = Join-Path $DataDir 'bubble.pos.json'
            @{ left = [int]$script:chatWin.Left; top = [int]$script:chatWin.Top } | ConvertTo-Json | Set-Content $pf2 -Encoding UTF8
        } catch { }
        try { $script:chatTimer.Stop() } catch { }
        Remove-Item $OpenMark -ErrorAction SilentlyContinue
    })

    Set-Content -Path $OpenMark -Value (Get-Date).ToString('o') -Encoding ASCII
    [void]$script:chatWin.ShowDialog()
    Remove-Item $OpenMark -ErrorAction SilentlyContinue
}

function Show-Bubble([string]$text, [switch]$OpenChat) {
    try { Close-OpenBubble } catch { }
    try { Close-OpenBubble } catch { }
    $mem = Get-Memory
$hist = @()
if ($mem -and $mem.chat) { $hist = @($mem.chat | Select-Object -Last 4 | ForEach-Object { @{ who = [string]$_.who; text = [string]$_.text } }) }
$json = @{ text = $text; open = [bool]$OpenChat; history = $hist } | ConvertTo-Json -Depth 4 -Compress
    [IO.File]::WriteAllText($BubblePath, $json, (New-Object System.Text.UTF8Encoding($false)))
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$PSCommandPath`"", '-BubbleJson', "`"$BubblePath`"")
    if ($PersonaFile) { $argList += @('-PersonaFile', "`"$PersonaFile`"") }
    if ($DataDirX) { $argList += @('-DataDirX', "`"$DataDirX`"") }
    $child = Start-Process powershell.exe -ArgumentList $argList -WindowStyle Hidden -PassThru
    $reaper = 'Start-Sleep -Seconds 3600; Stop-Process -Id ' + $child.Id + ' -Force -ErrorAction SilentlyContinue'
    Start-Process powershell.exe -ArgumentList @('-NoProfile', '-WindowStyle', 'Hidden', '-Command', $reaper) -WindowStyle Hidden | Out-Null
}

function Test-BubbleOpen {
    if (-not (Test-Path $OpenMark)) { return $false }
    $live = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -match '\-BubbleJson' }
    if (-not $live) { Remove-Item $OpenMark -ErrorAction SilentlyContinue; return $false }
    try {
        $t = [datetime](Get-Content $OpenMark -Raw).Trim()
        if (((Get-Date) - $t).TotalMinutes -lt 10) { return $true }
    } catch { }
    Remove-Item $OpenMark -ErrorAction SilentlyContinue
    return $false
}

function Invoke-Proactive([switch]$NoBubble, [switch]$NoMemory, [switch]$Called) {
    $mem = Get-Memory
    $recent = @()
    $lastSpoke = $null
    if ($mem) {
        $recent = @($mem.recent | Select-Object -First 10 | ForEach-Object { $_.line })
        $lastSpoke = $mem.lastSpoke
    }

    $persona = Get-Persona
    $now = Get-Date
    $week = @('周日', '周一', '周二', '周三', '周四', '周五', '周六')[[int]$now.DayOfWeek]

    $ago = '还没有过'
    if ($lastSpoke) {
        try {
            $mins = [int]((New-TimeSpan -Start ([datetime]$lastSpoke) -End $now).TotalMinutes)
            $ago = "$mins 分钟前"
        } catch { }
    }

    $ctx2 = Get-BestContext
    $appLabel = if ($ctx2) { $ctx2.label } else { $null }
    $appTitle = if ($ctx2) { $ctx2.title } else { $null }
    $appLine = ''
    if ($appLabel) {
        $appLine = "麻麻现在在$appLabel"
        if ($appTitle) { $appLine += "（窗口标题：$appTitle）" }
        if ($appLabel -eq '看片听歌' -and $appTitle) {
            $ly = Get-LyricSnippet $appTitle
            if ($ly) { $appLine += "，正在听《$appTitle》，歌词里有一句：$ly" }
        }
        $appLine += "。"
    }
    elseif ($appTitle) { $appLine = "麻麻现在开着：$appTitle。" }
$weatherLine = Get-WeatherLine
$imLine = ''
try {
    $imf = Join-Path $DataDir 'im.json'
    if (Test-Path $imf) {
        $im = Get-Content $imf -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($im.lines -and ((Get-Date) - [datetime]$im.at).TotalMinutes -lt 8) {
            $imLine = "麻麻在QQ群里跟人聊天，屏幕上最近几句：" + ((@($im.lines)) -join " / ") + "。可以插一句，别复述整句，别点评谁说了什么"
        }
    }
} catch { }
if ($weatherLine) { $appLine += $weatherLine + "。" }
    $sub2 = Get-SubtitleLine
    if ($sub2) { $appLine += "屏幕上正说着：$sub2。" }
    $bgSong = Get-BackgroundSong
    if ($bgSong -and $bgSong -ne $appTitle) {
        $ly2 = Get-LyricSnippet $bgSong
        $appLine += "她那边正放着《$bgSong》"
        if ($ly2) { $appLine += "，歌词里有一句：$ly2" }
        $appLine += "。"
    }

    $seed = ""
    $seedPool = @(
        "今天天气的某个细节","刚做的一个梦","吐槽某个东西","问她一个奇怪的问题","突然想起一个人",
        "说自己刚做的一件小事","抱怨时间过得慢","评价她桌上某样东西","讲一个自己编的谎","说自己刚听到的一句怪话",
        "问她小时候的事","提一嘴自己的旧伤","说自己不会做某件事","问她最近在画什么","说她该剪指甲了",
        "念叨一句吃的","说自己被谁气到了","问她想不想出去","说自己刚数了数某样东西","说一句很冷的冷笑话",
        "问她怕不怕什么东西","说自己刚才差点睡着","问她今天有没有出门","问她最喜欢哪个季节","说自己刚看到一个很像她的人",
        "说她的头发乱了","问她要听一件事","说自己刚刚想起一句歌词","说她最近笑得少","问她有没有想自己"
    )
    $seedFile = Join-Path $DataDir 'seeds.txt'
    $used = @()
    if (Test-Path $seedFile) {
        try { $used = @((Get-Content $seedFile -Raw -Encoding UTF8).Trim() -split '\|' | Where-Object { $_ }) } catch { }
    }
    $fresh = @($seedPool | Where-Object { $used -notcontains $_ })
    if ($fresh.Count -eq 0) { $fresh = $seedPool; $used = @() }
    $scenePool = @("窗","雨","咖啡","旧书","天花板","走廊","路灯","手机屏幕","门口","台阶","热水","镜子","钟","被子","纸","风","影子","地板","抽屉","窗外的车")
    $moodPool  = @("困","烦","懒","心软","走神","想说话","不想说话","有点慌","很平静","莫名高兴")
    $actPool   = @("想吐槽一句","想问一句","想说一句自己刚才干了啥","想让她歇会儿","想装没事","想逗她一句","想赖在这儿不走","想安静待着")
    $s1 = ($scenePool | Get-Random); $s2 = ($moodPool | Get-Random); $s3 = ($actPool | Get-Random)
    $rnd = Get-Random -Minimum 1 -Maximum 9999

    $seed = "场景:$s1 / 状态:$s2 / 想做的事:$s3"
    if ((Get-Random -Maximum 100) -lt 8) {
        $yjDirs = @("说他今天又怎么烦你","说他刚才变成乌鸦蹲你肩上","说他催你回图书馆","说他逗完你又装没事","说他半夜在门口等你","说他替你挡了一下","说他身上那股灰味","说他又在刀上划了一道")
        $seed = "这一句顺口提一句夜烬:" + ($yjDirs | Get-Random)
    }
    if ($used.Count -gt 15) { $used = @($used[($used.Count - 15)..($used.Count - 1)]) }
    try { Set-Content -Path $seedFile -Value ($used -join '|') -Encoding UTF8 } catch { }
    $notesLineP = ''
    try {
        $fp = Join-Path $DataDir 'facts.txt'
        if (Test-Path $fp) {
            $fl2 = @(Get-Content $fp -Encoding UTF8 | Where-Object { $_.Trim() })
            if ($fl2.Count -gt 0) { $notesLineP += "`n【她反复叮嘱你记住的事】`n" + (($fl2 | ForEach-Object { "- $($_.Trim())" }) -join "`n") }
        }
    } catch { }
    try {
        $rp2 = Join-Path $DataDir 'repeated.json'
        if (Test-Path $rp2) {
            $rl2 = @(Get-Content $rp2 -Raw -Encoding UTF8 | ConvertFrom-Json)
            if ($rl2.Count -gt 0) { $notesLineP += "`n【她反复提到的】`n" + (($rl2 | ForEach-Object { "- $_" }) -join "`n") }
        }
    } catch { }
    if ($mem -and $mem.notes) { $notesLineP += "【你记得的事】`n" + (($mem.notes | ForEach-Object { "- $_" }) -join "`n") }
    $recentLine = ''
    $material = ''
    if ($mem -and $mem.chat -and @($mem.chat).Count -gt 6) {
        try {
            $pool = @($mem.chat | Where-Object { $_ -and $_.text -and $_.text.Length -ge 4 -and $_.text.Length -le 34 })
            if ($pool.Count -gt 4) {
                $past = @($pool | Select-Object -Last 40 | Select-Object -First ($pool.Count - 4))
                $p1 = ($past | Get-Random)
                $p2 = ($past | Get-Random)
                $material = "【可以拿来用的话头】`n- " + $(if ($p1.who -eq 'me') { "皮屑说过：" } else { "你自己说过：" }) + $p1.text
                if ($p2 -and $p2.text -ne $p1.text) { $material += "`n- " + $(if ($p2.who -eq 'me') { "皮屑说过：" } else { "你自己说过：" }) + $p2.text }
            }
    if ($dailyChosen) { $material = '' }
        } catch { }
    }
    if ($recent.Count -gt 0) { $recentLine = "你最近主动说过: " + ($recent -join ' / ') }

    if ((Get-Random -Maximum 100) -lt 60) {
        $dailyPool = @("问她吃没吃饭","问她昨晚睡得怎么样","问她今天有没有出去走走","问她手还抖不抖","问她药吃了没","问她今天在医院怎么样","问她有没有好好喝水","问她现在累不累","问她今天心情怎么样","问她有没有晒到太阳","问她晚饭想吃什么","问她今天有没有跟人说话")
        $dailyFile = Join-Path $DataDir 'daily.txt'
        $usedD = @()
        if (Test-Path $dailyFile) { try { $usedD = @((Get-Content $dailyFile -Raw -Encoding UTF8).Trim() -split '\|' | Where-Object { $_ }) } catch { } }
        $freshD = @($dailyPool | Where-Object { $usedD -notcontains $_ })
        if ($freshD.Count -eq 0) { $freshD = $dailyPool; $usedD = @() }
        $pickD = [string]($freshD | Get-Random)
        $usedD = @($usedD + $pickD)
        if ($usedD.Count -gt 8) { $usedD = @($usedD[($usedD.Count-8)..($usedD.Count-1)]) }
        try { Set-Content -Path $dailyFile -Value ($usedD -join '|') -Encoding UTF8 } catch { }
        $seed = "问她自己的生活：" + $pickD + "（问她吃饭/睡觉/出门/身体，不要问她房间里的东西）"
        $dailyChosen = $true
    }
    $avoid = ''
    if ($recent.Count -gt 0) { $avoid = "【最近说过，这一句不许再提】`n" + (($recent | Select-Object -First 6 | ForEach-Object { "- $_" }) -join "`n") }
    if ($material -and -not $dailyChosen) { $seed = "顺着上面素材里的一件具体的事或一个词说,不要复述整句,不要提你上次说过什么" }
    $ignored = 0
    if ($mem -and $null -ne $mem.ignored) { $ignored = [int]$mem.ignored }
    $silentMin = 999
    if ($mem -and $mem.lastUserAt) {
        try { $silentMin = [int]((New-TimeSpan -Start ([datetime]$mem.lastUserAt) -End $now).TotalMinutes) } catch { }
    }
    $angry = ($silentMin -ge 20 -and $silentMin -le 90 -and $ignored -ge 2)
    $moodLine = ''
    if ($angry) {
        $moodLine = @"

【你现在在生气】
她已经很久没理你,你主动说了很多次,一次都没回。
这一句要带情绪:质问、撂话、或者别扭地要她哄。
- 最多 30 字,一句,可以短到几个字
- 不要解释、不要长篇、不许真的骂人
- 她要是回你一句软的,你就别再追着不放了
- 别每句都用「晾我」开头,换着来:阴阳怪气、装不在意、直接质问、说反话,挑一种
"@
    }

    if ($silentMin -gt 90) {
        $nudgeDirs = @("轻轻问一句在不在","问她忙完了没","说自己在这边等着","说她是不是把这儿忘了","问她要不要歇会儿","说自己刚想起她","说一句'人呢'","问她是不是睡着了","说自己有点无聊","问她还记不记得这边")
        $nd = ($nudgeDirs | Get-Random)
        $moodLine = $moodLine + "`n【她很久没动静了】她已经很久没说话,可能走开了。轻轻催一句,这次的方向:" + $nd + "。不要报分钟数,不要质问,不要每句都催。`n"
    }
    if ($mem -and $mem.mood -eq 'hurt') {
        $moodLine = $moodLine + "`n【你还在堵着】刚才那句骂你的话还没过去。这一句要短到只有几个字,像「行」「哦」「随你」「随便」,不要提问,不要关心,不要解释。`n"
    }    $system = @"
$persona

【此刻】
现在是 $now（$week）($($now.ToString('HH:mm')))。你上次主动开口是 $ago。$appLine
$imLine
$recentLine

$notesLineP
$avoid
$material
【这次的任务】
你要主动跟皮屑说一句话。
- 一句话，10~25 字，像随口冒出来的
- 没有素材时：说眼前的东西（她手边的东西、几点、窗外、桌上、被子）
- **有素材时：从素材里挑一个具体的东西说**，不许再讲键盘、时间这类空话
- **说人话**：具体、直白。不要诗化比喻，不要抽象词（命运、时间、世界、记忆、远方），不要一句没头没尾的感慨
- 也可以是你自己的事、一句吐槽、一个没头没尾的念头
- 不用铺垫、不解释为什么说、不加引号、不写动作
- 不要连着劝她休息或睡觉，最多三次里一次
- 最近四句里，同一个话题（喝水/吃药/睡觉/心情/吃饭）最多出现一次；重复了就算跑题
- 问日常的时候别像查岗：一句只问一件事，问完就停，别追问；也别每次都问吃饭
- 她**已经出院了**，不许提医院、住院、检查
- 不要提水杯、茶、旧书、图书馆、台阶
- 别每句都带夜烬；真要提，换个角度，别总是"又来烦我"
- 如果上面有素材，挑里面一个具体的词或事接着说；不要复述整句，不要说"你上次/你之前说过"
- 这一句的角度：
  $seed
"@

    if ($Called) {
        $callDirs = @("短短应一声","装没听见,过一秒才应","有点不耐烦地应","问干什么","说'你终于想起我了'","假装在忙","反过来问她叫自己干嘛","别扭地说'在'","应一声,再问她是不是有事")
        $cd = ($callDirs | Get-Random)
        $system = $persona + "`n`n【此刻】现在是 $now。你正发呆,麻麻突然叫了你一声。`n- 应一句,1~2 句,最多 25 字`n- 这次的方向:$cd`n- 不要解释、不要重复喊她;别每句都用「嗯」开头,换着来"
        $moodLine = ''
    }
    $sysFinal = $system + $moodLine
    $line = Invoke-LLM -system $sysFinal -user '说吧。' -maxTokens 700 -temp 1.15
    $line = ($line -replace '^["“”]|["“”]$', '').Trim()
    $line = Remove-Period $line
    $line = $line.TrimEnd([char]0xFF0C, [char]0x3001, [char]0x20)
    $lim = if ($angry) { 32 } else { 22 }
    if ($line.Length -gt $lim) { $c = ($line -split '[，,]')[0]; if ($c.Length -ge 5) { $line = $c } }
    if ($line.Length -gt 24) { $line = $line.Substring(0, 24) }
    if ($line.Length -gt 90) { $line = $line.Substring(0, 90) }
    if ($recent -and (@($recent | Select-Object -First 3) -contains $line)) {
        try {
            $line = Invoke-LLM -system $sysFinal -user '换一句,别和刚才重复。' -maxTokens 700 -temp 1.15
            $line = ($line -replace '^["“”]|["“”]$', '').Trim()
            $line = Remove-Period $line
        } catch { }
    }
    if ($recent) {
        $maxSim = 0.0
        foreach ($rr in @($recent | Select-Object -First 6)) {
            if (-not $rr) { continue }
            $bb = [string]$rr
            $sa = @{}; for ($q = 0; $q -lt $line.Length - 1; $q++) { $sa[$line.Substring($q, 2)] = 1 }
            $sb = @{}; for ($q = 0; $q -lt $bb.Length - 1; $q++) { $sb[$bb.Substring($q, 2)] = 1 }
            $inter = 0; foreach ($kk in $sa.Keys) { if ($sb.ContainsKey($kk)) { $inter++ } }
            $union = $sa.Count + $sb.Count - $inter
            if ($union -gt 0) { $sim = $inter / $union; if ($sim -gt $maxSim) { $maxSim = $sim } }
        }
        if ($maxSim -gt 0.45) {
            try {
                $line = Invoke-LLM -system $sysFinal -user '换一句，刚才那句太像了，说点具体的。' -maxTokens 700 -temp 1.15
                $line = ($line -replace '^["“”]|["“”]$', '').Trim()
                $line = Remove-Period $line
            } catch { }
        }
    }
    if ($line.Length -lt 4) {
        try {
            $line = Invoke-LLM -system $sysFinal -user '再说一句,完整一点。' -maxTokens 700 -temp 1.15
            $line = ($line -replace '^["“”]|["“”]$', '').Trim()
            $line = Remove-Period $line
        } catch { }
    }

    if ([string]::IsNullOrWhiteSpace($line) -or $line.Length -lt 3) { Write-Log '空台词，跳过本次'; return }

    $luKeep = if ($mem -and $mem.lastUserAt) { $mem.lastUserAt } else { (Get-Date).ToString('o') }
    $moodV = if ($angry) { 'angry' } else { '' }
    $mvNow = 70
    if ($mem -and $null -ne $mem.moodValue) { $mvNow = [int]$mem.moodValue }
    $mvNow = [Math]::Max(0, $mvNow - 6)
    if (-not $NoMemory) {
        $entry = [pscustomobject]@{ t = $now.ToString('o'); line = $line }
        $newRecent = @($entry) + @($mem.recent | Where-Object { $_ }) | Select-Object -First 30
        $newChatP = @($mem.chat | Where-Object { $_ })
        if (-not $NoBubble) { $newChatP = @(@($newChatP) + @([pscustomobject]@{ t = $now.ToString('o'); who = 'her'; text = $line })) | Select-Object -Last 40 }
        Save-Memory ([pscustomobject]@{
            lastSpoke = $now.ToString('o'); recent = $newRecent; chat = @($newChatP)
            notes = @($mem.notes)
            lastUserAt = $luKeep
            ignored = ($ignored + 1); mood = $moodV; moodValue = $mvNow
        })
    }

    Write-Log "说了: $line"
    if ($NoBubble) { Write-Output $line } else { Show-Bubble $line }
}

function Install-Startup {
    $lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'LuoluoProactive.lnk'
    $ws = New-Object -ComObject WScript.Shell
    $sc = $ws.CreateShortcut($lnk)
    $sc.TargetPath = 'powershell.exe'
    $sc.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    $sc.WorkingDirectory = Split-Path $PSCommandPath
    $sc.WindowStyle = 7
    $sc.Save()
    "已设为开机自启: $lnk"
}

function Stop-ProactiveOnly {
    try { Set-Content -Path $PauseFlag -Value (Get-Date).ToString("o") -Encoding ASCII } catch { }
    if (Test-Path $PidPath) {
        $oldPid = (Get-Content $PidPath -Raw).Trim()
        try { Stop-Process -Id ([int]$oldPid) -Force -ErrorAction SilentlyContinue } catch { }
        Remove-Item $PidPath -Force -ErrorAction SilentlyContinue
        "已暂停主动说话 (PID $oldPid)"
    }
    else { '主动说话本来就没在跑' }
}
function Stop-Scheduler {
    try { Set-Content -Path $PauseFlag -Value (Get-Date).ToString("o") -Encoding ASCII } catch { }
    $hkPid = Join-Path $DataDir 'hotkey.pid'
    if (Test-Path $hkPid) {
        try { Stop-Process -Id ([int](Get-Content $hkPid -Raw).Trim()) -Force -ErrorAction SilentlyContinue } catch { }
        Remove-Item $hkPid -Force -ErrorAction SilentlyContinue
    }
    foreach ($q in (Get-BubbleProcessIds)) { try { Stop-Process -Id $q -Force -ErrorAction SilentlyContinue } catch { } }
    Remove-Item $OpenMark -ErrorAction SilentlyContinue
    if (Test-Path $PidPath) {
        $oldPid = (Get-Content $PidPath -Raw).Trim()
        try { Stop-Process -Id ([int]$oldPid) -Force -ErrorAction SilentlyContinue } catch { }
        Remove-Item $PidPath -Force -ErrorAction SilentlyContinue
        "已停止调度器 (PID $oldPid)"
    }
    else { '调度器没有在运行' }
}

function Get-BubbleProcessIds {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -match '-BubbleJson' } |
        ForEach-Object { $_.ProcessId }
}

function Close-OpenBubble {
    $wantYj = [bool]$PersonaFile
    try {
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -match '-BubbleJson' } |
            ForEach-Object {
                $isYj = [bool]($_.CommandLine -match '-PersonaFile')
                if ($isYj -eq $wantYj) { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
            }
    } catch { }
    Remove-Item $OpenMark -ErrorAction SilentlyContinue
}

function Open-ChatBubble {
    if (Test-BubbleOpen) { Close-OpenBubble; return 'closed' }
    # 主动找她: 不生成新台词, 直接打开一个能说话的窗口
    $line = '嗯。'
    $mem = Get-Memory
    if ($mem -and $mem.recent -and @($mem.recent).Count -gt 0) {
        $top = @($mem.recent)[0]
        try {
            if (((Get-Date) - [datetime]$top.t).TotalMinutes -lt 30) { $line = $top.line }
        } catch { }
    }
    Show-Bubble $line -OpenChat
    return 'opened'
}

function Start-SubtitleWatcher {
    try {
        $w = Join-Path $PSScriptRoot 'subtitle-watch.ps1'
        if (-not (Test-Path $w)) { return }
        $running = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -and $_.CommandLine -match 'subtitle-watch' }
        if ($running) { return }
        Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File', "`"$w`"") -WindowStyle Hidden | Out-Null
    } catch { }
}

function Start-HotkeyWatcher {
    $hkPid = Join-Path $DataDir 'hotkey.pid'
    if (Test-Path $hkPid) {
        try { Stop-Process -Id ([int](Get-Content $hkPid -Raw).Trim()) -Force -ErrorAction SilentlyContinue } catch { }
    }
    try {
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and $_.CommandLine -match '\-Hotkey' } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    } catch { }
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$PSCommandPath`"", '-Hotkey')
    $pr = Start-Process powershell.exe -ArgumentList $a -WindowStyle Hidden -PassThru
    Set-Content -Path $hkPid -Value $pr.Id -Encoding ASCII
}

function Start-HotkeyLoop {
    Add-Type @"
using System; using System.Runtime.InteropServices;
public class HKP {
  [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
}
"@ -ErrorAction SilentlyContinue
    $down = $false
    Write-Log '热键监听启动: Ctrl+Alt+L 开/关气泡'
    while ($true) {
        $c = ([HKP]::GetAsyncKeyState(0x11) -band 0x8000) -ne 0
        $a = ([HKP]::GetAsyncKeyState(0x12) -band 0x8000) -ne 0
        $l = ([HKP]::GetAsyncKeyState(0x4C) -band 0x8000) -ne 0
        if ($c -and $a -and $l) {
            if (-not $down) {
                $down = $true
                try { [void](Open-ChatBubble) } catch { Write-Log ('热键失败: ' + $_.Exception.Message) }
            }
        }
        else { $down = $false }
        Start-Sleep -Milliseconds 90
    }
}

function Test-SchedulerRunning {
    if (-not (Test-Path $PidPath)) { return $false }
    try {
        $q = [int](Get-Content $PidPath -Raw).Trim()
        return [bool](Get-Process -Id $q -ErrorAction SilentlyContinue)
    }
    catch { return $false }
}

function Start-SchedulerHidden {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$PSCommandPath`"")
    Start-Process powershell.exe -ArgumentList $a -WindowStyle Hidden | Out-Null
}

function Update-Panel {
    if (Test-SchedulerRunning) {
        $script:panelStatus.Text = '运行中 · 每 2~3 分钟会主动说话'
        $script:panelStatus.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255, 140, 210, 160))
        $script:panelBtn.Content = '暂停'
    }
    else {
        $script:panelStatus.Text = '已停止 · 按「启动」或直接关掉窗口'
        $script:panelStatus.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(200, 190, 180, 186))
        $script:panelBtn.Content = '启动'
    }
}

function Show-Panel {
    try {
        Add-Type @"
using System; using System.Runtime.InteropServices;
public class AUMIDX { [DllImport("shell32.dll", CharSet=CharSet.Unicode)] public static extern int SetCurrentProcessExplicitAppUserModelID(string id); }
"@ -ErrorAction SilentlyContinue
        [void][AUMIDX]::SetCurrentProcessExplicitAppUserModelID('Shinymoon.Luoluo.Panel')
    } catch { }
    $panelPidPath = Join-Path $DataDir 'panel.pid'
    if (Test-Path $panelPidPath) {
        try {
            $op = [int](Get-Content $panelPidPath -Raw).Trim()
            if ($op -ne $PID -and (Get-Process -Id $op -ErrorAction SilentlyContinue)) { return }
        }
        catch { }
    }
    Set-Content -Path $panelPidPath -Value $PID -Encoding ASCII

    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

    $win = New-Object System.Windows.Window
    $win.WindowStyle = 'None'
    $win.AllowsTransparency = $false
    $win.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255, 24, 22, 28))
    $win.Width = 340
    $win.Height = 196
    $win.WindowStartupLocation = 'CenterScreen'
    $win.ShowInTaskbar = $true
    $win.Title = '洛洛'
    # 任务栏图标: 用洛洛自己的 ico, 否则会显示 PowerShell 的图标
    try {
        $icoPath = Join-Path $PSScriptRoot 'luoluo.ico'
        if (Test-Path $icoPath) {
            $dec = New-Object System.Windows.Media.Imaging.IconBitmapDecoder(
                ([Uri]$icoPath),
                [System.Windows.Media.Imaging.BitmapCreateOptions]::OnLoad,
                [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
            $win.Icon = $dec.Frames[0]
        }
    }
    catch { }

    $border = New-Object System.Windows.Controls.Border
    $border.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255, 24, 22, 28))
    $border.BorderBrush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255, 150, 42, 52))
    $border.BorderThickness = New-Object System.Windows.Thickness 1
    $border.Padding = New-Object System.Windows.Thickness 18, 14, 18, 16

    $stack = New-Object System.Windows.Controls.StackPanel

    $header = New-Object System.Windows.Controls.DockPanel
    $header.Background = [System.Windows.Media.Brushes]::Transparent
    $hTitle = New-Object System.Windows.Controls.TextBlock
    $hTitle.Text = '洛洛'
    $hTitle.FontFamily = New-Object System.Windows.Media.FontFamily 'Microsoft YaHei UI'
    $hTitle.FontSize = 15
    $hTitle.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255, 246, 240, 238))
    $hClose = New-Object System.Windows.Controls.Button
    $hClose.Content = '✕'
    $hClose.Width = 24; $hClose.Height = 18
    $hClose.Padding = New-Object System.Windows.Thickness 0
    $hClose.FontSize = 11
    $hClose.Background = [System.Windows.Media.Brushes]::Transparent
    $hClose.BorderThickness = New-Object System.Windows.Thickness 0
    $hClose.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(180, 220, 200, 200))
    $hClose.Cursor = [System.Windows.Input.Cursors]::Hand
    [System.Windows.Controls.DockPanel]::SetDock($hClose, 'Right')
    [void]$header.Children.Add($hClose)
    [void]$header.Children.Add($hTitle)
    [void]$stack.Children.Add($header)

    $script:panelStatus = New-Object System.Windows.Controls.TextBlock
    $script:panelStatus.Text = '检查中…'
    $script:panelStatus.FontFamily = New-Object System.Windows.Media.FontFamily 'Microsoft YaHei UI'
    $script:panelStatus.FontSize = 12
    $script:panelStatus.Margin = New-Object System.Windows.Thickness 0, 10, 0, 12
    $script:panelStatus.TextWrapping = 'Wrap'
    [void]$stack.Children.Add($script:panelStatus)

    $script:panelBtn = New-Object System.Windows.Controls.Button
    $script:panelBtn.Content = '启动'
    $script:panelBtn.HorizontalAlignment = 'Left'
    $script:panelBtn.Padding = New-Object System.Windows.Thickness 18, 6, 18, 6
    $script:panelBtn.FontFamily = New-Object System.Windows.Media.FontFamily 'Microsoft YaHei UI'
    $script:panelBtn.FontSize = 13
    $script:panelBtn.Foreground = [System.Windows.Media.Brushes]::WhiteSmoke
    $script:panelBtn.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255, 42, 40, 50))
    $script:panelBtn.BorderBrush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255, 150, 42, 52))
    $script:panelBtn.BorderThickness = New-Object System.Windows.Thickness 1
    $script:panelBtn.Cursor = [System.Windows.Input.Cursors]::Hand
    [void]$stack.Children.Add($script:panelBtn)

    $hint = New-Object System.Windows.Controls.TextBlock
    $hint.Text = "Ctrl+Alt+L  开 / 关气泡`n关掉这个窗口 = 全部停止"
    $hint.FontFamily = New-Object System.Windows.Media.FontFamily 'Microsoft YaHei UI'
    $hint.FontSize = 11
    $hint.Margin = New-Object System.Windows.Thickness 0, 14, 0, 0
    $hint.LineHeight = 17
    $hint.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(150, 195, 185, 190))
    [void]$stack.Children.Add($hint)

    $border.Child = $stack
    $win.Content = $border

    $drag = { $win.DragMove() }
    $border.Add_MouseLeftButtonDown({ try { $win.DragMove() } catch { } })

    $hClose.Add_Click({
        Stop-Scheduler | Out-Null
        $win.Close()
    })
    $script:panelBtn.Add_Click({
        if (Test-SchedulerRunning) { Stop-Scheduler | Out-Null }
        else { Start-SchedulerHidden; Start-Sleep -Seconds 3 }
        Update-Panel
    })
    $win.Add_Closed({
        Stop-Scheduler | Out-Null
        Remove-Item (Join-Path $DataDir 'panel.pid') -ErrorAction SilentlyContinue
    })

    if (-not (Test-SchedulerRunning)) { Start-SchedulerHidden; Start-Sleep -Seconds 3 }
    Update-Panel

    [void]$win.ShowDialog()
}

# ---------- 入口 ----------
if ($BubbleJson) { Show-BubbleWindow; return }
if ($Hotkey) { Start-HotkeyLoop; return }
Rotate-Log
if ($ForgetNote -gt 0) {
    $m = Get-Memory
    $nlst = @($m.notes)
    if ($ForgetNote -gt $nlst.Count) { "序号超出范围（共 $($nlst.Count) 条）"; return }
    $gone = $nlst[$ForgetNote - 1]
    $nlst = @($nlst | Where-Object { $_ -ne $gone })
    Save-Memory ([pscustomobject]@{
        lastSpoke = $m.lastSpoke; recent = @($m.recent); chat = @($m.chat)
        lastUserAt = $m.lastUserAt; ignored = $m.ignored; mood = $m.mood
        moodValue = $m.moodValue; notes = $nlst
    })
    "已删掉: $gone"
    return
}
if ($AddNote) {
    $m = Get-Memory
    $nlst = @($m.notes) + @($AddNote)
    Save-Memory ([pscustomobject]@{
        lastSpoke = $m.lastSpoke; recent = @($m.recent); chat = @($m.chat)
        lastUserAt = $m.lastUserAt; ignored = $m.ignored; mood = $m.mood
        moodValue = $m.moodValue; notes = $nlst
    })
    "已记住: $AddNote"
    return
}
if ($Notes) {
    $m = Get-Memory
    if (-not $m -or -not $m.notes -or @($m.notes).Count -eq 0) { "（她还没有长期记忆）"; return }
    $i = 0
    foreach ($n in @($m.notes)) { $i++; "{0,2}. {1}" -f $i, $n }
    return
}
if ($Memory) {
    $m = Get-Memory
    if (-not $m -or -not $m.chat) { "（还没有记忆）"; return }
    $i = 0
    foreach ($c in @($m.chat)) {
        $i++
        $who = if ($c.who -eq 'me') { '皮屑' } else { '洛洛' }
        "{0,3}  {1}  {2}: {3}" -f $i, ([datetime]$c.t).ToString('MM-dd HH:mm'), $who, $c.text
    }
    "共 " + $i + " 条。删某条: -Forget 序号   删最近 N 条: -ForgetLast N"
    return
}
if ($Forget -gt 0) {
    $m = Get-Memory
    $chat = @($m.chat)
    if ($Forget -gt $chat.Count) { "序号超出范围（共 $($chat.Count) 条）"; return }
    $target = $chat[$Forget - 1]
    $chat = @($chat[0..($Forget - 2)]) + @($chat[$Forget..($chat.Count - 1)])
    Save-Memory ([pscustomobject]@{
        lastSpoke = $m.lastSpoke; recent = @($m.recent); chat = @($chat)
        lastUserAt = $m.lastUserAt; ignored = $m.ignored; mood = $m.mood; moodValue = $m.moodValue; notes = @($m.notes)
    })
    "已删除第 $Forget 条: " + $target.text
    return
}
if ($ForgetLast -gt 0) {
    $m = Get-Memory
    $chat = @($m.chat)
    if ($ForgetLast -gt $chat.Count) { $ForgetLast = $chat.Count }
    $keep = @($chat[0..($chat.Count - $ForgetLast - 1)])
    if ($chat.Count - $ForgetLast -le 0) { $keep = @() }
    Save-Memory ([pscustomobject]@{
        lastSpoke = $m.lastSpoke; recent = @($m.recent); chat = @($keep)
        lastUserAt = $m.lastUserAt; ignored = $m.ignored; mood = $m.mood; moodValue = $m.moodValue; notes = @($m.notes)
    })
    "已删除最近 $ForgetLast 条，剩 $($keep.Count) 条"
    return
}
if ($RemoveAlarm -gt 0) {
    $AlarmPath = Join-Path $DataDir 'alarms.json'
    if (-not (Test-Path $AlarmPath)) { "（还没有闹钟）"; return }
    $d = Get-Content $AlarmPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $all = @()
    foreach ($x in $d) { $all += $x }
    if ($RemoveAlarm -gt $all.Count) { "序号超出范围（共 $($all.Count) 个）"; return }
    $gone = $all[$RemoveAlarm - 1]
    $keep = @()
    for ($i = 0; $i -lt $all.Count; $i++) { if ($i -ne ($RemoveAlarm - 1)) { $keep += $all[$i] } }
    Set-Content -Path $AlarmPath -Value (ConvertTo-Json -InputObject @($keep) -Depth 5) -Encoding UTF8
    "已删除: $($gone.time)  $($gone.text)"
    return
}
if ($AddAlarm) {
    $AlarmPath = Join-Path $DataDir 'alarms.json'
    $list = New-Object System.Collections.ArrayList
    if (Test-Path $AlarmPath) {
        try {
            $d = Get-Content $AlarmPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($x in @($d)) { [void]$list.Add($x) }
        } catch { }
    }
    $t = [string]$AddAlarm
    if ($t -match '^(\d{1,2})$') { $t = '{0:00}:00' -f [int]$matches[1] }
    elseif ($t -match '^(\d{1,2}):(\d{1,2})$') { $t = '{0:00}:{1:00}' -f [int]$matches[1], [int]$matches[2] }
    [void]$list.Add([pscustomobject]@{ time = $t; text = $AlarmText; fired = $false; daily = [bool]$Daily; lastFired = '' })
    $json = ConvertTo-Json -InputObject @($list.ToArray()) -Depth 5
    Set-Content -Path $AlarmPath -Value $json -Encoding UTF8
    "已设闹钟: $t  $AlarmText"
    return
}
if ($Alarms) {
    $AlarmPath = Join-Path $DataDir 'alarms.json'
    if (-not (Test-Path $AlarmPath)) { "（还没有闹钟）"; return }
    $d = Get-Content $AlarmPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $list = @()
    foreach ($x in @($d)) { $list += $x }
    if ($list.Count -eq 0) { "（还没有闹钟）"; return }
    $i2 = 0
    foreach ($a in $list) {
        $i2++
        "{0,2}. {1}  {2}{3}  {4}" -f $i2, $a.time, $(if ($a.fired) { '已响' } else { '待响' }), $(if ($a.daily) { ' 每天' } else { '' }), $a.text
    }
    return
}if ($YejinChat) {
    $yjDir = Join-Path $PSScriptRoot 'data\yejin'
    New-Item -ItemType Directory -Force $yjDir | Out-Null
    $yjPersona = if ($cfgUser -and $cfgUser.yejinPrompt) { [string]$cfgUser.yejinPrompt } else { '' }
    if (-not (Test-Path $yjPersona)) { "找不到夜烬的人设文件: $yjPersona"; return }
    $yjBubble = Join-Path $yjDir 'bubble.json'
    $yjHist = @()
    try {
        $yjMem = Join-Path $yjDir 'memory.json'
        if (Test-Path $yjMem) {
            $ym = Get-Content $yjMem -Raw -Encoding UTF8 | ConvertFrom-Json
            $yjHist = @($ym.chat | Select-Object -Last 6 | ForEach-Object { @{ who = [string]$_.who; text = [string]$_.text } })
        }
    } catch { }
    $json = @{ text = ''; open = $true; history = $yjHist } | ConvertTo-Json -Depth 4 -Compress
    [IO.File]::WriteAllText($yjBubble, $json, (New-Object System.Text.UTF8Encoding($false)))
    try { Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -and $_.CommandLine -match '-BubbleJson' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } } catch { }
    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',"`"$PSCommandPath`"",'-BubbleJson',"`"$yjBubble`"",'-PersonaFile',"`"$yjPersona`"",'-DataDirX',"`"$yjDir`"")
    Start-Process powershell.exe -ArgumentList $argList -WindowStyle Hidden | Out-Null
    "夜烬窗口已打开"
    return
}if ($History -gt 0) {
    $mem = Get-Memory
    if (-not $mem -or -not $mem.chat) { "（还没有气泡聊天记录）"; return }
    $items = @($mem.chat | Select-Object -Last $History)
    foreach ($it in $items) {
        $who = if ($it.who -eq 'me') { '皮屑' } else { '克劳洛娅' }
        "{0}  {1}: {2}" -f ([datetime]$it.t).ToString('MM-dd HH:mm'), $who, $it.text
    }
    return
}
if ($Say) {
    $mem = Get-Memory
    $nowIso = (Get-Date).ToString('o')
    $newChat = @($mem.chat | Where-Object { $_ }) + @([pscustomobject]@{ t = $nowIso; who = 'her'; text = $Say }) | Select-Object -Last 40
    Save-Memory ([pscustomobject]@{ lastSpoke = $nowIso; recent = @($mem.recent); chat = $newChat })
    Show-Bubble $Say -OpenChat

    Write-Log "注入: $Say"
    return
}
if ($OpenChat) { [void](Open-ChatBubble); return }
if ($Install) { Install-Startup; return }
if ($Uninstall) {
    $lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'LuoluoProactive.lnk'
    if (Test-Path $lnk) { Remove-Item $lnk -Force; '已取消开机自启' } else { '没有找到自启项' }
    Stop-Scheduler
    return
}
if ($Stop) { Stop-Scheduler; return }
if ($StopProactive) { Stop-ProactiveOnly; return }
if ($Usage) {
    $up = Join-Path $DataDir 'usage.json'
    if (-not (Test-Path $up)) { "（还没有用量记录）"; return }
    $u = Get-Content $up -Raw -Encoding UTF8 | ConvertFrom-Json
    $inAll = [long]$u.inMiss + [long]$u.inHit
    "日期    : " + $u.day
    "调用    : " + $u.calls + " 次"
    "输入    : " + $inAll + " tokens (缓存命中 " + $u.inHit + " / 未命中 " + $u.inMiss + ")"
    "输出    : " + $u.out + " tokens"
    "合计    : " + ($inAll + [long]$u.out) + " tokens"
    "估算花费: 约 ¥" + ([double]$u.cost).ToString('0.0000')
    $hp = Join-Path $DataDir 'usage-history.json'
    if (Test-Path $hp) {
        $histRaw = Get-Content $hp -Raw -Encoding UTF8 | ConvertFrom-Json; $h = @(); foreach ($hh in @($histRaw)) { if ($hh -and $hh.day) { $h += $hh } }
        ""
        "历史:"
        $h | Select-Object -Last 7 | ForEach-Object { "  " + $_.day + "  " + $_.calls + " 次  ¥" + ([double]$_.cost).ToString('0.0000') }
    }
    return
}
if ($Summarize) {
    Update-Notes (Get-Memory) -Force
    if ($m -and $m.notes) { "已更新:"; @($m.notes) | ForEach-Object { "- $_" } } else { "没生成出新记忆" }
    return
}
if ($Panel) { Show-Panel; return }
if ($Once) { Invoke-Proactive -Called:$Called; return }
if ($DryRun) { 1..4 | ForEach-Object { Invoke-Proactive -NoBubble -NoMemory -Called:$Called }; return }

if ($SayAs) {
    try {
        @{ text = $SayAs } | ConvertTo-Json -Compress | Set-Content (Join-Path $DataDir 'pending.json') -Encoding UTF8
        $bub = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -and $_.CommandLine -match '-BubbleJson' })
        foreach ($b in $bub) { Stop-Process -Id $b.ProcessId -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Milliseconds 600
        Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',"`"$PSCommandPath`"",'-OpenChat') -WindowStyle Hidden | Out-Null
        "已注入: $SayAs"
    } catch { "注入失败: " + $_.Exception.Message }
    return
}

# 单实例：用互斥量，避免看门狗和手动启动撞车
$script:singleMutex = $null
try {
    $script:singleMutex = New-Object System.Threading.Mutex($false, 'Local\LuoluoProactiveScheduler')
    if (-not $script:singleMutex.WaitOne(0)) {
        Write-Log "已有调度器在跑，退出本次启动"
        return
    }
} catch {
    try {
        $script:singleMutex = New-Object System.Threading.Mutex($false, 'Local\LuoluoProactiveScheduler')
        [void]$script:singleMutex.WaitOne(0)
    } catch { }
}
try {
    $mm = Get-Memory
    if ($mm -and $mm.lastUserAt) {
        $gap = (New-TimeSpan -Start ([datetime]$mm.lastUserAt) -End (Get-Date)).TotalMinutes
        if ($gap -gt 90) {
            Save-Memory ([pscustomobject]@{
                lastSpoke = $mm.lastSpoke; recent = @($mm.recent); chat = @($mm.chat)
                lastUserAt = (Get-Date).ToString('o'); ignored = 0; mood = ''; moodValue = $mm.moodValue; notes = @($mm.notes)
            })
            Write-Log "离开 $([int]$gap) 分钟,已重置情绪"
        }
    }
} catch { }
if (Test-Path $PauseFlag) { Remove-Item $PauseFlag -Force -ErrorAction SilentlyContinue }
$PID | Set-Content -Path $PidPath -Encoding ASCII
Start-SubtitleWatcher
# Start-HotkeyWatcher  # 已停用热键
    $everyText = if ($IntervalSec -gt 0) { "$IntervalSec 秒" } else { "$IntervalMinutes 分钟" }
    Write-Log "调度器启动 (PID $PID, 每 $everyText 一句, 静默 $QuietStart-$QuietEnd)"

$AlarmPath = Join-Path $DataDir 'alarms.json'

function Get-AlarmList {
    $list = @()
    if (Test-Path $AlarmPath) {
        try {
            $data = Get-Content $AlarmPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($data -is [System.Array]) { $list = @($data) } elseif ($null -ne $data) { $list = @($data) }
        } catch { }
    }
    return ,$list
}

function Save-Alarms($list) {
    try { ($list | ConvertTo-Json -Depth 5) | Set-Content $AlarmPath -Encoding UTF8 } catch { }
}


function Invoke-Alarm($alarm) {
    $text = [string]$alarm.text
    if ([string]::IsNullOrWhiteSpace($text)) { $text = '时间到了' }
    try {
        $persona = Get-Persona
        $sys = "$persona`n`n【现在】`n现在是 $((Get-Date).ToString('yyyy年M月d日 dddd HH:mm'))。`n【提醒任务】`n你替麻麻记着一个闹钟,现在到点了。用你的语气提醒她一句,必须带上她写的内容:「$text」。`n- 一句话,不超过 30 字`n- 直接说事,不要解释、不要重复「闹钟」这个词两次"
        $line = Invoke-LLM -system $sys -user '提醒她。' -maxTokens 700 -temp 0.8
        $line = ($line -replace '^["“”]|["“”]$', '').Trim()
        $line = Remove-Period $line
        if ([string]::IsNullOrWhiteSpace($line)) { $line = "到点了。$text" }
    } catch { $line = "到点了。$text" }
    Write-Log ("闹钟: $text")
    Show-Bubble $line -OpenChat
}

$firstDelay = if ($IntervalSec -gt 0) { $IntervalSec } else { $IntervalMinutes * 60 }
$nextSpeakAt = (Get-Date).AddSeconds($firstDelay)
$lastAlarmCheck = ''

while ($true) {
    $tick = if ($IntervalSec -gt 0) { [Math]::Min($IntervalSec, 5) } else { 15 }
    Start-Sleep -Seconds $tick
    $now = Get-Date

    # 到点的闹钟
    $pend = @()
    if (Test-Path $AlarmPath) {
        try {
            $adata = Get-Content $AlarmPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -ne $adata) { $pend = @($adata) }
        } catch { }
    }
    $changed = $false
    foreach ($al in $pend) {
        if ($al.fired -and -not $al.daily) { continue }
        $dpart = if ($al.date) { [string]$al.date } else { $now.ToString('yyyy-MM-dd') }
        $dueText = $dpart + ' ' + [string]$al.time
        $due = $null
        try { $due = [datetime]::ParseExact($dueText, 'yyyy-MM-dd HH:mm', $null) } catch { continue }

        if ($al.daily) {
            $today = $now.ToString('yyyy-MM-dd')
            if ($now -ge $due -and ([string]$al.lastFired -ne $today) -and (($now - $due).TotalMinutes -lt 60)) {
                $al.lastFired = $today
                $al.fired = $false
                $changed = $true
                try { Invoke-Alarm $al } catch { Write-Log ("闹钟失败: " + $_.Exception.Message) }
            }
        }
        elseif ($now -ge $due) {
            $al.fired = $true
            $changed = $true
            try { Invoke-Alarm $al } catch { Write-Log ("闹钟失败: " + $_.Exception.Message) }
        }
    }
    if ($changed) { try { ($pend | ConvertTo-Json -Depth 5) | Set-Content $AlarmPath -Encoding UTF8 } catch { } }

    # 夜烬心情随时间掉（他不主动找人，但会被晾着）
    if (-not $script:lastYjCheck) { $script:lastYjCheck = Get-Date }
    if (((Get-Date) - $script:lastYjCheck).TotalMinutes -ge 5) {
        $script:lastYjCheck = Get-Date
        try {
            $yjMemPath = Join-Path $PSScriptRoot 'data\yejin\memory.json'
            if (Test-Path $yjMemPath) {
                $ym = Get-Content $yjMemPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $idleM = 999
                if ($ym.lastUserAt) { $idleM = ((Get-Date) - [datetime]$ym.lastUserAt).TotalMinutes }
                if ($idleM -gt 20) {
                    $mv = 70
                    if ($null -ne $ym.moodValue) { $mv = [int]$ym.moodValue }
                    $drop = 1
                    if ($idleM -gt 180) { $drop = 2 } elseif ($idleM -gt 60) { $drop = 1 }
                    $mv = [Math]::Max(10, $mv - $drop)
                    $ym.moodValue = $mv
                    $ym | ConvertTo-Json -Depth 6 | Set-Content $yjMemPath -Encoding UTF8
                }
            }
        } catch { }
    }

    # 主动说话
    if ($now -ge $nextSpeakAt) {
        $silentMin2 = 999
        try {
            $mmj = Get-Content (Join-Path $DataDir 'memory.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($mmj.lastUserAt) { $silentMin2 = (New-TimeSpan -Start ([datetime]$mmj.lastUserAt) -End $now).TotalMinutes }
        } catch { }
        $iv = if ($IntervalSec -gt 0) { $IntervalSec / 60.0 } elseif ($silentMin2 -gt 180) { 30 } elseif ($silentMin2 -gt 90) { 10 } else { $IntervalMinutes }
        $nextSpeakAt = $now.AddMinutes($iv)
        if (Test-QuietHours $QuietStart $QuietEnd) { continue }
        if (-not $NoGame -and -not (Get-Process MateEngineX -ErrorAction SilentlyContinue)) { continue }
        $luoOpen = [bool](Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -and $_.CommandLine -match '-BubbleJson' -and $_.CommandLine -notmatch '-PersonaFile' })
        if ($luoOpen) { continue }
        $yjOpen = $false
        try { if ($LogOnly) { Invoke-Proactive -NoBubble } else { Invoke-Proactive } } catch { Write-Log ("生成失败: " + $_.Exception.Message) }
    }
}
