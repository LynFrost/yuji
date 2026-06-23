@echo off
title Open-CodexChatIndex V0.23 - Local Server Running
set "CODEX_CHAT_INDEX_DIR=%~dp0"
python -c "import os; from pathlib import Path; root = Path(os.environ['CODEX_CHAT_INDEX_DIR']); [p.mkdir(parents=True, exist_ok=True) for p in (root / 'temp', root.parent / '\u8fd0\u884c\u6570\u636e', root.parent / '\u5916\u90e8\u804a\u5929\u8bb0\u5f55')]"
if errorlevel 1 (
  echo.
  echo Open-CodexChatIndex failed to prepare directories.
  echo Keep this window open for troubleshooting details.
  pause
  exit /b 1
)
python "%~dp0CodexChatIndexServer.py" --open
if errorlevel 1 (
  echo.
  echo Open-CodexChatIndex failed to start.
  echo Keep this window open for troubleshooting details.
  pause
)

