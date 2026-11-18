# 洛洛面板（无 exe：UI 在内存里编译，走 PowerShell 宿主，避免应用控制策略拦截）
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class AUMX {
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    public static extern int SetCurrentProcessExplicitAppUserModelID(string id);
}
"@
[void][AUMX]::SetCurrentProcessExplicitAppUserModelID('Shinymoon.Luoluo.Panel')

$code = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'LuoluoPanel3.cs'), [Text.Encoding]::UTF8)
Add-Type -TypeDefinition $code -ReferencedAssemblies System.Windows.Forms, System.Drawing, System.dll -Language CSharp

$mutex = New-Object System.Threading.Mutex($false, 'LuoluoPanelSingle')
$owned = $false
try { $owned = $mutex.WaitOne(0) }
catch [System.Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) { exit }

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)
$form = New-Object LuoluoPanel
[System.Windows.Forms.Application]::Run($form)
