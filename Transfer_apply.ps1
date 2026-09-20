<#
  Transfer_apply - apply dumps into NEW repack (3310)
  Dumps expected in transfer-dumps next to script.
#>
param(
    [string]$DestHost     = "127.0.0.1",
    [int]   $DestPort     = 3310,
    [string]$DestUser     = "root",
    [string]$DestPassword = "root",
    [string]$DumpDir      = $null,
    [string]$MariadbBin   = $null
)

$ErrorActionPreference = "Stop"
function Step($m){ Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Ok($m){ Write-Host "[OK] $m" -ForegroundColor Green }
function Warn($m){ Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Fail($m){ Write-Host "`n[FAILED] $m" -ForegroundColor Red; Read-Host "`nPress Enter to close"; exit 1 }

if (-not $DumpDir) {
    $DumpDir = Join-Path $PSScriptRoot "transfer-dumps"
    # if not found there, also try script root (where previous buggy pull put files)
    if (-not (Test-Path $DumpDir)) {
        $alt = Get-ChildItem -Path $PSScriptRoot -Filter "*_logon.sql" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($alt) { $DumpDir = $alt.DirectoryName }
    }
}

function Resolve-MariadbBin {
    param([string]$hint)
    if ($hint -and (Test-Path $hint)) { return $hint }
    $f = Get-ChildItem -Path $PSScriptRoot -Recurse -Depth 5 -Filter "mariadb.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($f) { return $f.DirectoryName }
    $f = Get-ChildItem -Path $PSScriptRoot -Recurse -Depth 5 -Filter "mysql.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($f) { return $f.DirectoryName }
    $c = Get-Command mariadb.exe -ErrorAction SilentlyContinue
    if ($c) { return (Split-Path $c.Source -Parent) }
    $c = Get-Command mysql.exe -ErrorAction SilentlyContinue
    if ($c) { return (Split-Path $c.Source -Parent) }
    return $null
}
if (-not $MariadbBin) { $MariadbBin = Resolve-MariadbBin }
if (-not $MariadbBin) { Fail "MariaDB client not found under $PSScriptRoot or PATH. Pass -MariadbBin" }
function Find-Client($bin,$names){ foreach($n in $names){ $p=Join-Path $bin $n; if(Test-Path $p){ return $p } } return $null }
$sqlClient = Find-Client $MariadbBin @("mariadb.exe","mysql.exe","mariadb","mysql")
if (-not $sqlClient) { Fail "sql client not found in $MariadbBin" }

# Only ONE primary source for old repack - old and oldnative are same file, so we deduplicate.
# If you have both old_*.sql and oldnative_*.sql that are byte-identical, second will be skipped.
$Sources = @(
    @{ Label="old"; Offset=0 },
    @{ Label="oldnative"; Offset=5000000 },
    @{ Label="docker"; Offset=1000000 }
)

function Get-FileHashQuick($path){
    if (-not (Test-Path $path)) { return $null }
    return (Get-FileHash -Path $path -Algorithm SHA256).Hash
}

function Invoke-DestSql($sql,$db){
    $a=@("-h",$DestHost,"-P","$DestPort","-u",$DestUser)
    if($DestPassword){ $a+="-p$DestPassword" }
    if($db){ $a+=$db }
    $sql | & $sqlClient @a
    if($LASTEXITCODE -ne 0){ Fail "SQL failed on $db ($DestHost`:$DestPort). Is NEW DB running?" }
}
function Invoke-DestSqlScalar($sql,$db){
    $a=@("-h",$DestHost,"-P","$DestPort","-u",$DestUser,"-N","-B")
    if($DestPassword){ $a+="-p$DestPassword" }
    if($db){ $a+=$db }
    return ($sql | & $sqlClient @a)
}
function Invoke-DestSqlFile($file,$db){
    (Get-Content $file -Raw) | & $sqlClient -h $DestHost -P $DestPort -u $DestUser $(if($DestPassword){"-p$DestPassword"}) $db
    if($LASTEXITCODE -ne 0){ Fail "Load $file into $db failed" }
}

$CharGuidTables = @(
    @{ Table="character_action"; Col="guid" },
    @{ Table="character_aura"; Col="guid" },
    @{ Table="character_battleground_data"; Col="guid" },
    @{ Table="character_declinedname"; Col="guid" },
    @{ Table="character_gifts"; Col="guid" },
    @{ Table="character_homebind"; Col="guid" },
    @{ Table="character_instance"; Col="guid" },
    @{ Table="character_inventory"; Col="guid" },
    @{ Table="character_pet"; Col="owner" },
    @{ Table="character_queststatus"; Col="guid" },
    @{ Table="character_reputation"; Col="guid" },
    @{ Table="character_skills"; Col="guid" },
    @{ Table="character_social"; Col="guid" },
    @{ Table="character_spell"; Col="guid" },
    @{ Table="character_spell_cooldown"; Col="guid" },
    @{ Table="character_stats"; Col="guid" },
    @{ Table="character_talent"; Col="guid" },
    @{ Table="item_instance"; Col="owner_guid" },
    @{ Table="mail"; Col="receiver" }
)
$CharGuidExtraCols = @( @{ Table="character_social"; Col="friend" } )
$ItemGuidTables = @(
    @{ Table="item_instance"; Col="guid" },
    @{ Table="character_inventory"; Col="item" },
    @{ Table="character_inventory"; Col="bag" },
    @{ Table="mail_items"; Col="item_guid" }
)
$PetIdTables = @(
    @{ Table="character_pet"; Col="id" },
    @{ Table="pet_aura"; Col="guid" },
    @{ Table="pet_spell"; Col="guid" },
    @{ Table="pet_spell_cooldown"; Col="guid" }
)
$MailIdTables = @(
    @{ Table="mail"; Col="id" },
    @{ Table="mail_items"; Col="mail_id" }
)
$CharacterOwnRow = @{ Table="characters"; GuidCol="guid"; AccountCol="account" }

$processedHashes = @{}
foreach($src in $Sources){
    $label=$src.Label; $offset=[int]$src.Offset
    $logonDump = Join-Path $DumpDir "$label`_logon.sql"
    $charDump  = Join-Path $DumpDir "$label`_char.sql"
    if(-not (Test-Path $logonDump) -or -not (Test-Path $charDump)){
        Warn "No dumps for '$label' in $DumpDir - skipping"
        continue
    }
    # deduplicate: if this dump is byte-identical to a previous one, skip
    $hash = (Get-FileHashQuick $logonDump) + "|" + (Get-FileHashQuick $charDump)
    if($processedHashes.ContainsKey($hash)){
        Warn "Dump for '$label' is identical to '$($processedHashes[$hash])' - skipping duplicate (would cause offset collision)"
        continue
    }
    $processedHashes[$hash] = $label

    Step "Applying '$label'$(if($offset -gt 0){" (offset $offset)"}) -> $DestHost`:$DestPort"
    $stageLogon="tw_logon_stage_$label"; $stageChar="tw_char_stage_$label"
    Step "Staging"
    Invoke-DestSql "DROP DATABASE IF EXISTS $stageLogon; CREATE DATABASE $stageLogon;" $null
    Invoke-DestSql "DROP DATABASE IF EXISTS $stageChar; CREATE DATABASE $stageChar;" $null
    Invoke-DestSql "CREATE TABLE $stageLogon.account_banned LIKE tw_logon.account_banned;" $null
    Invoke-DestSqlFile $logonDump $stageLogon
    Invoke-DestSqlFile $charDump $stageChar
    Ok "Staged"

    Step "Remove RNDBOT"
    $botAccounts = Invoke-DestSqlScalar "SELECT COUNT(*) FROM account WHERE username LIKE 'RNDBOT%';" $stageLogon
    Invoke-DestSql "DELETE FROM characters WHERE account NOT IN (SELECT id FROM $stageLogon.account);" $stageChar
    Invoke-DestSql "DELETE FROM account WHERE username LIKE 'RNDBOT%';" $stageLogon
    Ok "Removed $botAccounts"

    if($offset -gt 0){
        Step "Shift IDs $offset (ORDER BY DESC to avoid PK collision)"
        # ORDER BY DESC prevents duplicate-key during in-place PK update when original IDs already contain high values
        Invoke-DestSql "UPDATE account SET id = id + $offset ORDER BY id DESC;" $stageLogon
        Invoke-DestSql "UPDATE account_banned SET id = id + $offset ORDER BY id DESC;" $stageLogon
        Invoke-DestSql "UPDATE characters SET $($CharacterOwnRow.GuidCol) = $($CharacterOwnRow.GuidCol) + $offset, $($CharacterOwnRow.AccountCol) = $($CharacterOwnRow.AccountCol) + $offset ORDER BY $($CharacterOwnRow.GuidCol) DESC;" $stageChar
        foreach($t in $CharGuidTables){
            $e=Invoke-DestSqlScalar "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$stageChar' AND TABLE_NAME='$($t.Table)';" $null
            if([int]$e -eq 1){ Invoke-DestSql "UPDATE $($t.Table) SET $($t.Col) = $($t.Col) + $offset;" $stageChar }
        }
        foreach($t in $CharGuidExtraCols){
            $e=Invoke-DestSqlScalar "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$stageChar' AND TABLE_NAME='$($t.Table)';" $null
            if([int]$e -eq 1){ Invoke-DestSql "UPDATE $($t.Table) SET $($t.Col) = $($t.Col) + $offset WHERE $($t.Col) <> 0;" $stageChar }
        }
        foreach($t in $ItemGuidTables){
            $e=Invoke-DestSqlScalar "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$stageChar' AND TABLE_NAME='$($t.Table)';" $null
            if([int]$e -eq 1){ Invoke-DestSql "UPDATE $($t.Table) SET $($t.Col) = $($t.Col) + $offset WHERE $($t.Col) <> 0;" $stageChar }
        }
        foreach($t in $PetIdTables){
            $e=Invoke-DestSqlScalar "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$stageChar' AND TABLE_NAME='$($t.Table)';" $null
            if([int]$e -eq 1){ Invoke-DestSql "UPDATE $($t.Table) SET $($t.Col) = $($t.Col) + $offset ORDER BY $($t.Col) DESC;" $stageChar }
        }
        foreach($t in $MailIdTables){
            $e=Invoke-DestSqlScalar "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$stageChar' AND TABLE_NAME='$($t.Table)';" $null
            if([int]$e -eq 1){ Invoke-DestSql "UPDATE $($t.Table) SET $($t.Col) = $($t.Col) + $offset ORDER BY $($t.Col) DESC;" $stageChar }
        }
        Ok "Shifted"
    }

    Step "Merging"
    Invoke-DestSql "INSERT IGNORE INTO tw_logon.account SELECT * FROM $stageLogon.account;" $null
    Invoke-DestSql "INSERT IGNORE INTO tw_logon.account_banned SELECT * FROM $stageLogon.account_banned;" $null
    Invoke-DestSql "INSERT IGNORE INTO tw_char.characters SELECT * FROM $stageChar.characters;" $null
    $all=@()
    foreach($g in @($CharGuidTables,$ItemGuidTables,$PetIdTables,$MailIdTables)){ foreach($t in @($g)){ if($null -ne $t.Table){ $all+=[string]$t.Table } } }
    $all=$all | Sort-Object -Unique
    foreach($tn in $all){
        $e=Invoke-DestSqlScalar "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$stageChar' AND TABLE_NAME='$tn';" $null
        if([int]$e -eq 1){ Invoke-DestSql "INSERT IGNORE INTO tw_char.$tn SELECT * FROM $stageChar.$tn;" $null }
    }
    Ok "Merged"
    Invoke-DestSql "DROP DATABASE $stageLogon; DROP DATABASE $stageChar;" $null
    Ok "Cleaned"
}

Step "DONE"
$acctCount=Invoke-DestSqlScalar "SELECT COUNT(*) FROM account;" "tw_logon"
$charCount=Invoke-DestSqlScalar "SELECT COUNT(*) FROM characters;" "tw_char"
Write-Host "Destination $DestPort now has $acctCount accounts and $charCount chars." -ForegroundColor Green
Read-Host "`nPress Enter to close"
