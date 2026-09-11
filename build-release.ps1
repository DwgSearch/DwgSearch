<#>
.SYNOPSIS
    DwgSearch - Build Portable Release Script
    Usage: Run in PowerShell as Administrator on Windows 7 build machine
    .\build-release.ps1 [-Version "2.19.0"] [-UploadRelease] [-GitHubToken "ghp_xxx"]

.DESCRIPTION
    1. Clean old build artifacts
    2. Build with PyInstaller (folder mode only - portable)
    3. Create portable ZIP
    4. Generate SHA256SUMS.txt
    5. Optional: Create GitHub Release and upload assets

.NOTES
    Requires: Python 3.8+, PyInstaller, GitHub CLI (gh), 7-Zip (optional)
    .NET subprojects must be pre-built (DwgTextExtractor, DwgTextReplacer)
    Build on Windows 7 for Windows 7 compatibility
</#>

param(
    [string]$Version = "2.19.0",
    [switch]$UploadRelease,
    [string]$GitHubToken = "",
    [string]$RepoOwner = "DwgSearch",
    [string]$RepoName = "DwgSearch",
    [switch]$SkipBuild,
    [switch]$SkipSourceSnapshot
)

# dotnet/git/gh 这些外部命令行工具在中文 Windows 上，实际输出的是
# UTF-8 编码的字节，但 Windows PowerShell 5.1 默认按控制台的 ANSI
# 代码页（简体中文系统一般是 GBK/cp936）去解析捕获到的输出文本，
# 两边对不上，中文报错信息就会变成乱码（比如这次 dotnet build 报错
# 里的"鎵句笉鍒拌祫..."，其实是"找不到资产..."被错误解码的结果）。
# 这里统一把控制台输出编码设成 UTF-8，让后面所有 "外部命令 2>&1"
# 捕获到的输出都能正常显示中文，不止对 dotnet 有效，git/gh 等其它
# 外部工具的中文输出也会一并受益。
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
} catch {
    # 极少数环境（比如没有真正控制台、被重定向到文件）设置这个会报错，
    # 不影响脚本主体功能，静默跳过就好。
}

# Configuration
$ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
$DistDir = Join-Path $ProjectRoot "dist"
$BuildDir = Join-Path $ProjectRoot "build"
$ReleaseDir = Join-Path $ProjectRoot "release_dist"
$VenVPython = Join-Path $ProjectRoot "venv38\Scripts\python.exe"
$PyInstaller = Join-Path $ProjectRoot "venv38\Scripts\pyinstaller.exe"

$TagName = "v$Version"
$ReleaseTitle = "DwgSearch V$Version"
# 可执行文件所在的目录名
$FolderModeExeName = "DwgSearch"
$PortableZipName = "DwgSearch_Portable_x64_v$Version.zip"
$Sha256FileName = "SHA256SUMS.txt"

$SourceSnapshotZip = "G:\Script\dwg_search_project\src_backup_DwgSearch_v$Version.zip"

function Get-SourceFilesForSnapshot {
    <#
    在整个项目根目录下递归收集要放进"源码快照"里的文件，按扩展名白名单
    挑选，同时把 bin、obj、.vs、.git、dist、build、release_dist 这几个
    目录名整个跳过（不管它们出现在路径的哪一层），另外还会自动探测并
    排除 Python 虚拟环境目录。

    虚拟环境探测方式：认 pyvenv.cfg 这个文件——凡是项目根目录下的
    子文件夹里有这个文件，就认定它是虚拟环境，整个跳过，不管这个
    文件夹叫 venv38、venv、.venv 还是别的什么名字，都能自动排除，
    不用写死名字（第一次实测就是因为没考虑到这一项，venv38\Lib\
    site-packages\ 下面几千个第三方库的 .py 文件被原样收进了"源码
    快照"里——这些 dunder 文件（__init__.py/__about__.py 之类）
    本来就是各个第三方库自己带的，不是这个项目的源码）。

    这几个目录只装编译中间产物、IDE 缓存、第三方库代码，既不是本项目
    的"源码"，体积往往还很大，混进"源码快照"里既没意义、又让快照
    文件不必要地膨胀。
    #>
    param([string]$Root)
    $extensions = @(".py", ".spec", ".ico", ".csproj", ".cs", ".props", ".targets",
                    ".md", ".txt", ".json", ".ps1")
    $excludeDirNames = @("bin", "obj", ".vs", ".git", "__pycache__", "dist", "build", "release_dist")

    Get-ChildItem -Path $Root -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        if (Test-Path (Join-Path $_.FullName "pyvenv.cfg")) {
            $excludeDirNames += $_.Name
        }
    }

    Get-ChildItem -Path $Root -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
        $ext = $_.Extension.ToLower()
        if ($extensions -notcontains $ext) { return $false }
        # 只要这个文件路径里任何一段目录名命中排除列表，就整条跳过——
        # 逐段比较而不是简单地用 -like "*\bin\*"，是为了避免把文件名里
        # 恰好含有"bin"这几个字母、但其实不是目录名的情况误判掉
        # （虽然目前项目里大概率不会有这种命名，但这样写更严谨）。
        $relative = $_.FullName.Substring($Root.Length).TrimStart('\')
        $segments = $relative -split '\\'
        foreach ($seg in $segments) {
            if ($excludeDirNames -contains $seg.ToLower()) { return $false }
        }
        return $true
    }
}

function New-ZipPreservingStructure {
    <#
    按每个文件相对 Root 的原始相对路径，把它们写进一个新的 zip——
    直接用 .NET 的 ZipArchive API 逐个文件写入 entry，而不是把一堆
    绝对路径丢给 Compress-Archive -Path。

    这是因为 Compress-Archive -Path 只要传进去的是"一批具体文件的
    完整路径"（不是文件夹），就只会取文件名本身塞进 zip 根目录，不会
    保留这些文件原来在磁盘上的相对目录结构——实测这次快照 zip 解压
    出来所有文件全部堆在一起，AccoreconsolePlugin\src\Commands.cs
    跟 database.py 平级，就是这个原因。改用 ZipArchive 直接指定每个
    entry 的名字（也就是相对路径），不存在这个局限。
    #>
    param([string]$Root, [System.IO.FileInfo[]]$Files, [string]$DestinationZip)

    Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

    if (Test-Path $DestinationZip) { Remove-Item $DestinationZip -Force }

    $archive = [System.IO.Compression.ZipFile]::Open($DestinationZip, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in $Files) {
            # zip 内部的 entry 名字按惯例用正斜杠，不用 Windows 的反斜杠——
            # 这样解压出来的 zip 在任何平台上打开都是正常的目录结构，
            # 不会有工具因为路径分隔符不对而认错。
            $relativePath = $file.FullName.Substring($Root.Length).TrimStart('\').Replace('\', '/')
            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $archive, $file.FullName, $relativePath,
                [System.IO.Compression.CompressionLevel]::Optimal
            ) | Out-Null
        }
    } finally {
        $archive.Dispose()
    }
}

function Write-SourceSnapshot {
    param([switch]$Force)
    if (-not $Force -and $SkipSourceSnapshot) {
        Write-Log "Skipping source snapshot (--SkipSourceSnapshot)"
        return $false
    }
    Write-Log "Creating source code snapshot..."
    try {
        $files = @(Get-SourceFilesForSnapshot -Root $ProjectRoot)
        if ($files.Count -eq 0) {
            Write-Log "[WARN] Source snapshot: no matching source files found" "WARN"
            return $false
        }
        New-ZipPreservingStructure -Root $ProjectRoot -Files $files -DestinationZip $SourceSnapshotZip
        $sizeMB = [math]::Round((Get-Item $SourceSnapshotZip).Length / 1MB, 1)
        Write-Log ("  [OK] Source snapshot: {0} ({1} MB, {2} files)" -f (Split-Path $SourceSnapshotZip -Leaf), $sizeMB, $files.Count)
        return $true
    } catch {
        Write-Log ("[WARN] Source snapshot failed: {0}" -f $_.Exception.Message) "WARN"
        return $false
    }
}

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "HH:mm:ss"
    $color = switch ($Level) { "ERROR" { "Red" } "WARN" { "Yellow" } "OK" { "Green" } default { "Cyan" } }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

function Check-Command {
    param([string]$Name, [string]$Path = "")
    $cmd = if ($Path) { $Path } else { $Name }
    if (Get-Command $cmd -ErrorAction SilentlyContinue) {
        $cmdSrc = (Get-Command $cmd).Source
        Write-Log ("[OK] Found {0}: {1}" -f $Name, $cmdSrc)
        return $true
    } else {
        Write-Log ("[ERROR] Missing {0} ({1}), please install and add to PATH" -f $Name, $cmd)
        return $false
    }
}

function Get-Sha256 {
    param([string]$FilePath)
    $hash = Get-FileHash -Algorithm SHA256 -Path $FilePath
    return $hash.Hash.ToLower()
}

# Main
Write-Log ("=== DwgSearch Build Portable Release v{0} ===" -f $Version)
Write-Log ("Project root: {0}" -f $ProjectRoot)

$ok = $true
$ok = (Check-Command "python" $VenVPython) -and $ok
$ok = (Check-Command "pyinstaller" $PyInstaller) -and $ok
$ok = (Check-Command "git") -and $ok
if ($UploadRelease) { $ok = (Check-Command "gh") -and $ok }
if (-not $ok) { exit 1 }

# 记录这次源码快照是不是真的成功生成了，而不是等到脚本最后靠
# "这个文件名存不存在"去反推——如果这次因为筛选不到匹配文件、
# 或者压缩过程中出别的错而失败，但上一次用同一个 -Version 跑出来的
# 旧快照文件还在磁盘上，光看"文件存不存在"会被这个旧文件骗过去，
# 误以为这次也成功了。
$script:SourceSnapshotOk = $false

if (-not $SkipBuild) {
    Write-Log "Cleaning old build directories..."
    Remove-Item -Recurse -Force $DistDir -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $BuildDir -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $ReleaseDir -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $ReleaseDir | Out-Null

    # Create source snapshot before build
    $script:SourceSnapshotOk = Write-SourceSnapshot
}

# Build .NET subprojects
if (-not $SkipBuild) {
    Write-Log "Checking .NET subprojects..."
    $netProjects = @(
        @{ Path = "DwgTextExtractor"; Config = "Release"; Framework = "net48" },
        @{ Path = "DwgTextReplacer"; Config = "Release"; Framework = "net48" }
    )
    foreach ($proj in $netProjects) {
        $projPath = Join-Path $ProjectRoot $proj.Path
        $csproj = Get-ChildItem $projPath -Filter "*.csproj" | Select-Object -First 1
        if ($csproj) {
            $exeName = $csproj.BaseName + ".exe"
            $exePath = Join-Path $projPath ("bin\{0}\{1}\{2}" -f $proj.Config, $proj.Framework, $exeName)
            if (-not (Test-Path $exePath)) {
                Write-Log ("  Building {0}..." -f $proj.Path)
                $result = dotnet build $csproj.FullName -c $proj.Config -f $proj.Framework 2>&1
                if ($LASTEXITCODE -ne 0) {
                    Write-Log ("[ERROR] {0} build failed, and no pre-built artifact exists at {1}" -f $proj.Path, $exePath)
                    # 之前这里只打了一句笼统的 "build failed"，dotnet build
                    # 自己真正的报错内容（比如 NuGet 包没恢复、SDK 版本
                    # 不对、代码本身编译错误）完全没有显示出来，出问题了
                    # 只能凭空猜。这里把捕获到的完整输出打出来，方便
                    # 直接照着报错定位原因。
                    Write-Log "---- dotnet build output ----"
                    $result | ForEach-Object { Write-Log ("  {0}" -f $_) }
                    Write-Log "---- end of dotnet build output ----"
                    Write-Log ("[ERROR] Aborting: packaging without this exe would ship a broken release")
                    exit 1
                }
                # 编译命令本身退出码是 0，不代表这个具体 exe 就一定生成到了
                # 预期路径——比如目标框架/配置名跟脚本里假设的对不上、
                # 或者 dotnet build 输出到了别的目录，都会导致这里明明
                # "编译成功"但其实找不到东西。之前这里没有这一步二次确认，
                # 只要 dotnet build 退出码正常就当作没事，等到打包完、
                # 用户装到自己电脑上才会因为缺这个 exe 出问题，那时候
                # 已经不好排查了。
                if (-not (Test-Path $exePath)) {
                    Write-Log ("[ERROR] {0} build reported success, but exe still not found at {1}" -f $proj.Path, $exePath)
                    Write-Log "[ERROR] Aborting: check TargetFramework/Configuration match what this script expects"
                    exit 1
                }
                Write-Log ("  [OK] {0} built successfully" -f $proj.Path)
            } else {
                Write-Log ("  [OK] {0} has build artifacts" -f $proj.Path)
            }
        } else {
            Write-Log ("[ERROR] No .csproj found under {0}" -f $projPath)
            exit 1
        }
    }
}

# PyInstaller folder mode (portable)
if (-not $SkipBuild) {
    Write-Log "Building: Folder mode (build.spec) - Portable..."
    $specFile = Join-Path $ProjectRoot "build.spec"
    $result = & $VenVPython -m PyInstaller $specFile --clean --noconfirm
    if ($LASTEXITCODE -ne 0) { Write-Log "[ERROR] Folder mode build failed"; exit 1 }
    
    $folderModeDir = Join-Path $DistDir $FolderModeExeName
    $folderModeExe = Join-Path $folderModeDir ("{0}.exe" -f $FolderModeExeName)
    if (-not (Test-Path $folderModeExe)) {
        Write-Log ("[ERROR] Folder mode artifact not found: {0}" -f $folderModeExe)
        exit 1
    }
    Write-Log ("  Artifact dir: {0}" -f $folderModeDir)
}

# Create portable ZIP
Write-Log "Creating portable package..."
$portableSourceDir = Join-Path $DistDir $FolderModeExeName
$portableZipPath = Join-Path $ReleaseDir $PortableZipName
Write-Log ("  Creating portable: {0}" -f $PortableZipName)
if (Get-Command 7z -ErrorAction SilentlyContinue) {
    & 7z a -tzip -mx=9 $portableZipPath ("{0}\*" -f $portableSourceDir) | Out-Null
} else {
    Compress-Archive -Path ("{0}\*" -f $portableSourceDir) -DestinationPath $portableZipPath -Force
}
$portableSizeMB = [math]::Round((Get-Item $portableZipPath).Length / 1MB, 1)
Write-Log ("  [OK] Portable size: {0} MB" -f $portableSizeMB)

# Generate SHA256SUMS.txt
Write-Log "Generating SHA256 checksums..."
$hash = Get-Sha256 $portableZipPath
$name = Split-Path $portableZipPath -Leaf
$sha256Line = ("{0}  {1}" -f $hash, $name)
Write-Log ("  {0}  {1}" -f $name, $hash)
$sha256Path = Join-Path $ReleaseDir $Sha256FileName
# 内容全是十六进制哈希值 + 文件名，纯 ASCII，没有必要用 UTF8——
# Windows PowerShell 5.1（Windows 7 打包机大概率是这个版本）的
# "-Encoding UTF8" 会在文件开头写入一个 BOM，有些校验工具（比如某些
# Linux 上的 sha256sum -c）解析这种带 BOM 的文件时，会把第一行的哈希值
# 解析错，导致校验"莫名其妙"失败。改成 ascii 就不会有这个问题。
$sha256Line | Set-Content -Path $sha256Path -Encoding ascii
Write-Log ("  [OK] {0} written" -f $Sha256FileName)

# Upload to GitHub Release
if ($UploadRelease) {
    Write-Log "Uploading to GitHub Release..."
    
    if ($GitHubToken) {
        $env:GH_TOKEN = $GitHubToken
    }
    
    $authCheck = gh auth status 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Log "[ERROR] GitHub CLI not authenticated. Run: gh auth login"
        exit 1
    }
    
    Write-Log ("  Checking/creating Release tag: {0}" -f $TagName)
        $releaseExists = gh release view $TagName --repo ("{0}/{1}" -f $RepoOwner, $RepoName) 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Log "  Creating new Release..."
            # Extract only current version section from CHANGELOG.md
            $changelogPath = Join-Path $ProjectRoot "CHANGELOG.md"
            $changelog = Get-Content $changelogPath -Raw -Encoding UTF8
            $escapedVersion = [regex]::Escape($Version)
            $pattern = "(?s)##\s*\[$escapedVersion\].*?(?=##\s*\[|\z)"
            $currentNotes = ($changelog | Select-String -Pattern $pattern -AllMatches).Matches.Value
            if (-not $currentNotes) {
                Write-Log "[WARN] Could not extract notes for v$Version from CHANGELOG.md, using full file" "WARN"
                $currentNotes = $changelog
            }
            $notesFile = Join-Path $ReleaseDir ("RELEASE_NOTES_v{0}.md" -f $Version)
            $currentNotes | Set-Content -Path $notesFile -Encoding UTF8
        
            $releaseUrl = gh release create $TagName `
                --repo ("{0}/{1}" -f $RepoOwner, $RepoName) `
                --title $ReleaseTitle `
                --notes-file $notesFile `
                --generate-notes `
                2>&1
            if ($LASTEXITCODE -ne 0) { Write-Log ("[ERROR] Create Release failed: {0}" -f $releaseUrl); exit 1 }
        } else {
            Write-Log "  Release exists, uploading assets"
        }
    
    $assets = @($portableZipPath, $sha256Path)
    foreach ($asset in $assets) {
        $name = Split-Path $asset -Leaf
        Write-Log ("  Uploading {0} ..." -f $name)
        $result = gh release upload $TagName $asset --repo ("{0}/{1}" -f $RepoOwner, $RepoName) --clobber 2>&1
        if ($LASTEXITCODE -ne 0) { Write-Log ("[ERROR] Upload {0} failed: {1}" -f $name, $result); exit 1 }
    }
    
    Write-Log ("[OK] Release published: https://github.com/{0}/{1}/releases/tag/{2}" -f $RepoOwner, $RepoName, $TagName)
}

Write-Log "=== Build Release Complete ==="
Write-Log ("Release directory: {0}" -f $ReleaseDir)
$files = Get-ChildItem $ReleaseDir
foreach ($f in $files) {
    $sizeMB = [math]::Round($f.Length / 1MB, 1)
    Write-Log ("  {0} - {1} MB" -f $f.Name, $sizeMB)
}
if ($script:SourceSnapshotOk) {
    $sizeMB = [math]::Round((Get-Item $SourceSnapshotZip).Length / 1MB, 1)
    Write-Log ("  Source snapshot: {0} - {1} MB" -f (Split-Path $SourceSnapshotZip -Leaf), $sizeMB)
} elseif (-not $SkipSourceSnapshot -and -not $SkipBuild) {
    # 明确提醒一下"这次没有可用的源码快照"，而不是什么都不说、
    # 靠用户自己回头翻日志才发现——万一真出问题需要回滚，这时候才
    # 发现根本没有快照可用就晚了。
    Write-Log "  [WARN] No source snapshot was created this run" "WARN"
}
Write-Log ""
Write-Log "Next steps:"
Write-Log "  1. Verify files in $ReleaseDir"
Write-Log "  2. Test portable package on Windows 7/10/11"
if ($script:SourceSnapshotOk) {
    Write-Log "  3. Source snapshot saved at: $SourceSnapshotZip"
    Write-Log "     Rollback: Expand-Archive -Path $SourceSnapshotZip -DestinationPath . -Force"
} else {
    Write-Log "  3. [WARN] No source snapshot available for rollback this run" "WARN"
}
if (-not $UploadRelease) {
    Write-Log ("  4. Run .\build-release.ps1 -Version {0} -UploadRelease to upload" -f $Version)
}