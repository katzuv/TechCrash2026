@echo off
set QUARTUS_PATH="C:\intelFPGA_lite\17.1\quartus\bin64"

if not exist output_files\accel_project.sof (
    echo ERROR: no .sof found — run run.bat first
    exit /b 1
)

echo Programming DE10-Lite...
%QUARTUS_PATH%\quartus_pgm -c "USB-Blaster [USB-0]" -m JTAG -o "P;output_files\accel_project.sof"

if %ERRORLEVEL% EQU 0 (
    echo   DONE
) else (
    echo   FAILED — board connected? SW[9] up after programming.
    exit /b %ERRORLEVEL%
)
