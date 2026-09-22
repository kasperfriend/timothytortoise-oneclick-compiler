@echo off
:: Starts the portable MariaDB that belongs to this Turtle WoW folder.
:: Safe to double-click any time: if it is already running nothing happens.
setlocal
title Turtle WoW - Database
set "ROOT=%~dp0"
set "ROOT=%ROOT:~0,-1%"
set "DB=%ROOT%\database"
set "BIN=%DB%\mariadb\bin"
set "PORT=3310"
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
"%BIN%\%ADMIN%" --protocol=tcp -h 127.0.0.1 -P %PORT% -u root -proot ping >nul 2>&1
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
start "Turtle WoW - MariaDB (keep open)" /MIN "%BIN%\%DAEMON%" --defaults-file="%DB%\my.ini" --console
:: Wait until it answers (max ~60 s)
set /a tries=0
:wait
set /a tries+=1
"%BIN%\%ADMIN%" --protocol=tcp -h 127.0.0.1 -P %PORT% -u root -proot ping >nul 2>&1
if "%ERRORLEVEL%"=="0" goto up
if %tries% geq 60 (
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
