#Requires -Version 5.1
<#
.SYNOPSIS
    OpenClaw 環境偵測與自動安裝腳本
.DESCRIPTION
    偵測 PC 系統設定與依賴，自動安裝缺少的元件，
    並完成 OpenClaw 在 WSL2 Ubuntu 內的初始設定。
.NOTES
    版本: 2.0.0
    需要: Windows 10 Build 19041+ / Windows 11
    建議: 以系統管理員身份執行
#>

# ── 編碼設定 ──────────────────────────────────────────────
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# ── 顏色輔助函數 ───────────────────────────────────────────
function Write-OK    { param($msg) Write-Host "  [OK]   $msg" -ForegroundColor Green }
function Write-WARN  { param($msg) Write-Host "  [WARN] $msg" -ForegroundColor Yellow }
function Write-FAIL  { param($msg) Write-Host "  [FAIL] $msg" -ForegroundColor Red }
function Write-INFO  { param($msg) Write-Host "  [INFO] $msg" -ForegroundColor Cyan }
function Write-STEP  { param($n, $msg) Write-Host "`n[STEP $n] $msg" -ForegroundColor White }
function Write-LINE  { Write-Host ("─" * 60) -ForegroundColor DarkGray }

# ── 全域狀態 ───────────────────────────────────────────────
$script:Errors   = 0
$script:Warnings = 0
$script:Results  = @{}

# ── 腳本路徑（相容直接執行和 -File 兩種方式）──────────────
$script:ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else {
    try { Split-Path -Parent $MyInvocation.MyCommand.Path } catch { $null }
}
if (-not $script:ScriptDir) { $script:ScriptDir = $PWD.Path }

function Add-Result { param($key, $value) $script:Results[$key] = $value }

# ── winget 安裝輔助 ────────────────────────────────────────
function Install-WithWinget {
    param($Id, $Name)
    Write-INFO "正在透過 winget 安裝 $Name ..."
    winget install --id $Id -e --source winget `
        --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
}

# ── 刷新 PATH ──────────────────────────────────────────────
function Update-Path {
    $machinePath = [System.Environment]::GetEnvironmentVariable("PATH", "Machine")
    $userPath    = [System.Environment]::GetEnvironmentVariable("PATH", "User")
    $env:PATH = "$machinePath;$userPath"
}

# ── 啟動時先刷新 PATH，確保 winget 安裝過的程式可被找到 ────
Update-Path

# ============================================================
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "   OpenClaw 環境偵測 & 自動安裝程式 v2.0" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

# ============================================================
# STEP 1: 系統資訊
# ============================================================
Write-STEP 1 "收集系統資訊..."
Write-LINE

$os    = Get-CimInstance Win32_OperatingSystem
$cpu   = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name
$ramGB = [math]::Round($os.TotalVisibleMemorySize / 1MB)
$build = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuildNumber

Write-Host "  作業系統 : $($os.Caption)"
Write-Host "  CPU      : $cpu"
Write-Host "  記憶體   : $ramGB GB"
Write-Host "  Build    : $build"

if ($build -ge 19041) {
    Write-OK "Windows Build $build >= 19041 (支援 WSL2)"
    Add-Result "WindowsOK" $true
} else {
    Write-FAIL "Windows Build $build 過舊，需要 Build 19041+ 才支援 WSL2"
    $script:Errors++
    Add-Result "WindowsOK" $false
}

# ============================================================
# STEP 2: 管理員權限
# ============================================================
Write-STEP 2 "檢查執行權限..."
Write-LINE

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if ($isAdmin) {
    Write-OK "以管理員身份執行"
    Add-Result "IsAdmin" $true
} else {
    Write-WARN "未以管理員身份執行"
    Write-INFO "部分安裝步驟（WSL2 啟用）需要管理員權限"
    Write-INFO "建議：右鍵 openclaw-setup.bat > 以系統管理員身份執行"
    $script:Warnings++
    Add-Result "IsAdmin" $false
}

# ============================================================
# STEP 3: Winget
# ============================================================
Write-STEP 3 "檢查 Winget 套件管理器..."
Write-LINE

try {
    $wingetVer = (winget --version 2>&1).ToString().Trim()
    Write-OK "Winget $wingetVer 已安裝"
    Add-Result "HasWinget" $true
} catch {
    Write-WARN "Winget 未找到，部分自動安裝將跳過"
    Write-INFO "請至 Microsoft Store 安裝 'App Installer'"
    $script:Warnings++
    Add-Result "HasWinget" $false
}

# ============================================================
# STEP 4: Git (Windows)
# ============================================================
Write-STEP 4 "檢查 Git..."
Write-LINE

$gitOk = $false
try {
    $gitVer = (git --version 2>&1).ToString().Trim()
    Write-OK "$gitVer 已安裝"
    $gitOk = $true
} catch {}

if (-not $gitOk) {
    Write-WARN "Git 未安裝，正在安裝..."
    if ($script:Results["HasWinget"]) {
        Install-WithWinget "Git.Git" "Git"
        Update-Path
        try {
            $gitVer = (git --version 2>&1).ToString().Trim()
            Write-OK "Git 安裝成功: $gitVer"
            $gitOk = $true
        } catch {
            Write-FAIL "Git 安裝後未偵測到，請重新開啟命令列"
            Write-INFO "或手動下載: https://git-scm.com/download/win"
            $script:Errors++
        }
    } else {
        Write-FAIL "請手動安裝 Git: https://git-scm.com/download/win"
        $script:Errors++
    }
}
Add-Result "HasGit" $gitOk

# ============================================================
# STEP 5: Node.js v22+ (Windows)
# ============================================================
Write-STEP 5 "檢查 Node.js (需要 v22+)..."
Write-LINE

$nodeOk = $false
try {
    $nodeVer    = (node --version 2>&1).ToString().Trim()
    $nodeMajor  = [int]($nodeVer.TrimStart('v').Split('.')[0])
    if ($nodeMajor -ge 22) {
        Write-OK "Node.js $nodeVer (>= v22) 已安裝"
        $nodeOk = $true
    } else {
        Write-WARN "Node.js $nodeVer 版本過舊 (需要 v22+)，正在升級..."
    }
} catch {
    Write-WARN "Node.js 未安裝，正在安裝 v22 LTS..."
}

if (-not $nodeOk) {
    if ($script:Results["HasWinget"]) {
        Install-WithWinget "OpenJS.NodeJS.LTS" "Node.js LTS"
        Update-Path
        try {
            $nodeVer   = (node --version 2>&1).ToString().Trim()
            $nodeMajor = [int]($nodeVer.TrimStart('v').Split('.')[0])
            if ($nodeMajor -ge 22) {
                Write-OK "Node.js $nodeVer 安裝成功"
                $nodeOk = $true
            } else {
                Write-WARN "安裝後請重新開啟命令列以更新 PATH"
                $script:Warnings++
            }
        } catch {
            Write-WARN "安裝完成，請重新開啟命令列後再執行此腳本"
            $script:Warnings++
        }
    } else {
        Write-FAIL "請手動安裝 Node.js v22+: https://nodejs.org/en/download/"
        $script:Errors++
    }
}
Add-Result "HasNode" $nodeOk

# ============================================================
# STEP 6: WSL2 + Ubuntu
# ============================================================
Write-STEP 6 "檢查 WSL2 + Ubuntu..."
Write-LINE

$hasWSL2 = $false

# 用直接執行法偵測 Ubuntu（避免 wsl -l 的 UTF-16 解析問題）
$ubuntuTest = wsl -d Ubuntu -e echo "WSL_OK" 2>&1
$ubuntuOK   = ($LASTEXITCODE -eq 0) -and ("$ubuntuTest" -match "WSL_OK")

if ($ubuntuOK) {
    # 確認是 WSL2 版本（去除空白後比對）
    $rawList  = (wsl -l -v 2>&1 | Out-String) -replace '\x00', '' -replace ' ', ''
    if ($rawList -match 'Ubuntu.*2') {
        Write-OK "WSL2 + Ubuntu 已安裝且運行"
        $hasWSL2 = $true
    } else {
        Write-WARN "Ubuntu 以 WSL1 運行，正在升級至 WSL2..."
        wsl --set-version Ubuntu 2 2>&1 | Out-Null
        Write-OK "Ubuntu 升級至 WSL2 完成"
        $hasWSL2 = $true
    }
} else {
    # Ubuntu 未安裝 — 嘗試安裝
    $wslCheck = wsl --status 2>&1 | Out-String
    if ($wslCheck -match '\w') {
        # WSL 已啟用但沒有 Ubuntu
        Write-WARN "WSL2 已啟用但未安裝 Ubuntu，正在安裝..."
        if ($isAdmin) {
            wsl --install -d Ubuntu 2>&1 | Out-Null
            Write-WARN "Ubuntu 安裝中，完成後需重新開機"
            Write-INFO "重開機後請重新執行此腳本繼續設定"
            $script:Warnings++
        } else {
            Write-FAIL "安裝 Ubuntu 需要管理員權限，請以管理員執行"
            $script:Errors++
        }
    } else {
        # WSL 完全未啟用
        Write-WARN "WSL2 未啟用，正在啟用..."
        if ($isAdmin) {
            if ($script:Results["WindowsOK"]) {
                dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart 2>&1 | Out-Null
                dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart 2>&1 | Out-Null
                wsl --set-default-version 2 2>&1 | Out-Null
                wsl --install -d Ubuntu 2>&1 | Out-Null
                Write-WARN "WSL2 已啟用，需要重新開機"
                Write-INFO "重開機後請重新執行此腳本"
                $script:Warnings++
            } else {
                Write-FAIL "系統版本不支援 WSL2"
                $script:Errors++
            }
        } else {
            Write-FAIL "啟用 WSL2 需要管理員權限"
            $script:Errors++
        }
    }
}
Add-Result "HasWSL2" $hasWSL2

# ============================================================
# STEP 7: Docker Desktop
# ============================================================
Write-STEP 7 "檢查 Docker Desktop..."
Write-LINE

$hasDocker = $false
try {
    $dockerVer = (docker --version 2>&1).ToString().Trim()
    Write-OK "$dockerVer 已安裝"
    # 確認 daemon 運行
    docker info 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-OK "Docker daemon 運行中"
    } else {
        Write-WARN "Docker daemon 未運行，請啟動 Docker Desktop"
        $script:Warnings++
    }
    $hasDocker = $true
} catch {
    Write-WARN "Docker Desktop 未安裝 (The Hands PostgreSQL 需要)"
    if ($script:Results["HasWinget"]) {
        Write-INFO "正在安裝 Docker Desktop..."
        Install-WithWinget "Docker.DockerDesktop" "Docker Desktop"
        Write-WARN "安裝完成，請重新啟動系統後啟用 Docker"
        $script:Warnings++
    } else {
        Write-INFO "請手動下載: https://www.docker.com/products/docker-desktop/"
    }
}
Add-Result "HasDocker" $hasDocker

# ============================================================
# STEP 8: ngrok
# ============================================================
Write-STEP 8 "檢查 ngrok..."
Write-LINE

$hasNgrok = $false
try {
    $ngrokVer = (ngrok version 2>&1).ToString().Trim()
    Write-OK "$ngrokVer 已安裝"
    $hasNgrok = $true
} catch {
    Write-WARN "ngrok 未安裝 (用於對外暴露 The Hands，可選)"
    if ($script:Results["HasWinget"]) {
        Write-INFO "正在安裝 ngrok..."
        Install-WithWinget "Ngrok.Ngrok" "ngrok"
        Update-Path
        try {
            $ngrokVer = (ngrok version 2>&1).ToString().Trim()
            Write-OK "ngrok 安裝成功: $ngrokVer"
            $hasNgrok = $true
        } catch {
            Write-WARN "ngrok 安裝後請重新開啟命令列"
            $script:Warnings++
        }
    }
}
Add-Result "HasNgrok" $hasNgrok

# ============================================================
# STEP 9: WSL2 內部 Node.js 安裝
# ============================================================
Write-STEP 9 "WSL2 Ubuntu 內部 — 安裝 Node.js v22..."
Write-LINE

if ($hasWSL2) {
    # 檢查 WSL 內 Node.js
    $wslNodeVer = (wsl bash -c 'node --version 2>/dev/null || echo NONE' 2>&1).ToString().Trim()
    if ($wslNodeVer -eq "NONE" -or $wslNodeVer -eq "") {
        $wslNodeMajor = 0
    } else {
        try { $wslNodeMajor = [int]($wslNodeVer.TrimStart('v').Split('.')[0]) } catch { $wslNodeMajor = 0 }
    }

    if ($wslNodeMajor -ge 22) {
        Write-OK "WSL2 Node.js $wslNodeVer (>= v22) 已安裝"
    } else {
        Write-INFO "WSL2 Node.js 未安裝或版本不足 ($wslNodeVer)，正在安裝 v22..."
        Write-INFO "  (1/4) 更新 apt..."
        wsl -u root bash -c 'apt-get update -qq > /dev/null 2>&1' 2>&1 | Out-Null
        Write-INFO "  (2/4) 安裝 curl..."
        wsl -u root bash -c 'apt-get install -y -qq curl > /dev/null 2>&1' 2>&1 | Out-Null
        Write-INFO "  (3/4) 加入 NodeSource v22 倉庫..."
        wsl -u root bash -c 'curl -fsSL https://deb.nodesource.com/setup_22.x | bash - > /dev/null 2>&1' 2>&1 | Out-Null
        Write-INFO "  (4/4) 安裝 Node.js v22..."
        wsl -u root bash -c 'apt-get install -y nodejs > /dev/null 2>&1' 2>&1 | Out-Null

        $wslNodeVer = (wsl bash -c 'node --version 2>/dev/null || echo NONE' 2>&1).ToString().Trim()
        if ($wslNodeVer -ne "NONE" -and $wslNodeVer -ne "") {
            Write-OK "WSL2 Node.js $wslNodeVer 安裝成功"
        } else {
            Write-FAIL "WSL2 Node.js 安裝失敗，請在 WSL2 Ubuntu 內手動執行:"
            Write-INFO "  curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -"
            Write-INFO "  sudo apt-get install -y nodejs"
            $script:Errors++
        }
    }
} else {
    Write-WARN "WSL2 未安裝，跳過此步驟"
}

# ============================================================
# STEP 10: WSL2 內部 pnpm 安裝
# ============================================================
Write-STEP 10 "WSL2 Ubuntu 內部 — 安裝 pnpm v10+..."
Write-LINE

if ($hasWSL2) {
    $wslPnpmVer = (wsl bash -c 'pnpm --version 2>/dev/null || echo NONE' 2>&1).ToString().Trim()
    if ($wslPnpmVer -eq "NONE" -or $wslPnpmVer -eq "") {
        $wslPnpmMajor = 0
    } else {
        try { $wslPnpmMajor = [int]($wslPnpmVer.Split('.')[0]) } catch { $wslPnpmMajor = 0 }
    }

    if ($wslPnpmMajor -ge 10) {
        Write-OK "WSL2 pnpm v$wslPnpmVer (>= v10) 已安裝"
    } else {
        Write-INFO "WSL2 pnpm 未安裝或版本不足，正在安裝..."
        wsl bash -c 'npm install -g pnpm@latest > /dev/null 2>&1' 2>&1 | Out-Null

        # 用 login shell (-l) 讓 PATH 包含 npm global bin
        $wslPnpmVer = (wsl bash -l -c 'pnpm --version 2>/dev/null || echo NONE' 2>&1).ToString().Trim()
        if ($wslPnpmVer -ne "NONE" -and $wslPnpmVer -ne "") {
            Write-OK "WSL2 pnpm v$wslPnpmVer 安裝成功"
        } else {
            # 嘗試用完整路徑
            $wslPnpmPath = (wsl bash -c 'ls /usr/local/bin/pnpm 2>/dev/null || ls ~/.local/share/pnpm/pnpm 2>/dev/null || echo NONE' 2>&1).ToString().Trim()
            if ($wslPnpmPath -ne "NONE" -and $wslPnpmPath -ne "") {
                Write-OK "WSL2 pnpm 安裝完成 (路徑: $wslPnpmPath)"
            } else {
                Write-FAIL "WSL2 pnpm 安裝失敗，請手動執行: npm install -g pnpm@latest"
                $script:Errors++
            }
        }
    }
} else {
    Write-WARN "WSL2 未安裝，跳過此步驟"
}

# ============================================================
# STEP 11: WSL2 基本工具安裝
# ============================================================
Write-STEP 11 "WSL2 Ubuntu 內部 — 安裝基本工具..."
Write-LINE

if ($hasWSL2) {
    Write-INFO "安裝 curl / git / jq / python3..."
    wsl -u root bash -c 'apt-get install -y -qq curl git jq python3 python3-pip > /dev/null 2>&1' 2>&1 | Out-Null
    Write-OK "基本工具安裝完成 (curl / git / jq / python3)"
} else {
    Write-WARN "WSL2 未安裝，跳過此步驟"
}

# ============================================================
# STEP 12: OpenClaw 目錄結構檢查
# ============================================================
Write-STEP 12 "檢查 OpenClaw 目錄結構..."
Write-LINE

if ($hasWSL2) {
    $checks = @(
        @{ cmd = "[ -d ~/.openclaw ] && echo YES || echo NO";                        label = "~/.openclaw 根目錄" },
        @{ cmd = "[ -d ~/.openclaw/workspace ] && echo YES || echo NO";               label = "~/.openclaw/workspace" },
        @{ cmd = "[ -f ~/.openclaw/.env ] && echo YES || echo NO";                    label = "~/.openclaw/.env" },
        @{ cmd = "[ -f ~/.openclaw/workspace/package.json ] && echo YES || echo NO";  label = "workspace/package.json" },
        @{ cmd = "[ -f ~/.config/systemd/user/openclaw-gateway.service ] && echo YES || echo NO"; label = "systemd service 檔案" }
    )

    foreach ($check in $checks) {
        $result = (wsl bash -c $check.cmd 2>&1).ToString().Trim()
        if ($result -eq "YES") {
            Write-OK "$($check.label): 存在"
        } else {
            Write-WARN "$($check.label): 不存在"
        }
    }

    # 顯示 openclaw 目錄內容
    Write-INFO "~/.openclaw/ 內容:"
    $dirContent = wsl bash -c 'ls ~/.openclaw/ 2>/dev/null | head -20' 2>&1
    ($dirContent | Out-String).Trim().Split("`n") | ForEach-Object {
        if ($_.Trim()) { Write-Host "    $($_.Trim())" -ForegroundColor DarkGray }
    }
} else {
    Write-WARN "WSL2 未安裝，跳過目錄檢查"
}

# ============================================================
# STEP 13: pnpm install (安裝 Node.js 依賴)
# ============================================================
Write-STEP 13 "安裝 OpenClaw Node.js 依賴 (pnpm install)..."
Write-LINE

if ($hasWSL2) {
    $hasPkg = (wsl bash -c '[ -f ~/.openclaw/workspace/package.json ] && echo YES || echo NO' 2>&1).ToString().Trim()
    if ($hasPkg -eq "YES") {
        Write-INFO "執行 pnpm install..."
        $pnpmOut = wsl bash -c 'cd ~/.openclaw/workspace && pnpm install 2>&1 | tail -5' 2>&1
        Write-Host ($pnpmOut | Out-String).Trim()
        Write-OK "pnpm install 完成"
    } else {
        Write-WARN "package.json 不存在，跳過 pnpm install"
        Write-INFO "請確認 OpenClaw workspace 已正確部署"
    }
} else {
    Write-WARN "WSL2 未安裝，跳過"
}

# ============================================================
# STEP 14: The Hands Docker 服務
# ============================================================
Write-STEP 14 "檢查 The Hands Docker 服務..."
Write-LINE

if ($hasDocker -and $hasWSL2) {
    $hasCompose = (wsl bash -c '[ -f ~/.openclaw/workspace/the-hands/docker-compose.yml ] && echo YES || echo NO' 2>&1).ToString().Trim()
    if ($hasCompose -eq "YES") {
        Write-OK "docker-compose.yml 存在"
        $psOut = wsl bash -c 'docker compose -f ~/.openclaw/workspace/the-hands/docker-compose.yml ps 2>&1' 2>&1
        Write-Host ($psOut | Out-String).Trim()
    } else {
        Write-WARN "the-hands/docker-compose.yml 不存在"
    }
} else {
    Write-WARN "Docker 或 WSL2 未就緒，跳過"
}

# ============================================================
# STEP 15: .env 檔案檢查
# ============================================================
Write-STEP 15 "檢查 .env 設定..."
Write-LINE

if ($hasWSL2) {
    $hasEnv = (wsl bash -c '[ -f ~/.openclaw/.env ] && echo YES || echo NO' 2>&1).ToString().Trim()
    if ($hasEnv -eq "YES") {
        # 列出已設定的 key（不顯示值）
        Write-OK ".env 檔案存在，已設定的變數:"
        $envKeys = wsl bash -c "grep -v '^#' ~/.openclaw/.env 2>/dev/null | grep '=' | cut -d= -f1 | grep -v '^$'" 2>&1
        ($envKeys | Out-String).Trim().Split("`n") | ForEach-Object {
            if ($_.Trim()) { Write-Host "    $($_.Trim())" -ForegroundColor DarkGray }
        }
    } else {
        Write-WARN ".env 不存在，請根據以下範本建立 ~/.openclaw/.env:"
        Write-Host @"

    # ─ 建立指令 ─────────────────────────────────────────────
    # 在 WSL2 Ubuntu 終端機執行:
    # nano ~/.openclaw/.env
    #
    # ─ 必填（至少填一個通訊平台）──────────────────────────
    TELEGRAM_BOT_TOKEN=
    DISCORD_BOT_TOKEN=
    LINE_CHANNEL_ACCESS_TOKEN=
    LINE_CHANNEL_SECRET=
    #
    # ─ AI 服務 ──────────────────────────────────────────────
    OPENROUTER_API_KEY=
    BRAVE_API_KEY=
    #
    # ─ The Hands DB (docker-compose 預設值) ────────────────
    DATABASE_URL=postgresql://thehands:thehands@localhost:5432/thehands
    APP_HOST=0.0.0.0
    APP_PORT=8100
"@ -ForegroundColor DarkGray
        $script:Warnings++
    }
} else {
    Write-WARN "WSL2 未安裝，跳過"
}

# ============================================================
# 產生報告
# ============================================================
$reportPath = Join-Path $script:ScriptDir "openclaw-env-report.txt"
$reportContent = @"
OpenClaw 環境報告
生成時間: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
==========================================

[系統資訊]
  OS    : $($os.Caption)
  Build : $build
  CPU   : $cpu
  RAM   : $ramGB GB

[依賴狀態]
  Git          : $(if ($script:Results['HasGit']) { '已安裝' } else { '未安裝' })
  Node.js v22+ : $(if ($script:Results['HasNode']) { '已安裝' } else { '未安裝' })
  WSL2+Ubuntu  : $(if ($hasWSL2) { '已安裝' } else { '未安裝' })
  Docker       : $(if ($hasDocker) { '已安裝' } else { '未安裝' })
  ngrok        : $(if ($hasNgrok) { '已安裝' } else { '未安裝' })

[統計]
  錯誤數 : $($script:Errors)
  警告數 : $($script:Warnings)

[下一步]
  1. 確認 ~/.openclaw/.env 已填入所有 API 金鑰
  2. 啟用 systemd 服務:
     wsl -e bash -c "systemctl --user enable --now openclaw-gateway.service"
  3. 啟動 The Hands:
     wsl -e bash -c "cd ~/.openclaw/workspace/the-hands && docker compose up -d"
"@
$reportContent | Out-File -FilePath $reportPath -Encoding UTF8
Write-Host ""
Write-INFO "報告已儲存至: $reportPath"

# ============================================================
# 最終摘要
# ============================================================
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "   安裝摘要" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

$items = @(
    @{ label = "Git (Windows)   "; ok = $script:Results["HasGit"];    required = $true },
    @{ label = "Node.js v22+    "; ok = $script:Results["HasNode"];   required = $true },
    @{ label = "WSL2 + Ubuntu   "; ok = $hasWSL2;                     required = $true },
    @{ label = "Docker Desktop  "; ok = $hasDocker;                   required = $false },
    @{ label = "ngrok           "; ok = $hasNgrok;                    required = $false }
)

foreach ($item in $items) {
    $tag  = if ($item.ok) { "[已安裝]" } else { if ($item.required) { "[未安裝]" } else { "[選用/未安裝]" } }
    $color = if ($item.ok) { "Green" } else { if ($item.required) { "Red" } else { "Yellow" } }
    Write-Host "  $($item.label): $tag" -ForegroundColor $color
}

Write-Host ""
if ($script:Errors -eq 0) {
    if ($script:Warnings -eq 0) {
        Write-Host "  所有必要依賴已就緒！OpenClaw 可以安裝。" -ForegroundColor Green
    } else {
        Write-Host "  環境基本就緒，有 $($script:Warnings) 個警告（詳見上方說明）" -ForegroundColor Yellow
    }
} else {
    Write-Host "  發現 $($script:Errors) 個錯誤，請修正後再繼續安裝" -ForegroundColor Red
}

Write-Host ""
Write-Host "  錯誤: $($script:Errors) 個  |  警告: $($script:Warnings) 個" -ForegroundColor White
Write-Host ""
Write-Host "詳細報告: $reportPath" -ForegroundColor Cyan
Write-Host ""
Read-Host "按 Enter 鍵結束"






