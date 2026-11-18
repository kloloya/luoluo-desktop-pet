# QQ 消息区 OCR：QQ 在前台时，读中间消息区最近几行，写 data\im.json
$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot
$outFile = Join-Path $root 'data\im.json'

Add-Type -AssemblyName System.Runtime.WindowsRuntime, System.Drawing
Add-Type @"
using System; using System.Runtime.InteropServices;
public class IMDPI { [DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); }
"@
[void][IMDPI]::SetProcessDPIAware()

$asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
})[0]
function Await($op, [Type]$t) {
    $task = $asTask.MakeGenericMethod($t).Invoke($null, @($op))
    [void]$task.Wait(-1)
    $task.Result
}
[Windows.Storage.StorageFile, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null
[Windows.Graphics.Imaging.BitmapDecoder, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null
[Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null
[Windows.Globalization.Language, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null
$eng = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage((New-Object Windows.Globalization.Language 'zh-Hans-CN'))

Add-Type @"
using System; using System.Text; using System.Runtime.InteropServices;
public class IMW {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(IntPtr h, out int pid);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  public struct RECT { public int Left, Top, Right, Bottom; }
  public static int ForegroundPid() { int pid; GetWindowThreadProcessId(GetForegroundWindow(), out pid); return pid; }
  public static string Find(int[] pids){
    string res = null; int best = 0;
    EnumWindows((h,l)=>{ if(!IsWindowVisible(h)) return true; int pid; GetWindowThreadProcessId(h,out pid); if(Array.IndexOf(pids,pid)>=0){ RECT r; GetWindowRect(h,out r); int w=r.Right-r.Left, hh=r.Bottom-r.Top; if(w>700 && hh>500 && w*hh>best){ best=w*hh; res=r.Left+","+r.Top+","+w+","+hh; } } return true; }, IntPtr.Zero);
    return res;
  }
}
"@

$last = ''
while ($true) {
    try {
        $fg = [IMW]::ForegroundPid()
        $fgName = ''
        if ($fg -gt 0) { $fgName = (Get-Process -Id $fg -ErrorAction SilentlyContinue).ProcessName }
        if ($fgName -notmatch '^QQ$|^qq$|WeChat|Weixin') { Start-Sleep -Milliseconds 3000; continue }

        $pids = @(Get-Process | Where-Object { $_.ProcessName -match '^QQ$|^WeChat$|^Weixin$' } | Select-Object -ExpandProperty Id)
        if ($pids.Count -gt 0) {
            $rect = [IMW]::Find($pids)
            if ($rect) {
                $p = $rect -split ','
                $x = [int]$p[0]; $y0 = [int]$p[1]; $w = [int]$p[2]; $h = [int]$p[3]
                # 消息区：左 15.5%~86%，上 5.5%~79%
                $cx = $x + [int]($w * 0.155)
                $cy = $y0 + [int]($h * 0.055)
                $cw = [int]($w * 0.705)
                $ch = [int]($h * 0.735)
                $bmp = New-Object System.Drawing.Bitmap $cw, $ch
                $g = [System.Drawing.Graphics]::FromImage($bmp)
                $g.CopyFromScreen($cx, $cy, 0, 0, (New-Object System.Drawing.Size $cw, $ch))
                $g.Dispose()
                $big = New-Object System.Drawing.Bitmap ($cw * 2), ($ch * 2)
                $g2 = [System.Drawing.Graphics]::FromImage($big)
                $g2.InterpolationMode = 'HighQualityBicubic'
                $g2.DrawImage($bmp, 0, 0, $cw * 2, $ch * 2)
                $g2.Dispose(); $bmp.Dispose()
                $tmp = Join-Path $env:TEMP 'imwatch.png'
                $big.Save($tmp, [System.Drawing.Imaging.ImageFormat]::Png); $big.Dispose()

                $f = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($tmp)) ([Windows.Storage.StorageFile])
                $s = Await ($f.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
                $d = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($s)) ([Windows.Graphics.Imaging.BitmapDecoder])
                $bm = Await ($d.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
                $r = Await ($eng.RecognizeAsync($bm)) ([Windows.Media.Ocr.OcrResult])

                # 排除她自己气泡里的话（气泡是置顶窗口，会挡住 QQ）
                $herLines = @()
                try {
                    $lg = Join-Path $root 'data\log.txt'
                    if (Test-Path $lg) {
                        $herLines = @(Get-Content $lg -Encoding UTF8 -Tail 40 | Where-Object { $_ -match '说了: ' } | ForEach-Object { (($_ -split '说了: ')[1]).Trim() })
                    }
                } catch { }

                $lines = @($r.Lines | ForEach-Object { ($_.Text -replace '\s+', '').Trim() } | Where-Object {
                    $_.Length -ge 2 -and $_.Length -le 40 -and $_ -notmatch 'LV' -and $_ -notmatch '发现对面' -and $_ -notmatch '^\d{3,}$' -and $_ -notmatch '^[0-9:]+$' -and $_ -notmatch '^[（(]\d+[)）]$'
                })
                if ($lines.Count -gt 0) {
                    $take = @($lines | Select-Object -Last 4)
                    $joined = $take -join ' / '
                    if ($joined -ne $last) {
                        $last = $joined
                        @{ lines = $take; at = (Get-Date).ToString('o') } | ConvertTo-Json -Compress | Set-Content $outFile -Encoding UTF8
                    }
                }
            }
        }
    } catch { }
    Start-Sleep -Milliseconds 4000
}
