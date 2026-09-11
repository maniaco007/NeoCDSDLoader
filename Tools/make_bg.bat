@echo off
REM Drag and drop an image file onto this .bat to convert it into a bg.bmp
REM (320x224, 16-color, ready for the SD card) in the SAME folder as the
REM image. Usual workflow:
REM   1. Copy the game's cover/art image into its folder on the SD card
REM      (any format: jpg, png, bmp...)
REM   2. Drag that image file onto this make_bg.bat
REM   3. A "bg.bmp" appears next to it in that same folder - done!

if "%~1"=="" (
    echo Arraste uma imagem para este arquivo .bat para converte-la em bg.bmp
    pause
    exit /b 1
)

python "%~dp0bg_maker.py" "%~1"
if errorlevel 1 (
    echo.
    echo Falha na conversao. Verifique se o Python e a biblioteca Pillow
    echo estao instalados ^(pip install pillow^).
)
pause
