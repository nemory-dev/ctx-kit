@echo off
setlocal
pushd "%~dp0"

if exist "C:\Program Files\Git\bin\bash.exe" (
    "C:\Program Files\Git\bin\bash.exe" -l ctx.sh %*
    goto done
)

if exist "%LOCALAPPDATA%\Programs\Git\bin\bash.exe" (
    "%LOCALAPPDATA%\Programs\Git\bin\bash.exe" -l ctx.sh %*
    goto done
)

where git >nul 2>nul
if %ERRORLEVEL% equ 0 (
    for /f "delims=" %%i in ('where git') do (
        if exist "%%~dpi..\bin\bash.exe" (
            "%%~dpi..\bin\bash.exe" -l ctx.sh %*
            goto done
        )
    )
)

echo [Error] Git Bash is required to run ctx on Windows.
echo Please install Git for Windows or ensure C:\Program Files\Git\bin\bash.exe exists.
exit /b 1

:done
set "CTX_EXIT=%ERRORLEVEL%"
popd
exit /b %CTX_EXIT%
