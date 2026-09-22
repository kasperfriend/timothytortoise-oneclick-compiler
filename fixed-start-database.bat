@echo off
:: Starts the portable MariaDB that belongs to this Turtle WoW folder.
:: Safe to double-click any time: if it is already running nothing happens.
setlocal
title Turtle WoW - Database
set "ROOT=%~dp0"
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"
set "DB=%ROOT%\database"
set "BIN=%DB%\mariadb\bin"
set "PORT=3310"
:: Fallbacks for different MariaDB zip layouts (mariadb.exe vs mysql.exe, mariadbd.exe vs mysqld.exe)
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
(
echo [client]
echo port=%PORT%
echo socket=MySQL
echo [mysqld]
echo basedir=%FDB%/mariadb
echo datadir=%FDB%/data
echo tmpdir=%FDB%/tmp
echo port=%PORT%
echo bind-address=127.0.0.1
echo character-set-server=utf8mb4
echo collation-server=utf8mb4_general_ci
echo sql_mode=NO_ENGINE_SUBSTITUTION
echo innodb_strict_mode=0
echo innodb_buffer_pool_size=1G
echo innodb_flush_log_at_trx_commit=2
echo innodb_file_per_table=1
echo innodb_use_native_aio=0
echo max_allowed_packet=256M
echo max_connections=200
echo table_open_cache=4000
echo wait_timeout=86400
echo secure_file_priv=""
echo log_error=%FDB%/mariadb-error.log
) > "%DB%\my.ini"
if not exist "%DB%\tmp" mkdir "%DB%\tmp"
:: Already running?
"%BIN%\%ADMIN%" --protocol=tcp -h 127.0.0.1 -P %PORT% -u root -proot ping >nul 2>&1
if %ERRORLEVEL%==0 (
    echo Database is already running on port %PORT%.
    exit /b 0
)
netstat -ano | findstr /R /C:":%PORT% .*LISTENING" >nul 2>&1
if %ERRORLEVEL%==0 (
    echo [ERROR] Port %PORT% is used by another program. Close it or change DbPort in setup and the *.conf files.
    timeout /t 5 >nul
    exit /b 1
)
echo Starting MariaDB on 127.0.0.1:%PORT% ...
start "Turtle WoW - MariaDB (keep open)" /MIN "%BIN%\%DAEMON%" --defaults-file="%DB%\my.ini" --console
:: Wait until it answers (max ~60 s)
set /a tries=0
:wait
set /a tries+=1
"%BIN%\%ADMIN%" --protocol=tcp -h 127.0.0.1 -P %PORT% -u root -proot ping >nul 2>&1
if %ERRORLEVEL%==0 goto up
if %tries% GEQ 60 (
    echo [ERROR] MariaDB did not start. See database\mariadb-error.log
    type "%DB%\mariadb-error.log" 2>nul
    timeout /t 5 >nul
    exit /b 1
)
timeout /t 1 /nobreak >nul
goto wait
:up
echo Database is UP  (port %PORT%, user mangos / mangos, root / root)
exit /b 0
