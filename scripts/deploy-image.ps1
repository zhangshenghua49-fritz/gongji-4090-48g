# deploy-image.ps1 -- 一条命令把镜像建出来
#
# 用法（在 gongji-4090-48g 目录里，PowerShell 或 pwsh）：
#   .\scripts\deploy-image.ps1 -Token ghp_xxxxxxxx
#   .\scripts\deploy-image.ps1 -Token ghp_xxx -Flavor full -RepoName my-h3-image
#
# Token 怎么来（30 秒）：
#   浏览器 → https://github.com/settings/tokens/new
#   Note 随便写（比如 gongji-4090-48g），Expiration 选 7 days，
#   勾选 [x] repo  和 [x] workflow  两项 → Generate token → 复制那串 ghp_...
#
# 它替你做的事：
#   1. 用 token 确认身份
#   2. 建一个 public 仓库（已存在就复用）
#   3. git init + commit + 推上去
#   4. 触发 build-gongji-image，flavor 按你选的
#   5. 盯着跑到结束，把镜像地址打出来
#
# 推的是 ghcr.io，**不用配任何 secret** —— Actions 自带的 GITHUB_TOKEN 就够。
# 跑完镜像地址形如：ghcr.io/<你的用户名>/gongji-4090-48g:slim

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Token,

    [string]$RepoName = "gongji-4090-48g",

    [ValidateSet("slim", "full", "both")]
    [string]$Flavor = "slim",

    [string]$CommitMessage = "4090-48G: MOSS-Image + MiniMax H3 + GPT-SoVITS V5 + Drama 3",

    # 只打印计划，不真的动 GitHub
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$ApiBase = "https://api.github.com"

# 这台机器上 git 不在默认 PATH 里（只有 DSH 随附的 bash 环境带 git）。
# 找一圈：PATH → Program Files → DSH 自带的 ucrt64。
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    $candidates = @(
        "C:\Program Files\Git\cmd",
        "C:\Program Files (x86)\Git\cmd",
        "$env:LOCALAPPDATA\Programs\Git\cmd",
        "C:\Users\zhang\.dsh\profiles\desktop\node_modules\@dsh-ops\bash-win32-x64\ucrt64\bin"
    ) | Where-Object { Test-Path (Join-Path $_ "git.exe") }
    if ($candidates) {
        $env:PATH = ($candidates -join ";") + ";" + $env:PATH
    } else {
        throw "找不到 git.exe，先装 Git for Windows 或把它的 cmd 目录加进 PATH"
    }
}

$Headers = @{
    Authorization          = "Bearer $Token"
    Accept                 = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
    "User-Agent"           = "gongji-4090-48g-deploy"
}

function Say($msg) { Write-Host "[deploy] $msg" -ForegroundColor Cyan }
function Ok($msg) { Write-Host "   ok  $msg" -ForegroundColor Green }
function Bad($msg) { Write-Host "   !!  $msg" -ForegroundColor Yellow }

function Invoke-GitHub {
    param(
        [string]$Method = "GET",
        [string]$Path,
        $Body = $null,
        [switch]$AllowFailure
    )
    $uri = if ($Path -like "http*") { $Path } else { "$ApiBase$Path" }
    $p = @{ Method = $Method; Uri = $uri; Headers = $Headers }
    if ($null -ne $Body) {
        $p.Body = ($Body | ConvertTo-Json -Depth 8 -Compress)
        $p.ContentType = "application/json"
    }
    try {
        return Invoke-RestMethod @p
    } catch {
        if ($AllowFailure) {
            Bad "$Method $Path -> $($_.Exception.Message)"
            return $null
        }
        throw
    }
}

# ---------------------------------------------------------------------------
# 0. 定位项目根目录
# ---------------------------------------------------------------------------
$Root = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path (Join-Path $Root "Dockerfile"))) {
    throw "找不到 Dockerfile —— 请在 gongji-4090-48g 目录里跑这个脚本（当前推算根目录：$Root）"
}
Say "项目根目录：$Root"

# ---------------------------------------------------------------------------
# 1. 验身份 + 查 token 权限
# ---------------------------------------------------------------------------
Say "1/6 验证 token"
try {
    $Me = Invoke-GitHub -Path "/user"
    $Owner = $Me.login
    Ok "已认证为 $Owner"
} catch {
    if ($DryRun) {
        # DryRun 不碰 GitHub，token 是假的也无所谓，用占位符走完计划
        $Owner = "<你的账号>"
        Bad "token 无效（DryRun 忽略）—— $($_.Exception.Message)"
    } else {
        Bad "token 验证失败：$($_.Exception.Message)"
        throw "先修 token 再跑。检查：是否过期、是否复制完整、是否有 repo + workflow 权限。"
    }
}

$Scopes = ""
try {
    # 权限 scope 只在 /user 的响应头里，Invoke-RestMethod 取不到，单独发一次
    $resp = Invoke-WebRequest -Uri "$ApiBase/user" -Headers $Headers -Method GET -UseBasicParsing
    $Scopes = $resp.Headers["X-OAuth-Scopes"]
} catch { }
if ($Scopes) {
    Ok "token scopes: $Scopes"
    foreach ($need in @("repo", "workflow")) {
        if ($Scopes -notmatch $need) { Bad "缺 scope: $need —— 到 token 设置页补勾，否则到第 4 步会失败" }
    }
} else {
    Bad "读不到 scopes（fine-grained token 正常）—— 继续"
}

if ($DryRun) {
    Say "DryRun：将创建 $Owner/$RepoName，推 main，触发 flavor=$Flavor"
    return
}

# ---------------------------------------------------------------------------
# 2. 建仓库（已存在就复用）
# ---------------------------------------------------------------------------
Say "2/6 准备仓库 $Owner/$RepoName"
$Repo = Invoke-GitHub -Path "/repos/$Owner/$RepoName" -AllowFailure
if ($Repo) {
    Ok "仓库已存在，复用（$($Repo.html_url)）"
    $DefaultBranch = if ($Repo.default_branch) { $Repo.default_branch } else { "main" }
} else {
    $Repo = Invoke-GitHub -Method POST -Path "/user/repos" -Body @{
        name        = $RepoName
        description = "RTX 4090 48G AI video stack: MiniMax-H3 + Qwen-Image-2.1 + FLUX3 klein + VoxCPM2"
        private     = $false
        has_issues  = $false
        has_wiki    = $false
        auto_init   = $false
    }
    Ok "已创建 $($Repo.html_url)"
    $DefaultBranch = "main"
}

# ---------------------------------------------------------------------------
# 3. git init + commit + push
# ---------------------------------------------------------------------------
Say "3/6 提交并推送"
Push-Location $Root
try {
    if (-not (Test-Path ".git")) {
        git init -b $DefaultBranch 2>&1 | Out-Null
        Ok "git 仓库已初始化"
    }

    # 本地身份（只写进 .git/config，不动全局）
    git config user.name  "deploy-bot"                      2>&1 | Out-Null
    git config user.email "deploy-bot@users.noreply.github.com" 2>&1 | Out-Null

    # .gitignore：大件和敏感件不进仓库
    $ignore = @(
        "runtime.env",
        ".cache/",
        "local/",
        "**/__pycache__/",
        "*.pyc",
        "shot-*.png"
    )
    $giPath = Join-Path $Root ".gitignore"
    $existing = if (Test-Path $giPath) { Get-Content $giPath } else { @() }
    $merged = @($existing) + @($ignore) | Where-Object { $_ -and $_.Trim() } | Select-Object -Unique
    # 保留上一次脚本写入的注释头，避免重复追加
    Set-Content -Path $giPath -Value $merged -Encoding utf8
    Ok ".gitignore 已就绪（$($merged.Count) 条）"

    git add -A 2>&1 | Out-Null
    $dirty = git status --porcelain 2>&1
    if ($dirty) {
        git commit -q -m $CommitMessage 2>&1 | Out-Null
        Ok "已提交 $(($dirty -split "`n").Count) 个变更"
    } else {
        Ok "没有新变更，跳过提交"
    }

    # 用一次性的带 token remote 推送，不把它写进 .git/config
    $pushUrl = "https://x-access-token:$Token@github.com/$Owner/$RepoName.git"
    git push $pushUrl "HEAD:$DefaultBranch" 2>&1 | ForEach-Object { if ($_ -match "error|fatal") { Bad $_ } }
    if (-not ((git remote 2>&1) -contains "origin")) {
        git remote add origin "https://github.com/$Owner/$RepoName.git"
    }
    Ok "已推送到 https://github.com/$Owner/$RepoName"
} finally {
    Pop-Location
}

# ---------------------------------------------------------------------------
# 4. 触发 workflow
# ---------------------------------------------------------------------------
Say "4/6 触发 build-gongji-image（flavor=$Flavor）"
Start-Sleep -Seconds 3   # 让 GitHub 感知到新 push

$dispatched = Invoke-GitHub -Method POST -Path "/repos/$Owner/$RepoName/actions/workflows/build-image.yml/dispatches" -Body @{
    ref    = $DefaultBranch
    inputs = @{ flavor = $Flavor; tag = "" }
} -AllowFailure

if ($null -eq $dispatched -and $Flavor -eq "slim") {
    # push 本身就会触发一次 slim 构建，可能已经在跑
    Bad "手动触发失败 —— 可能 push 已经自动触发了一次，继续盯着"
}

# ---------------------------------------------------------------------------
# 5. 轮询
# ---------------------------------------------------------------------------
Say "5/6 等待构建（首次 slim 约 25-40 分钟，full 60-90；这里每 30 秒看一眼）"
$run = $null
for ($i = 0; $i -lt 240; $i++) {
    Start-Sleep -Seconds 30
    $runs = Invoke-GitHub -Path "/repos/$Owner/$RepoName/actions/runs?per_page=5" -AllowFailure
    if (-not $runs) { continue }
    $run = $runs.workflow_runs | Where-Object { $_.path -like "*build-image.yml*" } | Select-Object -First 1
    if (-not $run) { Bad "还没看到 run（$([int]($i*30/60)) 分钟）"; continue }

    $mins = [math]::Round(((Get-Date).ToUniversalTime() - [datetime]$run.created_at).TotalMinutes, 1)
    Write-Host ("   [{0,5} min] {1}  {2}" -f $mins, $run.status, $run.conclusion) -ForegroundColor DarkGray

    if ($run.status -eq "completed") { break }
}

if (-not $run) { throw "等不到 workflow run —— 去 https://github.com/$Owner/$RepoName/actions 看看" }

if ($run.conclusion -ne "success") {
    Bad "构建结果：$($run.conclusion)"
    Write-Host "   日志：$($run.html_url)" -ForegroundColor Yellow
    Write-Host "   最常见原因：torch 装超时（重跑一次通常就好）、磁盘不足（Free disk space 步骤失败）" -ForegroundColor DarkGray
    return
}

Ok "构建成功（$([math]::Round(((Get-Date).ToUniversalTime() - [datetime]$run.created_at).TotalMinutes,1)) 分钟）"

# ---------------------------------------------------------------------------
# 6. 收尾：确认包可见性 + 打印地址
# ---------------------------------------------------------------------------
Say "6/6 镜像地址"
$pkgPath = "/users/$Owner/packages/container/gongji-4090-48g"
$pkg = Invoke-GitHub -Path $pkgPath -AllowFailure
if ($pkg) {
    if ($pkg.visibility -ne "public") {
        Bad "包当前是 $($pkg.visibility) —— 平台匿名拉不到"
        Say "正在改成 public…"
        $fixed = Invoke-GitHub -Method PATCH -Path $pkgPath -Body @{ visibility = "public" } -AllowFailure
        if ($fixed) { Ok "已设为 public" }
        else { Bad "自动改失败，手动：https://github.com/users/$Owner/packages/container/gongji-4090-48g/settings" }
    } else {
        Ok "包已是 public"
    }
}

$flavors = if ($Flavor -eq "both") { @("slim", "full") } else { @($Flavor) }
Write-Host ""
Write-Host "共绩「弹性部署 → 自定义服务」填：" -ForegroundColor Cyan
foreach ($f in $flavors) {
    Write-Host "  ghcr.io/$Owner/gongji-4090-48g:$f" -ForegroundColor White
}
Write-Host ""
Write-Host "  端口        ：8188" -ForegroundColor Gray
Write-Host "  机型        ：RTX 4090 48G" -ForegroundColor Gray
Write-Host "  启动命令    ：bash /root/scripts/boot.sh" -ForegroundColor Gray
Write-Host ""
Write-Host "镜像里没有模型权重，进容器后还要拉一次：" -ForegroundColor DarkGray
Write-Host "  bash /root/scripts/fetch_models.sh --tier h3 --tier vox" -ForegroundColor DarkGray
