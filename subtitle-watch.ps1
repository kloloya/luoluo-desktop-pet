# 字幕助手：每 3 秒读一次 B站窗口底部字幕，写进 data\subtitle.json
$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot
$outFile = Join-Path $root 'data\subtitle.json'

Add-Type -AssemblyName System.Runtime.WindowsRuntime, System.Drawing

Add-Type @"
using System; using System.Runtime.InteropServices;
public class DPIA { [DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); }
"@
[void][DPIA]::SetProcessDPIAware()
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
public class SUBW {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(IntPtr h, out int pid);
  public struct RECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  public static int ForegroundPid() { int pid; GetWindowThreadProcessId(GetForegroundWindow(), out pid); return pid; }
  public static string Find(int[] pids){
    string res = null; int best = 0;
    EnumWindows((h,l)=>{ if(!IsWindowVisible(h)) return true; int pid; GetWindowThreadProcessId(h,out pid); if(Array.IndexOf(pids,pid)>=0){ RECT r; GetWindowRect(h,out r); int w=r.Right-r.Left, hh=r.Bottom-r.Top; if(w>600 && hh>400 && w*hh>best){ best=w*hh; res=r.Left+","+r.Top+","+w+","+hh; } } return true; }, IntPtr.Zero);
    return res;
  }
}
"@

$lastText = ''
while ($true) {
    try {
        # 只有 B站 在前台才抓，其他时候空转不截图
        $fg = [SUBW]::ForegroundPid()
        $fgName = ''
        if ($fg -gt 0) { $fgName = (Get-Process -Id $fg -ErrorAction SilentlyContinue).ProcessName }
        if ($fgName -notmatch '哔哩|bilibili') { Start-Sleep -Milliseconds 3000; continue }
        $pids = @(Get-Process | Where-Object { $_.ProcessName -match '哔哩|bilibili' } | Select-Object -ExpandProperty Id)
        if ($pids.Count -gt 0) {
            $rect = [SUBW]::Find($pids)
            if ($rect) {
                $p = $rect -split ','
                $x = [int]$p[0]; $y0 = [int]$p[1]; $w = [int]$p[2]; $h = [int]$p[3]
                # 字幕区：窗口高度的 74% ~ 90%，宽度中间 76%
                $top = $y0 + [int]($h * 0.855)
                $band = [int]($h * 0.105)
                $cw = [int]($w * 0.55)
                $cx = $x + [int](($w - $cw) / 2)
                $bmp = New-Object System.Drawing.Bitmap $cw, $band
                $g = [System.Drawing.Graphics]::FromImage($bmp)
                $g.CopyFromScreen($cx, $top, 0, 0, (New-Object System.Drawing.Size $cw, $band))
                $g.Dispose()
                $big = New-Object System.Drawing.Bitmap ($cw * 2), ($band * 2)
                $g2 = [System.Drawing.Graphics]::FromImage($big)
                $g2.InterpolationMode = 'HighQualityBicubic'
                $g2.DrawImage($bmp, 0, 0, $cw * 2, $band * 2)
                $g2.Dispose(); $bmp.Dispose()
                $tmp = Join-Path $env:TEMP 'subwatch.png'
                $big.Save($tmp, [System.Drawing.Imaging.ImageFormat]::Png); $big.Dispose()

                $f = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($tmp)) ([Windows.Storage.StorageFile])
                $s = Await ($f.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
                $d = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($s)) ([Windows.Graphics.Imaging.BitmapDecoder])
                $bm = Await ($d.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
                $r = Await ($eng.RecognizeAsync($bm)) ([Windows.Media.Ocr.OcrResult])

                $cands = @($r.Lines | ForEach-Object { ($_.Text -replace "\s+", "") } | Where-Object {
                $cands = @($r.Lines | ForEach-Object { ($_.Text -replace "\s+", "") } | Where-Object { $_.Length -ge 3 -and $_.Length -le 40 })
                })
                if ($cands.Count -gt 0) {
                    $line = ($cands | Sort-Object Length -Descending)[0]
                    if ($line -ne $lastText) {
                        $lastText = $line
                        @{ text = $line; at = (Get-Date).ToString('o') } | ConvertTo-Json -Compress | Set-Content $outFile -Encoding UTF8
                    }
                }
            }
        }
    } catch { }
    Start-Sleep -Milliseconds 3000
}
