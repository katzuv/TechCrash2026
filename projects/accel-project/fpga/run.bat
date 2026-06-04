@echo off
echo Compiling accel_project for DE10-Lite...
set QUARTUS_PATH="C:\intelFPGA_lite\17.1\quartus\bin64"

%QUARTUS_PATH%\quartus_sh --flow compile accel_project

if %ERRORLEVEL% EQU 0 (
    echo   DONE: output_files\accel_project.sof
) else (
    echo   FAILED — check output_files\ for errors
    exit /b %ERRORLEVEL%
)
