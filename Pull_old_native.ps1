<#
  Pull from OLD repack - dumps to transfer-dumps subfolder
#>
param(
    [string]$SrcHost     = "127.0.0.1",
    [int]   $SrcPort     = 3307,
    [string]$SrcUser     = "mangos",
    [string]$SrcPassword = "mangos",
    [string]$Label       = "old",
    [string]$DumpDir     = $null,
    [string]$MariadbBin  = $null
)

$ErrorActionPreference = "Stop"
function Step($m){ Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Ok($m){ Write-Host "[OK] $m" -ForegroundColor Green }
function Fail($m){ Write-Host "`n[FAILED] $m" -ForegroundColor Red; Read-Host "`nPress Enter to close"; exit 1 }

# DumpDir defaults to transfer-dumps next to script (relative, not absolute)
if (-not $DumpDir) {
    $DumpDir = Join-Path $PSScriptRoot "transfer-dumps"
}
New-Item -ItemType Directory -Force -Path $DumpDir | Out-Null

function Resolve-MariadbBin {
    param([string]$hint)
    if ($hint -and (Test-Path $hint)) { return $hint }
    $f = Get-ChildItem -Path $PSScriptRoot -Recurse -Depth 5 -Filter "mariadb.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($f) { return $f.DirectoryName }
    $f = Get-ChildItem -Path $PSScriptRoot -Recurse -Depth 5 -Filter "mysql.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($f) { return $f.DirectoryName }
    $f = Get-ChildItem -Path $PSScriptRoot -Recurse -Depth 5 -Filter "mariadb-dump.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($f) { return $f.DirectoryName }
    $c = Get-Command mariadb.exe -ErrorAction SilentlyContinue
    if ($c) { return (Split-Path $c.Source -Parent) }
    $c = Get-Command mysql.exe -ErrorAction SilentlyContinue
    if ($c) { return (Split-Path $c.Source -Parent) }
    return $null
}
if (-not $MariadbBin) { $MariadbBin = Resolve-MariadbBin }
if (-not $MariadbBin) { Fail "MariaDB client not found. Searched under $PSScriptRoot and PATH." }

function Find-Client($bin,$names){ foreach($n in $names){ $p=Join-Path $bin $n; if(Test-Path $p){ return $p } } return $null }
$dumpClient = Find-Client $MariadbBin @("mariadb-dump.exe","mysqldump.exe","mariadb-dump","mysqldump")
$sqlClient  = Find-Client $MariadbBin @("mariadb.exe","mysql.exe","mariadb","mysql")
if (-not $dumpClient) { Fail "dump client not found in $MariadbBin" }
if (-not $sqlClient)  { Fail "sql client not found in $MariadbBin" }

Step "Pulling from OLD $SrcHost`:$SrcPort via $MariadbBin -> $DumpDir"
$dumpArgs = @("-h",$SrcHost,"-P","$SrcPort","-u",$SrcUser)
if ($SrcPassword) { $dumpArgs += "-p$SrcPassword" }
$sqlArgs  = @("-h",$SrcHost,"-P","$SrcPort","-u",$SrcUser)
if ($SrcPassword) { $sqlArgs += "-p$SrcPassword" }

$logonDump = Join-Path $DumpDir "$Label`_logon.sql"
$charDump  = Join-Path $DumpDir "$Label`_char.sql"

Remove-Item $logonDump -Force -ErrorAction SilentlyContinue
Remove-Item $charDump -Force -ErrorAction SilentlyContinue

Write-Host "Testing connection..."
& $sqlClient @sqlArgs -N -B -e "SELECT 1;" > $null
if ($LASTEXITCODE -ne 0) { Fail "Cannot connect to OLD $SrcHost`:$SrcPort" }
Ok "Connected"

Write-Host "Dumping tw_logon.account (skip RNDBOT)..."
& $dumpClient @dumpArgs --where="username NOT LIKE 'RNDBOT%'" tw_logon account > $logonDump
if ($LASTEXITCODE -ne 0) { Fail "dump account failed" }
Write-Host "Dumping tw_logon.account_banned..."
& $dumpClient @dumpArgs --no-create-info tw_logon account_banned >> $logonDump
if ($LASTEXITCODE -ne 0) { Fail "dump account_banned failed" }
Ok "tw_logon dumped"

Write-Host "Reading RNDBOT IDs..."
$ids = & $sqlClient @sqlArgs -N -B -e "SELECT id FROM tw_logon.account WHERE username LIKE 'RNDBOT%';"
if ($LASTEXITCODE -ne 0) { Fail "query RNDBOT failed" }
$ids = @($ids | ForEach-Object{ $_.ToString().Trim() } | Where-Object{ $_ -match '^\d+$' })
Write-Host "Found $($ids.Count) RNDBOT"

Write-Host "Dumping tw_char (ignore characters)..."
& $dumpClient @dumpArgs --ignore-table="tw_char.characters" tw_char > $charDump
if ($LASTEXITCODE -ne 0) { Fail "dump tw_char failed" }

if ($ids.Count -gt 0) {
    $list = $ids -join ","
    Write-Host "Dumping characters excluding $list"
    & $dumpClient @dumpArgs --where="account NOT IN ($list)" tw_char characters >> $charDump
    if ($LASTEXITCODE -ne 0) { Fail "dump characters failed" }
} else {
    & $dumpClient @dumpArgs tw_char characters >> $charDump
    if ($LASTEXITCODE -ne 0) { Fail "dump characters failed" }
}
Ok "tw_char dumped"

# keep alias for Transfer_apply backward compat (oldnative expects same files)
$logonAlias = Join-Path $DumpDir "oldnative_logon.sql"
$charAlias  = Join-Path $DumpDir "oldnative_char.sql"
Copy-Item $logonDump $logonAlias -Force
Copy-Item $charDump $charAlias -Force

if (-not (Test-Path $logonDump)) { Fail "logon dump missing" }
if (-not (Test-Path $charDump))  { Fail "char dump missing" }
if ((Get-Item $logonDump).Length -eq 0) { Fail "logon dump empty" }
if ((Get-Item $charDump).Length -eq 0)  { Fail "char dump empty" }

Step "DONE"
Write-Host "  $logonDump" -ForegroundColor Green
Write-Host "  $charDump" -ForegroundColor Green
Write-Host "Aliases: $logonAlias , $charAlias (same content, for Transfer_apply compatibility)"
Read-Host "`nPress Enter to close"
