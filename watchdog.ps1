# 洛洛看门狗：调度器挂了就拉起来
$ErrorActionPreference = 'SilentlyContinue'
$root = $PSScriptRoot
$script = Join-Path $root 'luoluo-proactive.ps1'
$data = Join-Path $root 'data'
$pidPath = Join-Path $data 'scheduler.pid'
$selfPid = Join-Path $data 'watchdog.pid'
$log = Join-Path $data 'watchdog.log'
$pauseFlag = Join-Path $data 'paused.flag'

function WLog($m) {
    try { Add-Content -Path $log -Value ("[{0}] {1}" -f (Get-Date -Format 'MM-dd HH:mm:ss'), $m) -Encoding UTF8 } catch { }
}

# 单实例（互斥量）
$wdMutex = $null
try {
    $wdMutex = New-Object System.Threading.Mutex($false, 'Local\LuoluoWatchdog')
    if (-not $wdMutex.WaitOne(0)) { return }
} catch { }
$PID | Set-Content -Path $selfPid -Encoding ASCII
WLog "看门狗启动 (PID $PID)"

while ($true) {
    Start-Sleep -Seconds 30
    if (Test-Path $pauseFlag) { continue }
    $alive = $false
    if (Test-Path $pidPath) {
        try {
            $sp = (Get-Content $pidPath -Raw).Trim()
            if ($sp -and (Get-Process -Id ([int]$sp) -ErrorAction SilentlyContinue)) { $alive = $true }
        } catch { }
    }
    if (-not $alive) {
        WLog "调度器不在了，重新拉起"
        $extra = @()
        $argFile = Join-Path $data 'scheduler.args.txt'
        if (Test-Path $argFile) {
            try { $extra = @(Get-Content $argFile -Encoding UTF8 | Where-Object { $_.Trim() }) } catch { }
        }
        $allArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',$script) + $extra
        Start-Process powershell.exe -ArgumentList $allArgs -WindowStyle Hidden
        Start-Sleep -Seconds 6
    }
}
