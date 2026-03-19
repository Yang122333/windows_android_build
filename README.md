# Windows Android Build

One-click PowerShell script to build Android AAB on a fresh Windows machine.

## Features

- Auto-detect and install JDK (Adoptium)
- Auto-detect and install Android SDK
- Auto-read project config (compileSdk, buildTools, Gradle version)
- Interactive keystore creation for release signing
- Unity project support (launcher module, IL2CPP task patching)
- Gradle Tencent mirror for faster downloads in China
- Caches downloads - no re-download on retry

## Usage

1. Put `build-aab.ps1` and your project `.zip` in the same folder
2. Run in PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\build-aab.ps1
```

3. Enter signing info when prompted
4. AAB output will be copied to the script folder

## Requirements

- Windows 10+
- PowerShell 5.1+
- Internet connection (for JDK/SDK/Gradle download)
