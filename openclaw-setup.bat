@echo off
:: ============================================================
::  OpenClaw 環境偵測 & 自動安裝程式
::  版本: 2.0.0
::  說明: 偵測系統環境並自動安裝 OpenClaw 所需的所有依賴
::        雙擊執行即可，建議以系統管理員身份執行
:: ============================================================

setlocal

:: ── 取得腳本所在目錄（支援有空格的路徑）──────────────────
set "SCRIPT_DIR=%~dp0"
set "PS1_FILE=%SCRIPT_DIR%openclaw-setup.ps1"

:: ── 確認 .ps1 檔案存在 ───────────────────────────────────
if not exist "%PS1_FILE%" (
    echo.
    echo [ERROR] 找不到 openclaw-setup.ps1
    echo         請確認此 .bat 與 .ps1 在同一個資料夾內
    echo         路徑: %PS1_FILE%
    echo.
    pause
    exit /b 1
)

:: ── 嘗試以管理員身份重新啟動（若尚未取得權限）──────────
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo.
    echo  建議以系統管理員身份執行以取得完整安裝功能
    echo  正在嘗試提升權限...
    echo.
    :: 使用 PowerShell 觸發 UAC 提升
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
        "Start-Process cmd.exe -ArgumentList '/c \"\"%~f0\"\"' -Verb RunAs" >nul 2>&1
    if %errorLevel% equ 0 (
        exit /b 0
    )
    :: 若提升失敗（使用者拒絕 UAC），仍繼續以一般權限執行
    echo  提升失敗或已拒絕，以一般使用者權限繼續執行...
    echo  部分功能（如啟用 WSL2）可能無法完成
    echo.
)

:: ── 執行 PowerShell 主腳本 ───────────────────────────────
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1_FILE%"

set EXIT_CODE=%errorLevel%

:: ── 若 PowerShell 異常退出則顯示錯誤 ────────────────────
if %EXIT_CODE% neq 0 (
    echo.
    echo [ERROR] 腳本異常退出，錯誤碼: %EXIT_CODE%
    echo         請截圖此畫面並回報問題
    pause
)

endlocal
exit /b %EXIT_CODE%
