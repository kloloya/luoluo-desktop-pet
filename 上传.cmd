@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo === 洛洛 · 上传到 GitHub ===
echo.
git add -A
echo.
set /p msg=这次改了什么（直接回车用默认）： 
if "%msg%"=="" set msg=更新
git commit -m "%msg%"
echo.
echo 正在推送...
git push
echo.
echo 完成。按任意键关闭。
pause >nul
