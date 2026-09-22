<#
=====================================================================
 Turtle WoW one-click installer (T-imothy/tortoise-wow, mantech-turtle)
 Everything - toolchain, dependencies, source, build, portable
 MariaDB, databases and game data - lives inside the folder that holds
 setup.bat.  Re-running resumes at the first unfinished step.

 Optional switches (normally you just double-click setup.bat):
   -Jobs 8                            parallel compile jobs
   -Update                            git pull + rebuild + apply new SQL
=====================================================================
#>
[CmdletBinding()]
param(
    [int]$Jobs = 0,
    [switch]$Update
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

# --- self-elevate to Administrator (needed for BindIP 0.0.0.0, firewall, and MariaDB service registration)
# If not already elevated, re-launch this script elevated and exit the non-elevated copy.
# Uses -Verb RunAs which triggers UAC prompt. Pass through Jobs/Update args.
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    try {
        $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"")
        if ($Jobs -ne 0) { $argList += @('-Jobs',"$Jobs") }
        if ($Update) { $argList += '-Update' }
        # Preserve any extra args passed to setup.bat
        $extra = @($args)
        if ($extra.Count -gt 0) { $argList += $extra }
        Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [WARN] Not running as Administrator - relaunching elevated (UAC)..." -ForegroundColor Yellow
        $proc = Start-Process -FilePath "powershell.exe" -ArgumentList $argList -Verb RunAs -PassThru -ErrorAction Stop
        $proc.WaitForExit()
        exit $proc.ExitCode
    } catch {
        Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [WARN] Failed to elevate to Administrator: $($_.Exception.Message) - continuing without elevation (may fail on bind/firewall)." -ForegroundColor Yellow
    }
}

# ------------------------------------------------------------------ layout
$Root      = $PSScriptRoot
$ToolsDir  = Join-Path $Root 'tools'
$SrcDir    = Join-Path $Root 'source'
$BuildDir  = Join-Path $Root 'build'
$ServerDir = Join-Path $Root 'server'
$DbDir     = Join-Path $Root 'database'
$StateDir  = Join-Path $Root '.state'
$LogFile   = Join-Path $Root 'setup.log'
$TempDir   = Join-Path $ToolsDir 'downloads'

$RepoUrl    = 'https://github.com/T-imothy/tortoise-wow.git'
$RepoBranch = 'mantech-turtle'

$Urls = @{
    cmake    = 'https://github.com/Kitware/CMake/releases/download/v3.31.6/cmake-3.31.6-windows-x86_64.zip'
    git      = 'https://github.com/git-for-windows/git/releases/download/v2.47.1.windows.1/MinGit-2.47.1-64-bit.zip'
    ninja    = 'https://github.com/ninja-build/ninja/releases/download/v1.12.1/ninja-win.zip'
    vsbt     = 'https://aka.ms/vs/17/release/vs_BuildTools.exe'
    mariadb  = 'https://archive.mariadb.org/mariadb-11.4.8/winx64-packages/mariadb-11.4.8-winx64.zip'
    vcpkg    = 'https://github.com/microsoft/vcpkg.git'
}

# Database settings (portable, private to this folder)
$DbPort     = 3310            # not 3306 on purpose: never collides with an existing MySQL
$DbRootPass = 'root'
$DbUser     = 'mangos'
$DbPass     = 'mangos'
$WorldPort  = 10081
$RealmPort  = 3724

# ------------------------------------------------------------------ helpers
function Log {
    param([string]$Msg, [string]$Level = 'INFO')
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Msg
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'STEP'  { Write-Host ""; Write-Host $line -ForegroundColor Cyan }
        'OK'    { Write-Host $line -ForegroundColor Green }
        default { Write-Host $line }
    }
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}
function Fail { param([string]$Msg) Log $Msg 'ERROR'; throw $Msg }
function Ensure-Dir { param([string]$P) if (-not (Test-Path -LiteralPath $P)) { New-Item -ItemType Directory -Path $P -Force | Out-Null } }
function Done   { param([string]$Step) Test-Path (Join-Path $StateDir "$Step.done") }
function Mark   { param([string]$Step) Set-Content -Path (Join-Path $StateDir "$Step.done") -Value (Get-Date) }
function Unmark { param([string]$Step) Remove-Item -LiteralPath (Join-Path $StateDir "$Step.done") -ErrorAction SilentlyContinue }

function Run {
    # Runs an external program, streams output to console+log, throws on non-zero exit.
    param([string]$Exe, [string[]]$Arguments, [string]$Cwd = $Root, [int[]]$OkCodes = @(0), [hashtable]$EnvVars = @{})
    $ErrorActionPreference = 'Continue'   # native stderr must not abort the pipeline
    Log ("> {0} {1}" -f $Exe, ($Arguments -join ' '))
    $old = @{}
    foreach ($k in $EnvVars.Keys) { $old[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $EnvVars[$k]) }
    Push-Location $Cwd
    try {
        & $Exe @Arguments 2>&1 | ForEach-Object { $s = "$_"; Write-Host $s; Add-Content -Path $LogFile -Value $s -Encoding UTF8 }
        $code = $LASTEXITCODE
    } finally {
        Pop-Location
        foreach ($k in $old.Keys) { [Environment]::SetEnvironmentVariable($k, $old[$k]) }
    }
    if ($OkCodes -notcontains $code) { Fail ("'{0}' failed with exit code {1}. See setup.log." -f (Split-Path $Exe -Leaf), $code) }
    return $code
}

function Download {
    param([string]$Url, [string]$Dest)
    $ErrorActionPreference = 'Continue'
    if (Test-Path -LiteralPath $Dest) { if ((Get-Item $Dest).Length -gt 0) { Log "Already downloaded: $(Split-Path $Dest -Leaf)"; return } }
    Ensure-Dir (Split-Path $Dest -Parent)
    $tmp = "$Dest.part"
    for ($i = 1; $i -le 4; $i++) {
        try {
            Log "Downloading ($i/4): $Url"
            Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
            $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
            if ($curl) {
                & $curl.Source -L --fail --retry 3 --connect-timeout 30 -o $tmp $Url
                if ($LASTEXITCODE -ne 0) { throw "curl exit $LASTEXITCODE" }
            } else {
                (New-Object System.Net.WebClient).DownloadFile($Url, $tmp)
            }
            if (-not (Test-Path $tmp) -or (Get-Item $tmp).Length -lt 1024) { throw "downloaded file is empty" }
            Move-Item -LiteralPath $tmp -Destination $Dest -Force
            return
        } catch {
            Log "Download attempt $i failed: $($_.Exception.Message)" 'WARN'
            Start-Sleep -Seconds (5 * $i)
        }
    }
    Fail "Could not download $Url - check your internet connection / firewall / proxy and run setup.bat again."
}

function Extract-Zip {
    param([string]$Zip, [string]$Dest)
    Ensure-Dir $Dest
    Log "Extracting $(Split-Path $Zip -Leaf) -> $Dest"
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($Zip, $Dest)
    } catch {
        # ExtractToDirectory refuses to overwrite; fall back to Expand-Archive -Force
        Expand-Archive -LiteralPath $Zip -DestinationPath $Dest -Force
    }
}

function Free-GB { param([string]$Path) [math]::Round((Get-PSDrive -Name ($Path.Substring(0,1))).Free / 1GB, 1) }

function Port-InUse { param([int]$Port)
    try { return [bool](Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) } catch { return $false }
}

function Set-Conf {
    # Replace "Key = value" in a mangos style .conf (first match, keeps comments). Appends if missing.
    param([string]$File, [string]$Key, [string]$Value)
    $content = Get-Content -LiteralPath $File -Raw
    $pattern = "(?m)^\s*" + [regex]::Escape($Key) + "\s*=.*$"
    if ($content -match $pattern) {
        $rx = New-Object System.Text.RegularExpressions.Regex($pattern)
        $content = $rx.Replace($content, ("$Key = $Value" -replace '\$','$$$$'), 1)
    } else {
        $content += "`r`n$Key = $Value`r`n"
    }
    [IO.File]::WriteAllText($File, $content, (New-Object System.Text.UTF8Encoding($false)))
}

function Sha1Hex { param([string]$Text)
    $sha = [System.Security.Cryptography.SHA1]::Create()
    ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)) | ForEach-Object { $_.ToString('X2') }) -join ''
}

# ------------------------------------------------------------------ start
Ensure-Dir $StateDir; Ensure-Dir $ToolsDir; Ensure-Dir $TempDir
Log "==================== Turtle WoW one-click setup ====================" 'STEP'
Log "Root folder: $Root"
# --- scan already finished steps and ask to skip them ---
$doneMarkers = Get-ChildItem $StateDir -Filter '*.done' -ErrorAction SilentlyContinue | Sort-Object Name
if ($doneMarkers -and -not $Update) {
    $doneNames = $doneMarkers | ForEach-Object { $_.BaseName }
    Log ("Found {0} completed step(s) from a previous run: {1}" -f $doneMarkers.Count, ($doneNames -join ', ')) 'INFO'
    Log "The installer will SKIP those steps and resume where it stopped. This is the normal resume behaviour." 'INFO'
    $isInteractive = $Host.Name -match 'ConsoleHost' -and -not [Console]::IsInputRedirected -and $env:TERM_PROGRAM -ne 'vscode'
    if ($isInteractive) {
        $answer = ""
        # loop until Y/N or timeout 60s (so unattended re-runs don't hang)
        $timeout = 60
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($answer -notin @('Y','N','y','n') -and $sw.Elapsed.TotalSeconds -lt $timeout) {
            if ($sw.Elapsed.TotalSeconds -gt 5 -and $answer -eq "") {
                # after 5s of no input, assume resume (common when double-clicked and user walks away)
                break
            }
            try {
                $answer = Read-Host "Resume and skip completed steps? [Y/n] (auto-Y in 60s)"
                if ([string]::IsNullOrWhiteSpace($answer)) { $answer = 'Y' }
            } catch { break }
        }
        if ($answer -match '^[nN]') {
            Log "User chose N - clearing all .done markers and starting over." 'WARN'
            Remove-Item (Join-Path $StateDir '*.done') -Force -ErrorAction SilentlyContinue
            Log "All steps will re-run from the beginning." 'WARN'
        } else {
            Log ("Resuming - skipping: {0}" -f ($doneNames -join ', ')) 'OK'
        }
    } else {
        Log ("Non-interactive session - auto-resuming, skipping: {0}" -f ($doneNames -join ', ')) 'INFO'
    }
} elseif ($Update) {
    Log "Update mode: will re-pull source and rebuild." 'INFO'
}

# ------------------------------------------------------------------ 0. sanity checks
Log "Step 0/9  Checking this machine" 'STEP'
if (-not [Environment]::Is64BitOperatingSystem) { Fail "A 64-bit Windows is required." }
if ($PSVersionTable.PSVersion.Major -lt 5)      { Fail "Windows PowerShell 5.1 or newer is required (Windows 10/11 has it)." }
if ($Root.StartsWith('\\')) { Fail "Run this from a local drive (C:\...), not from a network path." }
if ($Root -match '\s')  { Fail "The folder path '$Root' contains spaces. vcpkg/ACE cannot build in such a path. Move this folder to e.g. C:\TurtleWoW and run again." }
if ($Root -match '[^\x00-\x7F]') { Fail "The folder path contains non-ASCII characters (e.g. Cyrillic). Move this folder to e.g. C:\TurtleWoW and run again." }
if ($Root.Length -gt 60) { Log "The folder path is long ($($Root.Length) chars). If the build fails with 'path too long', move this folder closer to the drive root (e.g. C:\TurtleWoW)." 'WARN' }
$free = Free-GB $Root
Log "Free disk space on $($Root.Substring(0,2)): $free GB"
if ($free -lt 40) { Fail "At least 40 GB of free disk space are needed (compiler ~8 GB, dependencies ~6 GB, build ~12 GB, database ~4 GB, game data ~6 GB). Only $free GB free." }
$cores = [Environment]::ProcessorCount
$ramGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
if ($Jobs -le 0) { $Jobs = [math]::Max(1, [math]::Min($cores, [math]::Floor($ramGB / 1.5))) }
Log "CPU cores: $cores, RAM: $ramGB GB, compile jobs: $Jobs"
if ($ramGB -lt 8) { Log "Less than 8 GB RAM: compiling will be slow and running 100 bots may be tight." 'WARN' }
$UseLTO = if ($ramGB -ge 16) { 'ON' } else { 'OFF' }

# ------------------------------------------------------------------ 1. portable tools
Log "Step 1/9  Portable tools (CMake, Git, Ninja)" 'STEP'
$CMakeExe = Join-Path $ToolsDir 'cmake\bin\cmake.exe'
if (-not (Test-Path $CMakeExe)) {
    $zip = Join-Path $TempDir 'cmake.zip'; Download $Urls.cmake $zip
    $tmp = Join-Path $TempDir 'cmake_x'; Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Extract-Zip $zip $tmp
    $inner = Get-ChildItem $tmp -Directory | Select-Object -First 1
    Remove-Item (Join-Path $ToolsDir 'cmake') -Recurse -Force -ErrorAction SilentlyContinue
    Move-Item $inner.FullName (Join-Path $ToolsDir 'cmake')
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
if (-not (Test-Path $CMakeExe)) { Fail "CMake extraction failed." }
Log "CMake: $(& $CMakeExe --version | Select-Object -First 1)" 'OK'

$GitExe = Join-Path $ToolsDir 'git\cmd\git.exe'
if (-not (Test-Path $GitExe)) {
    $zip = Join-Path $TempDir 'mingit.zip'; Download $Urls.git $zip
    Extract-Zip $zip (Join-Path $ToolsDir 'git')
}
if (-not (Test-Path $GitExe)) { Fail "Git extraction failed." }
Log "Git: $(& $GitExe --version)" 'OK'

$NinjaExe = Join-Path $ToolsDir 'ninja\ninja.exe'
if (-not (Test-Path $NinjaExe)) {
    $zip = Join-Path $TempDir 'ninja.zip'; Download $Urls.ninja $zip
    Extract-Zip $zip (Join-Path $ToolsDir 'ninja')
}
if (-not (Test-Path $NinjaExe)) { Fail "Ninja extraction failed." }
Log "Ninja: $(& $NinjaExe --version)" 'OK'

$env:PATH = "$(Split-Path $CMakeExe);$(Split-Path $GitExe);$(Split-Path $NinjaExe);$env:PATH"
$env:GIT_CONFIG_COUNT = 1; $env:GIT_CONFIG_KEY_0 = 'core.longpaths'; $env:GIT_CONFIG_VALUE_0 = 'true'

# ------------------------------------------------------------------ 2. MSVC compiler
Log "Step 2/9  Visual C++ compiler (Build Tools)" 'STEP'
function Find-VsDevCmd {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path $vswhere)) { return $null }
    $paths = & $vswhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath -prerelease 2>$null
    foreach ($p in @($paths)) {
        if (-not $p) { continue }
        $cmd = Join-Path $p 'Common7\Tools\VsDevCmd.bat'
        if (Test-Path $cmd) { return $cmd }
    }
    return $null
}
$VsDevCmd = Find-VsDevCmd
if (-not $VsDevCmd) {
    Log "No Visual C++ toolchain found. Installing Visual Studio 2022 Build Tools into $ToolsDir\BuildTools (Windows will show a UAC prompt - please accept it). This downloads ~2 GB and takes 10-30 minutes." 'WARN'
    $bt = Join-Path $TempDir 'vs_BuildTools.exe'; Download $Urls.vsbt $bt
    $btArgs = @('--passive','--norestart','--wait','--nocache',
                '--installPath', (Join-Path $ToolsDir 'BuildTools'),
                '--add','Microsoft.VisualStudio.Workload.VCTools','--includeRecommended')
    $p = Start-Process -FilePath $bt -ArgumentList $btArgs -Wait -PassThru
    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) { Fail "Visual Studio Build Tools installer returned $($p.ExitCode). Run setup.bat again; if it keeps failing install 'Desktop development with C++' manually from https://visualstudio.microsoft.com/downloads/ and re-run." }
    if ($p.ExitCode -eq 3010) { Log "Build Tools asks for a reboot. Please reboot, then double-click setup.bat again - it will continue." 'WARN'; exit 3010 }
    $VsDevCmd = Find-VsDevCmd
    if (-not $VsDevCmd) { Fail "Build Tools were installed but the C++ toolchain is still not detected. Reboot and run setup.bat again." }
}
Log "Using: $VsDevCmd" 'OK'

# Import the developer environment (cl.exe, link.exe, Windows SDK) into this process.
$envLines = & "$env:ComSpec" /d /s /c "`"$VsDevCmd`" -arch=x64 -host_arch=x64 -no_logo >nul && set"
if ($LASTEXITCODE -ne 0) { Fail "VsDevCmd.bat failed - the C++ toolchain is damaged. Repair it via the Visual Studio Installer." }
foreach ($line in $envLines) { $i = $line.IndexOf('='); if ($i -gt 0) { Set-Item -LiteralPath ("Env:" + $line.Substring(0,$i)) -Value $line.Substring($i+1) } }
if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) { Fail "cl.exe not found after loading the VS environment." }
$env:PATH = "$(Split-Path $CMakeExe);$(Split-Path $GitExe);$(Split-Path $NinjaExe);$env:PATH"
Log "MSVC ready: $((cmd /c "cl.exe 2>&1" | Select-Object -First 1))" 'OK'

# ------------------------------------------------------------------ 3. source code
Log "Step 3/9  Source code ($RepoBranch)" 'STEP'
if (-not (Test-Path (Join-Path $SrcDir '.git'))) {
    Remove-Item $SrcDir -Recurse -Force -ErrorAction SilentlyContinue
    Run $GitExe @('clone','--branch',$RepoBranch,'--single-branch',$RepoUrl,$SrcDir)
    Unmark 'submodules'
} elseif ($Update) {
    Run $GitExe @('-C',$SrcDir,'pull','--ff-only')
    Unmark 'submodules'; Unmark 'configure'; Unmark 'build'; Unmark 'install'; Unmark 'sql-updates'
}
if (-not (Done 'submodules')) {
    # Only the modules this branch actually builds: ManTechPlayerbots (the bots) and Eluna (for the CMake check).
    Run $GitExe @('-C',$SrcDir,'submodule','update','--init','--depth','1','modules/ManTechPlayerbots')
    Run $GitExe @('-C',$SrcDir,'submodule','update','--init','--depth','1','src/modules/Eluna') -OkCodes @(0,1)
    if (-not (Test-Path (Join-Path $SrcDir 'modules\ManTechPlayerbots\ManTechPlayerbots.cmake'))) { Fail "ManTechPlayerbots submodule is missing after checkout." }
    Mark 'submodules'
}
Log "Source ready: $(& $GitExe -C $SrcDir log -1 --format='%h %s')" 'OK'

# ------------------------------------------------------------------ 4. vcpkg deps (ACE + Boost)
Log "Step 4/9  Dependencies via vcpkg (ACE, Boost) - first time 20-60 minutes" 'STEP'
$VcpkgDir = Join-Path $ToolsDir 'vcpkg'
$VcpkgExe = Join-Path $VcpkgDir 'vcpkg.exe'
$DepsDir  = Join-Path $VcpkgDir 'installed\x64-windows'
$VcpkgTriplet = 'x64-windows'
$env:VCPKG_ROOT = $VcpkgDir
$env:VCPKG_DOWNLOADS = Join-Path $ToolsDir 'vcpkg-downloads'
$env:VCPKG_DEFAULT_BINARY_CACHE = Join-Path $ToolsDir 'vcpkg-cache'
$env:VCPKG_DISABLE_METRICS = '1'
$env:VCPKG_FEATURE_FLAGS = 'manifests,registries'
Ensure-Dir $env:VCPKG_DOWNLOADS; Ensure-Dir $env:VCPKG_DEFAULT_BINARY_CACHE
if (-not (Test-Path (Join-Path $VcpkgDir '.git'))) {
    Remove-Item $VcpkgDir -Recurse -Force -ErrorAction SilentlyContinue
    Run $GitExe @('clone','--depth','1',$Urls.vcpkg,$VcpkgDir)
}
if (-not (Test-Path $VcpkgExe)) {
    try { Run (Join-Path $VcpkgDir 'bootstrap-vcpkg.bat') @('-disableMetrics') $VcpkgDir }
    catch {
        Log "bootstrap-vcpkg failed, retrying after 5s: $($_.Exception.Message)" 'WARN'
        Start-Sleep -Seconds 5
        Run (Join-Path $VcpkgDir 'bootstrap-vcpkg.bat') @('-disableMetrics') $VcpkgDir
    }
}
# The running server locks ACE.dll / boost DLLs and vcpkg cannot overwrite them.
Get-Process -Name 'mangosd','realmd','mariadbd','MoveMapGen','vmapextractor','mapextractor','vmap_assembler' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1
$ports = @('ace','boost-algorithm','boost-asio','boost-bimap','boost-bind','boost-callable-traits','boost-filesystem',
           'boost-functional','boost-smart-ptr','boost-stacktrace','boost-thread','boost-system')
$needVcpkg = (-not (Done 'vcpkg')) -or -not (Test-Path (Join-Path $DepsDir 'include\ace\ACE.h')) -or -not (Test-Path (Join-Path $DepsDir 'include\boost\filesystem.hpp')) -or -not (Get-ChildItem (Join-Path $DepsDir 'lib\boost_thread*.lib') -ErrorAction SilentlyContinue) -or -not (Test-Path (Join-Path $DepsDir 'lib\ACE.lib'))
if ($needVcpkg) {
    if ((Test-Path $DepsDir) -and -not (Test-Path (Join-Path $DepsDir 'include\ace\ACE.h'))) {
        Log "Cleaning incomplete vcpkg tree before reinstall..." 'WARN'
        Remove-Item $DepsDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $VcpkgDir 'buildtrees') -Recurse -Force -ErrorAction SilentlyContinue
    }
    $vcpkgArgs = @('install') + ($ports | ForEach-Object { "$($_):$VcpkgTriplet" }) + @('--clean-after-build','--recurse')
    try {
        Run $VcpkgExe $vcpkgArgs $VcpkgDir
    } catch {
        Log "vcpkg install failed, cleaning and retrying once: $($_.Exception.Message)" 'WARN'
        Remove-Item $DepsDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $VcpkgDir 'buildtrees') -Recurse -Force -ErrorAction SilentlyContinue
        Run $VcpkgExe $vcpkgArgs $VcpkgDir
    }
    $aceHeader = Join-Path $DepsDir 'include\ace\ACE.h'
    $aceLib    = Join-Path $DepsDir 'lib\ACE.lib'
    $boostHeader = Join-Path $DepsDir 'include\boost\filesystem.hpp'
    $boostLibGlob = Join-Path $DepsDir 'lib\boost_thread*.lib'
    if (-not (Test-Path $aceHeader))   { Fail "ACE headers missing after vcpkg ($aceHeader). Check setup.log and tools\vcpkg\buildtrees\ace\*.log" }
    if (-not (Test-Path $aceLib))      { Fail "ACE library missing after vcpkg ($aceLib). ACE was built static - this build needs the DLL triplet $VcpkgTriplet." }
    if (-not (Test-Path $boostHeader)) { Fail "Boost headers missing after vcpkg ($boostHeader)." }
    if (-not (Get-ChildItem $boostLibGlob -ErrorAction SilentlyContinue)) { Fail "Boost thread library missing ($boostLibGlob). Boost build failed - see tools\vcpkg\buildtrees\boost-thread\*.log" }
    if (-not (Test-Path (Join-Path $DepsDir 'include\boost\callable_traits\args.hpp'))) { Fail "Boost callable_traits headers missing - vcpkg Boost tree is incomplete." }
    if (-not (Test-Path (Join-Path $DepsDir 'include\boost\asio.hpp'))) { Fail "Boost asio headers missing - vcpkg Boost tree incomplete." }
    Mark 'vcpkg'
}
$env:ACE_ROOT = $DepsDir
$env:BOOST_ROOT = $DepsDir
$env:BOOST_LIBRARYDIR = Join-Path $DepsDir 'lib'
Log "Dependencies ready in $DepsDir" 'OK'

# ------------------------------------------------------------------ 5. configure + build
Log "Step 5/9  Configure and compile (30-90 minutes on first run)" 'STEP'
Ensure-Dir $BuildDir; Ensure-Dir $ServerDir
$prefixCMake = $ServerDir -replace '\\','/'
$depsCMake   = $DepsDir  -replace '\\','/'
$binCMake    = (Join-Path $BuildDir 'bin') -replace '\\','/'
if (-not (Done 'configure') -or -not (Test-Path (Join-Path $BuildDir 'build.ninja'))) {
    $vcpkgToolchain = (Join-Path $VcpkgDir 'scripts\buildsystems\vcpkg.cmake') -replace '\\','/'
    if (-not (Test-Path $vcpkgToolchain)) { Fail "vcpkg toolchain not found at $vcpkgToolchain - vcpkg checkout is incomplete." }
    # Extra safety: ACE/Boost env vars are also read by the project's own CMake
    # (FindACE, and mangosd's BOOST_LIBRARYDIR hack). Set them for this process
    # so the child cmake inherits them even if -D vars are missed.
    $env:ACE_ROOT = $DepsDir
    $env:BOOST_ROOT = $DepsDir
    $env:BOOST_LIBRARYDIR = Join-Path $DepsDir 'lib'
    $cfg = @('-S',$SrcDir,'-B',$BuildDir,'-G','Ninja',
        "-DCMAKE_MAKE_PROGRAM=$($NinjaExe -replace '\\','/')",
        '-DCMAKE_BUILD_TYPE=Release',
        "-DCMAKE_INSTALL_PREFIX=$prefixCMake",
        "-DCMAKE_RUNTIME_OUTPUT_DIRECTORY=$binCMake",
        "-DCMAKE_TOOLCHAIN_FILE=$vcpkgToolchain",
        "-DVCPKG_TARGET_TRIPLET=$VcpkgTriplet",
        "-DVCPKG_MANIFEST_MODE=OFF",
        "-DCMAKE_PREFIX_PATH=$depsCMake",
        "-DACE_ROOT=$depsCMake",
        "-DBoost_ROOT=$depsCMake",
        # exactly the maintainer's production selection (dev/build-mantech.ps1)
        '-DBUILD_PLAYERBOTS=ON',
        '-DMODULES=disabled',
        '-DMODULE_MANTECHPLAYERBOTS=static',
        '-DMODULE_TORTOISEBOTS=disabled',
        '-DMODULE_MOD_PLAYERBOTS=disabled',
        '-DBUILD_ELUNA=OFF',
        '-DENABLE_SOAP=ON',
        '-DUSE_EXTRACTORS=ON',
        '-DUSE_PCH=ON','-DUSE_PCH_OLD=ON',
        '-DUSE_DISCORD_BOT=OFF',
        "-DENABLE_LTO=$UseLTO",
        '-DALLOW_TURTLE_ADDONS=ON')
    if (Test-Path (Join-Path $BuildDir 'CMakeCache.txt')) { $cfg = @('--fresh') + $cfg }
    Run $CMakeExe $cfg $BuildDir
    Mark 'configure'; Unmark 'build'
}
if (-not (Done 'build')) {
    $code = Run $CMakeExe @('--build',$BuildDir,'--parallel',"$Jobs") $BuildDir -OkCodes @(0,1)
    if ($code -ne 0) {
        Log "Build failed. Retrying once single-threaded to get a readable error (out-of-memory on parallel builds is common)..." 'WARN'
        Run $CMakeExe @('--build',$BuildDir,'--parallel','1') $BuildDir
    }
    foreach ($exe in 'mangosd.exe','realmd.exe','mapextractor.exe','vmapextractor.exe','vmap_assembler.exe','MoveMapGen.exe') {
        if (-not (Test-Path (Join-Path $BuildDir "bin\$exe"))) { Fail "Build finished but $exe was not produced." }
    }
    Mark 'build'; Unmark 'install'
}
Log "Compiled OK" 'OK'

# ------------------------------------------------------------------ 6. install into server\
Log "Step 6/9  Installing server files into $ServerDir" 'STEP'
if (-not (Done 'install')) {
    Run $CMakeExe @('--install',$BuildDir,'--config','Release') $BuildDir
    # --- extractors: ensure the four exes land safely in server\ ---
    # cmake installs mapextractor, vmap_assembler and MoveMapGen (BIN_DIR == prefix
    # on Windows). vmap_extractor has NO install rule and lives only in build/bin.
    # Copy from build/bin over the installed copy so the version always matches
    # the just-built server, and verify every exe is present.
    foreach ($exe in 'mapextractor.exe','vmapextractor.exe','vmap_assembler.exe','MoveMapGen.exe') {
        $fromBuild = Join-Path $BuildDir "bin\$exe"
        $toServer  = Join-Path $ServerDir $exe
        if (Test-Path $fromBuild) { Copy-Item $fromBuild $toServer -Force }
        if (-not (Test-Path $toServer)) { Fail "$exe was not produced and could not be copied to server\. Build with USE_EXTRACTORS=ON failed - see setup.log." }
    }
    # runtime DLLs from vcpkg (ACE + Boost). Release bin only.
    $vcpkgDlls = Get-ChildItem (Join-Path $DepsDir 'bin') -Filter '*.dll' -ErrorAction SilentlyContinue
    if (-not $vcpkgDlls) { Fail "No DLLs found in $DepsDir\bin - vcpkg ACE/Boost DLLs are missing (expected ACE.dll, boost_*.dll). vcpkg install may have used a static triplet." }
    $vcpkgDlls | Copy-Item -Destination $ServerDir -Force
    # bundled MySQL / OpenSSL 1.1 DLLs (cmake installs them, double check)
    $bundledDlls = Get-ChildItem (Join-Path $SrcDir 'dep\windows\lib\x64_release') -Filter '*.dll' -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch 'Optick|eay32' }
    if (-not $bundledDlls) { Fail "Bundled MySQL/OpenSSL DLLs missing in source\dep\windows\lib\x64_release." }
    $bundledDlls | Copy-Item -Destination $ServerDir -Force
    # final verification: the three DLLs the server cannot start without
    foreach ($need in @('ACE.dll','libmySQL.dll')) {
        if (-not (Test-Path (Join-Path $ServerDir $need))) { Fail "$need is missing in server\ after install - DLL copy failed." }
    }
    $sslDll = Get-ChildItem $ServerDir -Filter 'libssl*.dll' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $sslDll) { Fail "libssl DLL is missing in server\ after install (expected libssl-1_1-x64.dll or libssl-3-x64.dll)." }
    $cryptoDll = Get-ChildItem $ServerDir -Filter 'libcrypto*.dll' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cryptoDll) { Fail "libcrypto DLL is missing in server\ after install." }
    # configs: template -> live copy (never overwrite an existing live config)
    foreach ($c in 'mangosd','realmd','aiplayerbot','ahbot') {
        $dist = Join-Path $ServerDir "$c.conf.dist"
        if (-not (Test-Path $dist)) {
            $alt = Get-ChildItem $BuildDir -Recurse -Filter "$c.conf.dist" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($alt) { Copy-Item $alt.FullName $dist -Force }
        }
        if (-not (Test-Path $dist)) { Fail "$c.conf.dist was not generated by the build." }
        if (-not (Test-Path (Join-Path $ServerDir "$c.conf"))) { Copy-Item $dist (Join-Path $ServerDir "$c.conf") }
    }
    # mmap generator inputs (needed by MoveMapGen)
    Ensure-Dir (Join-Path $ServerDir 'data'); Ensure-Dir (Join-Path $ServerDir 'logs')
    Copy-Item (Join-Path $SrcDir 'tools\mmap\offmesh.txt')      (Join-Path $ServerDir 'data') -Force
    Copy-Item (Join-Path $SrcDir 'tools\mmap\mmapSettings.txt') (Join-Path $ServerDir 'data') -Force
    if (-not (Test-Path (Join-Path $ServerDir 'data\offmesh.txt'))) { Fail "offmesh.txt not copied to server\data - MoveMapGen will fail later." }
    Mark 'install'; Unmark 'configs'
}
foreach ($exe in 'mangosd.exe','realmd.exe','mapextractor.exe','vmapextractor.exe','vmap_assembler.exe','MoveMapGen.exe','ACE.dll','libmySQL.dll') { if (-not (Test-Path (Join-Path $ServerDir $exe))) { Fail "$exe is missing in server\ after install." } }
Log "Server files installed (including 4 extractors in server\)" 'OK'

# ------------------------------------------------------------------ 7. portable MariaDB
Log "Step 7/9  Portable MariaDB database" 'STEP'
$MariaDir  = Join-Path $DbDir 'mariadb'
$MariaBin  = Join-Path $MariaDir 'bin'
$DataDir   = Join-Path $DbDir 'data'
$MyIni     = Join-Path $DbDir 'my.ini'
$MysqldExe = Join-Path $MariaBin 'mariadbd.exe'
$MysqlExe  = Join-Path $MariaBin 'mariadb.exe'
if (-not (Test-Path $MysqlExe)) { $MysqlExe = Join-Path $MariaBin 'mysql.exe' }
$AdminExe  = Join-Path $MariaBin 'mariadb-admin.exe'
if (-not (Test-Path $AdminExe)) { $AdminExe = Join-Path $MariaBin 'mysqladmin.exe' }
# mysql_install_db legacy name (MariaDB <10.5 zip used mysql_install_db.exe)
$InstallDbCandidates = @((Join-Path $MariaBin 'mariadb-install-db.exe'), (Join-Path $MariaBin 'mysql_install_db.exe'), (Join-Path $MariaBin 'mariadb-install-db'))
if (-not (Test-Path $MysqldExe)) {
    $zip = Join-Path $TempDir 'mariadb.zip'; Download $Urls.mariadb $zip
    $tmp = Join-Path $TempDir 'mariadb_x'; Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Extract-Zip $zip $tmp
    $inner = Get-ChildItem $tmp -Directory | Select-Object -First 1
    if (-not $inner) { Fail "MariaDB zip extraction produced no top-level folder." }
    Remove-Item $MariaDir -Recurse -Force -ErrorAction SilentlyContinue
    Ensure-Dir $DbDir
    Move-Item $inner.FullName $MariaDir
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    # sanity: the zip must contain the server binary
    if (-not (Test-Path (Join-Path $MariaBin 'mariadbd.exe')) -and -not (Test-Path (Join-Path $MariaDir 'bin\mysqld.exe'))) {
        # some archives name it mysqld.exe
        $alt = Get-ChildItem $MariaDir -Recurse -Filter 'mariadbd.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $alt) { $alt = Get-ChildItem $MariaDir -Recurse -Filter 'mysqld.exe' -ErrorAction SilentlyContinue | Select-Object -First 1 }
        if ($alt) { $MysqldExe = $alt.FullName; $MariaBin = Split-Path $MysqldExe; $MysqlExe = Join-Path $MariaBin 'mariadb.exe'; $AdminExe = Join-Path $MariaBin 'mariadb-admin.exe' }
    }
}
# Re-resolve after extraction (name may be mysqld.exe on older zips)
if (-not (Test-Path $MysqldExe)) {
    $alt = Get-ChildItem $MariaDir -Recurse -Filter 'mariadbd.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($alt) { $MysqldExe = $alt.FullName; $MariaBin = Split-Path $MysqldExe; $MysqlExe = Join-Path $MariaBin 'mariadb.exe'; if (-not (Test-Path $MysqlExe)) { $MysqlExe = Join-Path $MariaBin 'mysql.exe' }; $AdminExe = Join-Path $MariaBin 'mariadb-admin.exe'; if (-not (Test-Path $AdminExe)) { $AdminExe = Join-Path $MariaBin 'mysqladmin.exe' } }
}
if (-not (Test-Path $MysqldExe)) { Fail "MariaDB extraction failed - server binary not found under $MariaDir." }
if (-not (Test-Path $MysqlExe))  { Fail "MariaDB client not found ($MysqlExe) - archive is incomplete." }
if (-not (Test-Path $AdminExe))  { Fail "MariaDB admin client not found ($AdminExe)." }

# start-database.bat regenerates my.ini every start, so the folder can be moved anywhere.
$startDb = @"
@echo off
:: Starts the portable MariaDB that belongs to this Turtle WoW folder.
:: Safe to double-click any time: if it is already running nothing happens.
setlocal
title Turtle WoW - Database
set "ROOT=%~dp0"
set "ROOT=%ROOT:~0,-1%"
set "DB=%ROOT%\database"
set "BIN=%DB%\mariadb\bin"
set "PORT=$DbPort"
set "DAEMON=mariadbd.exe"
if not exist "%BIN%\mariadbd.exe" set "DAEMON=mysqld.exe"
if not exist "%BIN%\%DAEMON%" (
    echo [ERROR] %BIN%\%DAEMON% not found. Run setup.bat first.
    timeout /t 5 >nul & exit /b 1
)
if not exist "%DB%\data\mysql" (
    echo [ERROR] Database data folder is not initialised. Run setup.bat.
    timeout /t 5 >nul & exit /b 1
)
if exist "%BIN%\mariadb-admin.exe" set "ADMIN=mariadb-admin.exe"
if not exist "%BIN%\mariadb-admin.exe" set "ADMIN=mysqladmin.exe"
:: Rewrite my.ini with the current absolute paths (portable).
set "FDB=%DB:\=/%"
echo [client] > "%DB%\my.ini"
echo port=%PORT% >> "%DB%\my.ini"
echo socket=MySQL >> "%DB%\my.ini"
echo [mysqld] >> "%DB%\my.ini"
echo basedir=%FDB%/mariadb >> "%DB%\my.ini"
echo datadir=%FDB%/data >> "%DB%\my.ini"
echo tmpdir=%FDB%/tmp >> "%DB%\my.ini"
echo port=%PORT% >> "%DB%\my.ini"
echo bind-address=127.0.0.1 >> "%DB%\my.ini"
echo character-set-server=utf8mb4 >> "%DB%\my.ini"
echo collation-server=utf8mb4_general_ci >> "%DB%\my.ini"
echo sql_mode=NO_ENGINE_SUBSTITUTION >> "%DB%\my.ini"
echo innodb_strict_mode=0 >> "%DB%\my.ini"
echo innodb_buffer_pool_size=1G >> "%DB%\my.ini"
echo innodb_flush_log_at_trx_commit=2 >> "%DB%\my.ini"
echo innodb_file_per_table=1 >> "%DB%\my.ini"
echo innodb_use_native_aio=0 >> "%DB%\my.ini"
echo max_allowed_packet=256M >> "%DB%\my.ini"
echo max_connections=200 >> "%DB%\my.ini"
echo table_open_cache=4000 >> "%DB%\my.ini"
echo wait_timeout=86400 >> "%DB%\my.ini"
echo secure_file_priv="" >> "%DB%\my.ini"
echo log_error=%FDB%/mariadb-error.log >> "%DB%\my.ini"
if not exist "%DB%\tmp" mkdir "%DB%\tmp"
:: Already running?
"%BIN%\%ADMIN%" --protocol=tcp -h 127.0.0.1 -P %PORT% -u root -p$DbRootPass ping >nul 2>&1
if "%ERRORLEVEL%"=="0" (
    echo Database is already running on port %PORT%.
    exit /b 0
)
netstat -ano | findstr /R /C:":%PORT% .*LISTENING" >nul 2>&1
if "%ERRORLEVEL%"=="0" (
    echo [ERROR] Port %PORT% is used by another program. Close it or change DbPort in setup and the *.conf files.
    timeout /t 5 >nul
    exit /b 1
)
echo Starting MariaDB on 127.0.0.1:%PORT% ...
start "TurtleWoW-MariaDB" /MIN "%BIN%\%DAEMON%" --defaults-file="%DB%\my.ini" --console
:: Wait until it answers (max ~60 s)
set /a tries=0
:wait
set /a tries+=1
"%BIN%\%ADMIN%" --protocol=tcp -h 127.0.0.1 -P %PORT% -u root -p$DbRootPass ping >nul 2>&1
if "%ERRORLEVEL%"=="0" goto up
if %tries% GEQ 60 (
    echo [ERROR] MariaDB did not start. See database\mariadb-error.log
    type "%DB%\mariadb-error.log" 2>nul
    timeout /t 5 >nul
    exit /b 1
)
timeout /t 1 /nobreak >nul
goto wait
:up
echo Database is UP  (port %PORT%, user $DbUser / $DbPass, root / $DbRootPass)
exit /b 0
"@
Set-Content -Path (Join-Path $Root 'start-database.bat') -Value $startDb -Encoding ASCII

$stopDb = @"
@echo off
title Turtle WoW - Stop Database
setlocal
set "ROOT=%~dp0"
set "ROOT=%ROOT:~0,-1%"
set "BIN=%ROOT%\database\mariadb\bin"
if exist "%BIN%\mariadb-admin.exe" set "ADMIN=mariadb-admin.exe"
if not exist "%BIN%\mariadb-admin.exe" set "ADMIN=mysqladmin.exe"
"%BIN%\%ADMIN%" --protocol=tcp -h 127.0.0.1 -P $DbPort -u root -p$DbRootPass shutdown
if "%ERRORLEVEL%"=="0" (
    echo Database stopped.
) else (
    echo Database was not running.
)
timeout /t 3 >nul
"@
Set-Content -Path (Join-Path $Root 'stop-database.bat') -Value $stopDb -Encoding ASCII

# --- initialise data dir (with corruption detection) ---
$mysqlSubdir = Join-Path $DataDir 'mysql'
$ibdata = Join-Path $DataDir 'ibdata1'
$needsInit = $false
if (-not (Test-Path $mysqlSubdir)) { $needsInit = $true }
elseif (-not (Test-Path $ibdata))  { Log "Data dir exists but ibdata1 is missing - incomplete init, will re-create." 'WARN'; $needsInit = $true }
elseif ((Get-ChildItem $mysqlSubdir -ErrorAction SilentlyContinue | Measure-Object).Count -lt 5) { Log "mysql subdir looks empty/corrupted - will re-create." 'WARN'; $needsInit = $true }

if ($needsInit) {
    if (Port-InUse $DbPort) { Fail "Port $DbPort is already in use by another program. Free it and run setup.bat again." }
    # Kill any stale daemon that might hold locks on the data dir
    Get-Process -Name 'mariadbd','mysqld' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    if (Test-Path $DataDir) { Remove-Item $DataDir -Recurse -Force -ErrorAction SilentlyContinue }
    Ensure-Dir $DataDir
    Ensure-Dir (Join-Path $DbDir 'tmp')
    $installDb = $null
    foreach ($cand in $InstallDbCandidates) { if (Test-Path $cand) { $installDb = $cand; break } }
    if (-not $installDb) { Fail "MariaDB install helper not found (looked for mariadb-install-db.exe / mysql_install_db.exe under $MariaBin)." }
    # --allow-remote-root-access lets root connect via TCP (127.0.0.1) as well as socket
    Log "Initializing data dir with $installDb --datadir=$DataDir --password=*** --port=$DbPort" 'INFO'
    Run $installDb @("--datadir=$DataDir","--password=$DbRootPass","--port=$DbPort","--allow-remote-root-access") $DbDir
    Log "mariadb-install-db finished with exit 0" 'OK'
    if (-not (Test-Path $mysqlSubdir)) { Fail "MariaDB data dir init finished but $mysqlSubdir is still missing - see setup.log and database\\mariadb-error.log" }
    if (-not (Test-Path $ibdata)) { Log "Warning: ibdata1 not found after init - InnoDB may create it on first start." 'WARN' }
    # Fresh data dir: mariadb-install-db on 11.4 does not create ib_logfile0, the server will create it on first start.
    # Keep default 96M log file size for initial files and use redo capacity for performance - don't delete.
    Log "Fresh data dir initialized." 'INFO'
    Unmark 'db-schema'
    Unmark 'sql-updates'; Unmark 'db-bots'; Unmark 'db-realm'
}

function Db-Up {
    $ErrorActionPreference = 'Continue'
    & $AdminExe --protocol=tcp -h 127.0.0.1 -P $DbPort -u root "-p$DbRootPass" --connect-timeout=5 ping 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}
function Wait-DbReady {
    param([int]$TimeoutSec=60)
    for ($i=0; $i -lt $TimeoutSec; $i++) {
        $ErrorActionPreference = 'Continue'
        $out = & $MysqlExe --protocol=tcp -h 127.0.0.1 -P $DbPort -u root "-p$DbRootPass" --default-character-set=utf8mb4 --connect-timeout=5 -e "SELECT 1;" 2>&1
        if ($LASTEXITCODE -eq 0) {
            if ($i -gt 0) { Log "DB query-ready after $($i)s" 'INFO' }
            return $true
        }
        if ($i -eq 0) { Log "Waiting for DB to accept queries (SELECT 1)..." 'INFO' }
        if ($i % 10 -eq 9) { Log "Still waiting for DB... $($i+1)s / ${TimeoutSec}s (last: $($out | Select-Object -First 1))" 'WARN' }
        Start-Sleep -Seconds 1
    }
    return $false
}
function Start-Db {
    Log "  Db-Up check (ping root@127.0.0.1:$DbPort)..." 'INFO'
    $up = Db-Up
    Log "  Db-Up = $up" 'INFO'
    if ($up) {
        Log "  DB already running, waiting for query-ready (15s)..." 'INFO'
        if (-not (Wait-DbReady -TimeoutSec 15)) {
            $errLog = Join-Path $DbDir 'mariadb-error.log'
            $tail = if (Test-Path $errLog) { (Get-Content $errLog -Tail 30 | Out-String) } else { "<no mariadb-error.log>" }
            Fail "Database ping succeeded but SELECT 1 failed for 15s - InnoDB recovery or auth error. Log tail:`n$tail`nSee setup.log"
        }
        Log "  DB is up and query-ready." 'OK'
        return
    }
    Log "  DB not running - generating my.ini and starting mariadbd directly..." 'INFO'
    # Generate my.ini with current absolute paths (portable, same as start-database.bat)
    # Use Windows-style backslashes for basedir/datadir/tmpdir/log_error to avoid forward-slash parsing issues on some MariaDB builds
    $FDB_slash = ($DbDir -replace '\\','/')
    $FDB_win = $DbDir
    $myIniContent = @"
[client]
port=$DbPort
socket=MySQL
[mysqld]
basedir=$FDB_slash/mariadb
datadir=$FDB_slash/data
tmpdir=$FDB_slash/tmp
port=$DbPort
bind-address=127.0.0.1
character-set-server=utf8mb4
collation-server=utf8mb4_general_ci
sql_mode=NO_ENGINE_SUBSTITUTION
innodb_strict_mode=0
innodb_buffer_pool_size=1G
innodb_flush_log_at_trx_commit=2
innodb_file_per_table=1
innodb_use_native_aio=0
max_allowed_packet=256M
max_connections=200
table_open_cache=4000
wait_timeout=86400
secure_file_priv=""
log_error=$FDB_slash/mariadb-error.log
"@
    try {
        # Ensure directories exist before writing my.ini
        Ensure-Dir $DbDir
        Ensure-Dir (Join-Path $DbDir 'tmp')
        Ensure-Dir $DataDir
        Set-Content -LiteralPath $MyIni -Value $myIniContent -Encoding ASCII -Force
        # Verify my.ini was written and is readable
        if (-not (Test-Path $MyIni)) { Fail "Failed to write my.ini to $MyIni" }
        Log "  my.ini written to $MyIni (basedir=$FDB_slash/mariadb)" 'INFO'
    } catch { Fail "Failed to write my.ini to $MyIni : $($_.Exception.Message)" }
    Ensure-Dir (Join-Path $DbDir 'tmp')
    # Clean stale error log so we can detect fresh errors
    $errLog = Join-Path $DbDir 'mariadb-error.log'
    if (Test-Path $errLog) { try { Remove-Item $errLog -Force } catch {} }
    if (Port-InUse $DbPort) {
        $net = (netstat -ano 2>$null | Select-String ":$DbPort") | Out-String
        Fail "Port $DbPort is already in use (netstat shows LISTENING). Stop the program using it and retry. netstat:`n$net"
    }
    $daemon = $MysqldExe
    if (-not (Test-Path $daemon)) {
        $alt = Get-ChildItem $MariaDir -Recurse -Filter 'mariadbd.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($alt) { $daemon = $alt.FullName; $MysqldExe = $daemon } else { Fail "Daemon not found at $daemon and no alternative found under $MariaDir" }
    }
    # Also ensure the daemon has its dependencies (e.g. Visual C++ runtime) - check via running --help briefly
    Log "  Launching $daemon --defaults-file=`"$MyIni`" --console ..." 'INFO'
    try {
        # First try hidden (normal). If it exits immediately, we will retry visible and capture stdout
        $p = Start-Process -FilePath $daemon -ArgumentList "--defaults-file=`"$MyIni`"","--console" -WindowStyle Hidden -PassThru -ErrorAction Stop
        Log "  Launched PID $($p.Id), waiting 2s..." 'INFO'
    } catch { Fail "Failed to launch mariadbd.exe: $($_.Exception.Message). Check $MyIni and database\mariadb-error.log" }
    Start-Sleep -Seconds 3
    $up2 = $false
    for ($i=0; $i -lt 60; $i++) {
        $up2 = Db-Up
        if ($up2) { Log "  Db-Up after launch = True after $($i)s" 'OK'; break }
        if ($i % 5 -eq 0) { Log "  Waiting for mariadbd ping... $($i)s/60s" 'INFO' }
        Start-Sleep -Seconds 1
        if ($p.HasExited) {
            # Try to collect diagnostics: error log, data dir .err, and a one-shot visible run
            $tail = if (Test-Path $errLog) { (Get-Content $errLog -Tail 80 | Out-String) } else { "<no mariadb-error.log yet>" }
            $altErr = Get-ChildItem $DataDir -Filter "*.err" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($altErr) { $tail += "`n--- $($altErr.FullName) ---`n" + (Get-Content $altErr.FullName -Tail 80 | Out-String) }
            # One-shot visible run to capture stderr (timeout 5s)
            $captureLog = Join-Path $DbDir "mariadb-start-capture.log"
            try {
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = $daemon
                $psi.Arguments = "--defaults-file=`"$MyIni`" --console --log_error=$FDB_slash/mariadb-error.log"
                $psi.RedirectStandardError = $true
                $psi.RedirectStandardOutput = $true
                $psi.UseShellExecute = $false
                $psi.CreateNoWindow = $true
                $psi.WorkingDirectory = $DbDir
                $proc2 = New-Object System.Diagnostics.Process
                $proc2.StartInfo = $psi
                $proc2.Start() | Out-Null
                $out = $proc2.StandardError.ReadToEnd() + $proc2.StandardOutput.ReadToEnd()
                $proc2.WaitForExit(5000) | Out-Null
                if ($out.Trim()) { $tail += "`n--- direct run stderr ---`n$out" }
            } catch {}
            Fail "mariadbd process (PID $($p.Id)) exited early with code $($p.ExitCode). Log tail:`n$tail`nMy.ini:`n$myIniContent`nTry manually: `"$daemon`" --defaults-file=`"$MyIni`" --console`nCheck data dir permissions and that tmp exists: $FDB_slash/tmp"
        }
    }
    if (-not $up2) {
        $tail = if (Test-Path $errLog) { (Get-Content $errLog -Tail 80 | Out-String) } else { "<no log>" }
        try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {}
        Fail "The portable database could not be started (ping timeout 60s). Port=$DbPort Daemon=$daemon`nLast 80 lines of mariadb-error.log:`n$tail`nMy.ini:`n$myIniContent`nSee setup.log"
    }
    Log "  DB ping OK, waiting for query-ready (60s)..." 'INFO'
    if (-not (Wait-DbReady -TimeoutSec 60)) {
        $tail = if (Test-Path $errLog) { (Get-Content $errLog -Tail 80 | Out-String) } else { "<no log>" }
        Fail "Database started (ping OK) but never became query-ready within 60s. Log tail:`n$tail"
    }
    Log "  DB started and query-ready." 'OK'
}

function Sql {
    param([string]$Query, [string]$Db = '')
    $ErrorActionPreference = 'Continue'
    $a = @('--protocol=tcp','-h','127.0.0.1','-P',"$DbPort",'-u','root',"-p$DbRootPass",'--default-character-set=utf8mb4','--connect-timeout=10')
    if ($Db) { $a += $Db }
    $a += @('-e', $Query)
    $out = & $MysqlExe @a 2>&1
    if ($LASTEXITCODE -ne 0) {
        if ("$out" -match "Can't connect|Unknown database|Server shutdown") {
            Start-Sleep -Seconds 3
            $out = & $MysqlExe @a 2>&1
        }
        if ($LASTEXITCODE -ne 0) { Fail "SQL failed: $Query`n$out`n(DB=$Db Port=$DbPort)" }
    }
    return $out
}
function SqlFile {
    param([string]$File, [string]$Db, [switch]$Force)
    $ErrorActionPreference = 'Continue'
    if (-not (Test-Path -LiteralPath $File)) { Fail "SQL file not found: $File" }
    $len = (Get-Item -LiteralPath $File).Length
    if ($len -eq 0) { Log "Skipping empty SQL file $(Split-Path $File -Leaf)" 'WARN'; return }
    $free = Free-GB $DataDir
    if ($free -lt 2) { Fail "Only $free GB free on $($DataDir.Substring(0,2)) - need at least 2 GB for DB imports. Free disk space and run setup.bat again." }
    $f = $File -replace '\\','/'
    $a = @('--protocol=tcp','-h','127.0.0.1','-P',"$DbPort",'-u','root',"-p$DbRootPass",'--default-character-set=utf8mb4','--max_allowed_packet=256M','--connect-timeout=15')
    if ($Force) { $a += '--force' }
    if ($Db) { $a += $Db }
    $a += @('-e', "SOURCE $f")
    $out = & $MysqlExe @a 2>&1
    # Always log full output for debugging SQL errors
    $outStr = ($out | Out-String)
    if ($LASTEXITCODE -ne 0) { Fail "Import of $(Split-Path $File -Leaf) into $Db failed (exit $LASTEXITCODE):`n$($out | Select-Object -Last 30 | Out-String)Full output:`n$outStr" }
    $errs = @($out | Where-Object { "$_" -match '^ERROR' })
    if ($errs.Count -gt 0) {
        # For non-Force imports (base world, critical tables), any ERROR is fatal
        if (-not $Force) {
            Fail "Import of $(Split-Path $File -Leaf) into $Db reported SQL ERROR (not tolerated for base import):`n$($errs | Select-Object -First 10 | Out-String)Full output:`n$outStr"
        }
        Add-Content $LogFile ("  ({0} tolerated errors in {1}: {2})" -f $errs.Count, (Split-Path $File -Leaf), ($errs[0]))
        Log "  $($errs.Count) SQL ERROR(s) in $(Split-Path $File -Leaf) (tolerated with --force): $($errs[0])" 'WARN'
    }
    # Also detect warnings about missing tables that would cause mangosd to fail later
    if ($outStr -match "Unknown database|Table.*doesn.t exist|doesn.t exist") {
        Log "  SQL import $(Split-Path $File -Leaf) output contains missing DB/table warning: $($Matches[0])" 'WARN'
    }
}

Log "Starting portable MariaDB on 127.0.0.1:$DbPort (if not already running)..." 'INFO'
Start-Db
Log "MariaDB is up - testing query..." 'INFO'
$verLine = (Sql 'SELECT VERSION();' | Select-Object -Last 1)
Log "MariaDB $verLine is running on 127.0.0.1:$DbPort" 'OK'
# Version sanity: we ship 11.4, but any 10.6+ is ok; older 5.x would break utf8mb4
if ("$verLine" -match '(\d+)\.(\d+)') {
    $maj=[int]$Matches[1]; $min=[int]$Matches[2]
    if ($maj -lt 10 -or ($maj -eq 10 -and $min -lt 6)) { Log "MariaDB version $verLine is older than the expected 11.4 - some SQL imports may fail." 'WARN' }
}

# --- self-heal mangos user if it was created with the wrong plugin (ed25519/gssapi) ---
# Previous installer versions used IDENTIFIED BY without VIA on MariaDB 11.4,
# which created ed25519 users. The MySQL 5.7 libmySQL.dll then fails with
# "auth_gssapi_client cannot be loaded". Fix it on every run, not just fresh DB.
try {
    $pluginRows = Sql "SELECT user,host,plugin FROM mysql.user WHERE user='$DbUser';" | Out-String
    if ($pluginRows -match 'ed25519|gssapi|caching_sha2') {
        Log "Fixing $DbUser authentication plugin (was ed25519/gssapi) -> mysql_native_password..." 'WARN'
        Sql "CREATE OR REPLACE USER '$DbUser'@'localhost' IDENTIFIED VIA mysql_native_password USING PASSWORD('$DbPass'); CREATE OR REPLACE USER '$DbUser'@'127.0.0.1' IDENTIFIED VIA mysql_native_password USING PASSWORD('$DbPass'); CREATE OR REPLACE USER '$DbUser'@'%' IDENTIFIED VIA mysql_native_password USING PASSWORD('$DbPass'); GRANT ALL PRIVILEGES ON tw_world.* TO '$DbUser'@'localhost','$DbUser'@'127.0.0.1','$DbUser'@'%'; GRANT ALL PRIVILEGES ON tw_char.* TO '$DbUser'@'localhost','$DbUser'@'127.0.0.1','$DbUser'@'%'; GRANT ALL PRIVILEGES ON tw_logon.* TO '$DbUser'@'localhost','$DbUser'@'127.0.0.1','$DbUser'@'%'; GRANT ALL PRIVILEGES ON tw_logs.* TO '$DbUser'@'localhost','$DbUser'@'127.0.0.1','$DbUser'@'%'; FLUSH PRIVILEGES;"
        Log "Fixed $DbUser plugin to mysql_native_password" 'OK'
    }
} catch { Log "Could not check/fix $DbUser plugin: $($_.Exception.Message)" 'WARN' }

$SqlRoot = Join-Path $SrcDir 'sql'
$PbSql   = Join-Path $SrcDir 'modules\ManTechPlayerbots\sql'

if (-not (Done 'db-schema')) {
    Log "Creating user + 4 databases and importing the world (131 MB, 190 files - several minutes)..."
    # Explicitly force mysql_native_password - the only plugin the bundled
    # libmySQL.dll (MySQL 5.7 client) understands. MariaDB 11.4 defaults to
    # ed25519, and default_authentication_plugin is a MySQL variable that
    # MariaDB warns about and ignores ("is MySQL 5.6/5.7 compatible option").
    # USING PASSWORD() still exists on MariaDB 11.4 for this purpose.
    Sql "CREATE OR REPLACE USER '$DbUser'@'localhost' IDENTIFIED VIA mysql_native_password USING PASSWORD('$DbPass'); CREATE OR REPLACE USER '$DbUser'@'127.0.0.1' IDENTIFIED VIA mysql_native_password USING PASSWORD('$DbPass'); CREATE OR REPLACE USER '$DbUser'@'%' IDENTIFIED VIA mysql_native_password USING PASSWORD('$DbPass');"
    Sql "DROP DATABASE IF EXISTS tw_world; DROP DATABASE IF EXISTS tw_char; DROP DATABASE IF EXISTS tw_logon; DROP DATABASE IF EXISTS tw_logs;"
    SqlFile (Join-Path $SqlRoot 'create_databases.sql') ''
    Sql "GRANT ALL PRIVILEGES ON tw_world.* TO '$DbUser'@'localhost','$DbUser'@'127.0.0.1','$DbUser'@'%'; GRANT ALL PRIVILEGES ON tw_char.* TO '$DbUser'@'localhost','$DbUser'@'127.0.0.1','$DbUser'@'%'; GRANT ALL PRIVILEGES ON tw_logon.* TO '$DbUser'@'localhost','$DbUser'@'127.0.0.1','$DbUser'@'%'; GRANT ALL PRIVILEGES ON tw_logs.* TO '$DbUser'@'localhost','$DbUser'@'127.0.0.1','$DbUser'@'%'; FLUSH PRIVILEGES;"
    # base: each file is a `USE tw_world; CREATE TABLE ... + INSERT` dump
    $base = Get-ChildItem (Join-Path $SqlRoot 'base') -Filter '*.sql' -ErrorAction SilentlyContinue | Sort-Object Name
    if (-not $base -or $base.Count -eq 0) { Fail "No SQL files found in $SqlRoot\\base - source checkout is incomplete." }
    $n = 0
    foreach ($f in $base) { $n++; Write-Host ("  [{0}/{1}] {2}" -f $n, $base.Count, $f.Name); SqlFile $f.FullName 'tw_world' }
    # logon extra (donation_point_progress etc) - optional
    foreach ($f in Get-ChildItem (Join-Path $SqlRoot 'logon') -Filter '*.sql' -ErrorAction SilentlyContinue) { SqlFile $f.FullName 'tw_logon' -Force }
    $cnt = (Sql 'SELECT COUNT(*) FROM creature_template;' 'tw_world' | Select-Object -Last 1)
    if (-not "$cnt".Trim() -or [int]("$cnt".Trim()) -lt 1000) { Fail "World import looks incomplete (creature_template has '$cnt' rows, expected >1000). Check setup.log and database\\mariadb-error.log." }
    Log "World database imported ($cnt creature templates)" 'OK'
    Mark 'db-schema'; Unmark 'sql-updates'; Unmark 'db-bots'; Unmark 'db-realm'
}

if (-not (Done 'sql-updates')) {
    Log "Applying database migrations (world / character) and recording them..."
    foreach ($db in 'tw_world','tw_char') {
        Sql "CREATE TABLE IF NOT EXISTS migrations (Id INT UNSIGNED NOT NULL AUTO_INCREMENT, Name VARCHAR(255) NOT NULL DEFAULT '0', Module VARCHAR(255) NOT NULL DEFAULT '', Hash VARCHAR(128) NOT NULL DEFAULT '0', AppliedAt DATETIME NOT NULL, PRIMARY KEY (Id)); ALTER TABLE migrations ADD COLUMN IF NOT EXISTS Module VARCHAR(255) NOT NULL DEFAULT '' AFTER Name;" $db
    }
    $sets = @(
        @{ Dir = (Join-Path $SqlRoot 'database_updates\world');     Db = 'tw_world'; Record = $true  },
        @{ Dir = (Join-Path $SqlRoot 'database_updates\character'); Db = 'tw_char';  Record = $true  },
        @{ Dir = (Join-Path $SqlRoot 'character_updates');          Db = 'tw_char';  Record = $false }
    )
    foreach ($s in $sets) {
        if (-not (Test-Path $s.Dir)) { continue }
        $applied = @{}
        if ($s.Record) { foreach ($l in (Sql 'SELECT Hash FROM migrations;' $s.Db)) { $applied["$l".Trim()] = 1 } }
        $files = Get-ChildItem $s.Dir -Filter '*.sql' -ErrorAction SilentlyContinue | Sort-Object Name
        foreach ($f in $files) {
            $hash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA1).Hash.ToUpper()
            if ($applied.ContainsKey($hash)) { continue }
            Write-Host "  $($s.Db) <- $($f.Name)"
            SqlFile $f.FullName $s.Db -Force
            if ($s.Record) { Sql "INSERT INTO migrations (Name, Module, Hash, AppliedAt) VALUES ('$($f.BaseName)', '', '$hash', NOW());" $s.Db }
        }
    }
    # custom SQL (server-specific tweaks that live under sql/custom)
    foreach ($pair in @(@{Dir=(Join-Path $SqlRoot 'custom\world'); Db='tw_world'}, @{Dir=(Join-Path $SqlRoot 'custom\characters'); Db='tw_char'})) {
        if (-not (Test-Path $pair.Dir)) { continue }
        $customFiles = Get-ChildItem $pair.Dir -Filter '*.sql' -File -ErrorAction SilentlyContinue | Sort-Object Name
        foreach ($f in $customFiles) {
            Write-Host "  $($pair.Db) <- custom/$($f.Name)"
            SqlFile $f.FullName $pair.Db -Force
        }
    }
    $chk = (Sql "SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='tw_world' AND TABLE_NAME='spell_template' AND COLUMN_NAME='script_name';" | Select-Object -Last 1)
    if ("$chk".Trim() -ne '1') { Log "Schema check (spell_template.script_name) did not return 1 - migrations may not all have applied. Check setup.log." 'WARN' }
    Mark 'sql-updates'
}

if (-not (Done 'db-bots')) {
    Log "Importing playerbot tables (ManTechPlayerbots, classic set)..."
    $worldFiles = @()
    $worldFiles += Get-ChildItem (Join-Path $PbSql 'world') -Filter '*.sql' -File -ErrorAction SilentlyContinue | Sort-Object Name
    $worldFiles += Get-ChildItem (Join-Path $PbSql 'world\classic') -Filter '*.sql' -File -ErrorAction SilentlyContinue | Sort-Object Name
    if (Test-Path (Join-Path $PbSql 'world\turtle')) { $worldFiles += Get-ChildItem (Join-Path $PbSql 'world\turtle') -Filter '*.sql' -File -ErrorAction SilentlyContinue | Sort-Object Name }
    if ($worldFiles.Count -eq 0) { Fail "No playerbot world SQL files found under $PbSql\\world - submodule checkout is incomplete." }
    foreach ($f in $worldFiles) { Write-Host "  tw_world <- $($f.Name)"; SqlFile $f.FullName 'tw_world' -Force }
    $charFiles = Get-ChildItem (Join-Path $PbSql 'characters') -Filter '*.sql' -File -ErrorAction SilentlyContinue | Sort-Object Name
    if ($charFiles.Count -eq 0) { Fail "No playerbot character SQL files found under $PbSql\\characters." }
    foreach ($f in $charFiles) { Write-Host "  tw_char <- $($f.Name)"; SqlFile $f.FullName 'tw_char' -Force }
    foreach ($t in 'ai_playerbot_weightscales','ai_playerbot_travelnode','ai_playerbot_texts') {
        $r = Sql "SHOW TABLES LIKE '$t';" 'tw_world'
        if (-not ($r | Where-Object { "$_" -match $t })) { Fail "Playerbot table $t is missing after import (world). Check $PbSql\\world." }
    }
    foreach ($t in 'ai_playerbot_random_bots','ai_playerbot_names') {
        $r = Sql "SHOW TABLES LIKE '$t';" 'tw_char'
        if (-not ($r | Where-Object { "$_" -match $t })) { Fail "Playerbot table $t is missing after import (char). Check $PbSql\\characters." }
    }
    Mark 'db-bots'
}

if (-not (Done 'db-realm')) {
    Log "Realm entry + admin account"
    Sql "INSERT INTO realmlist (id, name, address, port, icon, realmflags, timezone, allowedSecurityLevel, realmbuilds) VALUES (1, 'Turtle WoW', '127.0.0.1', $WorldPort, 0, 0, 1, 0, '7272') ON DUPLICATE KEY UPDATE address='127.0.0.1', port=$WorldPort, realmflags=0;" 'tw_logon'
    $hash = Sha1Hex 'ADMIN:ADMIN'
    Sql "INSERT INTO account (username, sha_pass_hash, ``rank``, expansion, joindate) VALUES ('ADMIN', '$hash', 4, 0, NOW()) ON DUPLICATE KEY UPDATE sha_pass_hash='$hash', ``rank``=4;" 'tw_logon'
    Mark 'db-realm'
}
Log "Databases ready (tw_world, tw_char, tw_logon, tw_logs)" 'OK'

# Self-heal realmlist port if it is inside Hyper-V excluded range 8018-8117 (8090/8085 fail even though netstat clean)
try {
    $rlPortStr = (Sql "SELECT port FROM tw_logon.realmlist WHERE id=1;" | Select-Object -Last 1).ToString().Trim()
    $rlPort = 0; [void][int]::TryParse($rlPortStr, [ref]$rlPort)
    if ($rlPort -ge 8018 -and $rlPort -le 8117) {
        Log "Realmlist port $rlPort is inside Windows Hyper-V excluded range 8018-8117 - updating to $WorldPort (10081) to avoid 'Failed to open acceptor'" 'WARN'
        Sql "UPDATE tw_logon.realmlist SET port=$WorldPort WHERE id=1;"
    } elseif ($rlPort -ne 0 -and $rlPort -ne $WorldPort) {
        # Keep existing non-reserved custom port (e.g. user manually set 10082) - don't overwrite
        Log "Realmlist port is $rlPort (keeping, not $WorldPort)" 'INFO'
    }
} catch { Log "Could not check/fix realmlist port: $($_.Exception.Message)" 'WARN' }


# ------------------------------------------------------------------ 8. configuration
Log "Step 8/9  Writing configuration" 'STEP'
$mangosdConf = Join-Path $ServerDir 'mangosd.conf'
$realmdConf  = Join-Path $ServerDir 'realmd.conf'
$botConf     = Join-Path $ServerDir 'aiplayerbot.conf'
$dbInfo = "127.0.0.1;$DbPort;$DbUser;$DbPass;"
Set-Conf $mangosdConf 'LoginDatabase.Info'     "`"${dbInfo}tw_logon`""
Set-Conf $mangosdConf 'WorldDatabase.Info'     "`"${dbInfo}tw_world`""
Set-Conf $mangosdConf 'CharacterDatabase.Info' "`"${dbInfo}tw_char`""
Set-Conf $mangosdConf 'LogsDatabase.Info'      "`"${dbInfo}tw_logs`""
Set-Conf $mangosdConf 'DataDir'  '"data"'
Set-Conf $mangosdConf 'LogsDir'  '"logs"'
Set-Conf $mangosdConf 'WorldServerPort' "$WorldPort"
Set-Conf $mangosdConf 'BindIP' '"0.0.0.0"'
Set-Conf $mangosdConf 'RealmID' '1'
Set-Conf $mangosdConf 'LogSQL' '0'
Set-Conf $mangosdConf 'Database.AutoUpdate.Enabled' '1'
Set-Conf $mangosdConf 'Database.AutoUpdate.Path' '"../source/sql/database_updates/"'
Set-Conf $mangosdConf 'Console.Enable' '1'
Set-Conf $mangosdConf 'Anticheat.Enable' '0'
# solo / bot friendly switches from INSTALL-WINDOWS.md
Set-Conf $mangosdConf 'LFT.BotFill.Enable' '1'
Set-Conf $mangosdConf 'SoloDungeonRepopAlive.Enable' '1'
Set-Conf $mangosdConf 'Leech.Enable' '1'

Set-Conf $realmdConf 'LoginDatabaseInfo' "`"${dbInfo}tw_logon`""
Set-Conf $realmdConf 'LogsDir' '"logs"'
Set-Conf $realmdConf 'RealmServerPort' "$RealmPort"
Set-Conf $realmdConf 'BindIP' '"0.0.0.0"'
Set-Conf $realmdConf 'PatchesDir' '"./patches"'

if (-not (Done 'configs')) {
    Set-Conf $botConf 'AiPlayerbot.Enabled' '1'
    Set-Conf $botConf 'AiPlayerbot.MinRandomBots' '100'
    Set-Conf $botConf 'AiPlayerbot.MaxRandomBots' '100'
    Set-Conf $botConf 'AiPlayerbot.RandomBotAccountCount' '20'
    Mark 'configs'
}
# Always enforce sane bot population on every run - existing installs with 1000 hang for 30-60 min at
# "PLAYERBOT POPULATION min=1000 max=1000". Lower to 100 / 20 accounts unconditionally if heavy default found.
try {
    if (Test-Path -LiteralPath $botConf) {
        $txt = Get-Content -LiteralPath $botConf -Raw -ErrorAction SilentlyContinue
        $needsFix = $false
        if ($txt -match 'MinRandomBots\s*=\s*1000') { $needsFix = $true }
        if ($txt -match 'MaxRandomBots\s*=\s*1000') { $needsFix = $true }
        if ($txt -match 'RandomBotAccountCount\s*=\s*200') { $needsFix = $true }
        if ($needsFix) {
            Set-Conf $botConf 'AiPlayerbot.Enabled' '1'
            Set-Conf $botConf 'AiPlayerbot.MinRandomBots' '100'
            Set-Conf $botConf 'AiPlayerbot.MaxRandomBots' '100'
            Set-Conf $botConf 'AiPlayerbot.RandomBotAccountCount' '20'
            Log "Fixed aiplayerbot.conf: lowered 1000 bots / 200 accounts -> 100 bots / 20 accounts for fast startup (raise later)" 'WARN'
        }
    }
} catch { Log "Could not fix aiplayerbot.conf: $($_.Exception.Message)" 'WARN' }
Log "Configs written (server\mangosd.conf, realmd.conf, aiplayerbot.conf, ahbot.conf)" 'OK'

# ------------------------------------------------------------------ 9. client data (NOT done here - extractors only)
Log "Step 9/9  Client data" 'STEP'
Ensure-Dir (Join-Path $ServerDir 'data')
# The four extractors are already in server\ (copied in step 6). Nothing to
# generate here - the user must run them against their own client.
Log "Game data (dbc/maps/vmaps/mmaps) is NOT extracted by this installer." 'WARN'
Log "The four extractors (mapextractor.exe, vmapextractor.exe, vmap_assembler.exe, MoveMapGen.exe) are in server\." 'WARN'
Log "THE WORLD SERVER WILL NOT START WITHOUT IT. See README-FIRST.txt for how to extract." 'WARN'

# ------------------------------------------------------------------ launcher scripts - REMOVED
# Users now run exes directly: start-database.bat, then server\realmd.exe and server\mangosd.exe
# Clean up any obsolete launcher bats from previous installer versions.
foreach ($old in @('start-realmd.bat','start-mangosd.bat','start-server.bat','fix-bots-and-consoles.bat')) {
    $oldPath = Join-Path $Root $old
    if (Test-Path $oldPath) {
        try { Remove-Item $oldPath -Force -ErrorAction SilentlyContinue; Log "Removed obsolete $old (run exes directly)" 'INFO' } catch {}
    }
}
# start-database.bat / stop-database.bat already generated above - keep them




$stopAll = @"


@echo off
title Turtle WoW - Stop everything
taskkill /IM mangosd.exe /T >nul 2>&1 && echo mangosd stopped - use 'server exit' in its console for a clean save next time.
taskkill /IM realmd.exe /T >nul 2>&1 && echo realmd stopped.
call "%~dp0stop-database.bat"
"@
Set-Content -Path (Join-Path $Root 'stop-server.bat') -Value $stopAll -Encoding ASCII

$readme = @"
TURTLE WOW - PRIVATE SERVER (T-imothy/tortoise-wow, branch mantech-turtle, ManTech playerbots)
==============================================================================================

Everything is inside this folder. Nothing was installed elsewhere except the Visual C++ Build
Tools when no compiler was present (they live in tools\BuildTools).

HOW TO START
  0. FIRST extract game data (see GAME DATA below) - mandatory!
  1. start-database.bat, then run server\realmd.exe and server\mangosd.exe (each in its own window)
     or one by one:  start-database.bat, then server\\realmd.exe and server\\mangosd.exe
  2. In your client folder edit realmlist.wtf:      set realmlist 127.0.0.1
  3. Log in with account  ADMIN / ADMIN   (GM level 4 - change the password!)
     In the mangosd console:   account set password ADMIN newpass newpass
     Create more accounts:     account create NAME PASSWORD

HOW TO STOP
  Type   server exit   in the mangosd window (clean save), Ctrl+C in realmd,
  then stop-database.bat.  stop-server.bat does it the rough way.

BOTS
  Enabled (AiPlayerbot.Enabled = 1 in server\aiplayerbot.conf). All other values
  are the module's defaults - population is AiPlayerbot.MinRandomBots / MaxRandomBots /
  RandomBotAccountCount. The first world start creates and gears all of them, which
  takes a long time; lower the numbers if you want a quicker first start.

DATABASE (portable MariaDB, database\)
  host 127.0.0.1  port $DbPort   user $DbUser / $DbPass   root / $DbRootPass
  Databases: tw_world, tw_char, tw_logon, tw_logs.   Data files: database\data
  start-database.bat rewrites database\my.ini with the current paths, so you can
  move or copy this whole folder anywhere.

GAME DATA  *** REQUIRED - NOT DONE BY THE INSTALLER ***
  The world server will NOT start until dbc, maps, vmaps and mmaps exist in server\data.
  The extractors (mapextractor.exe, vmapextractor.exe, vmap_assembler.exe,
  MoveMapGen.exe) are already in server\ - run them against your
  Turtle WoW 1.18.1 client (build 7272) and move the resulting dbc/maps/
  vmaps/mmaps folders into server\data. The mmap step takes 1-4 hours.

UPDATING
  setup.bat -Update   (git pull, rebuild, new SQL migrations are applied by the
  server's auto-updater on next start).  Or just re-run setup.bat: it resumes.

PORTS   realmd 3724, mangosd $WorldPort, MariaDB $DbPort  (open 3724 + $WorldPort for LAN/Internet play
        and change realmlist.address in tw_logon to your public/LAN IP).

LOGS    setup.log (this installer), server\logs\, database\mariadb-error.log
"@
Set-Content -Path (Join-Path $Root 'README-FIRST.txt') -Value $readme -Encoding UTF8

# Old wrapper bats / fix bat already removed above

Log "" 
Log "ALL DONE. The server is compiled, database is filled, configs are written - everything is switched OFF." 'OK'
Log "  !!! REQUIRED NEXT STEP: extract game data from your Turtle WoW 1.18.1 client into server\data !!!" 'WARN'
Log "  !!! The extractors are in server\ - see README-FIRST.txt. Without dbc/maps/vmaps/mmaps the world WILL NOT START !!!" 'WARN'
Log "  Then start it with: start-database.bat, then server\realmd.exe and server\mangosd.exe   -   client: set realmlist 127.0.0.1   -   login ADMIN / ADMIN" 'OK'
& $AdminExe --protocol=tcp -h 127.0.0.1 -P $DbPort -u root "-p$DbRootPass" shutdown 2>$null | Out-Null
Log "  Database has been shut down again - everything is OFF. Start with start-database.bat + server\realmd.exe / server\mangosd.exe" 'INFO'
exit 0
