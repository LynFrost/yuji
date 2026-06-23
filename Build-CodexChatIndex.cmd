@echo off
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0Build-CodexChatIndex.ps1" -DataRoot "%~dp0..\运行数据" %*
