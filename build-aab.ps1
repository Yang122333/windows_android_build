# ===== Android AAB Build Script (Unity Project) =====
# Version: 15
# Usage: powershell -ExecutionPolicy Bypass -File .\build-aab.ps1
# Put this script in the same folder as your project .zip file

$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
$WORKSPACE = "$SCRIPT_DIR\android-build"
$TOOLS_DIR = "$WORKSPACE\_tools"
$LOG_FILE = "$SCRIPT_DIR\build-log.txt"

# Clear old log
"Build started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" | Out-File $LOG_FILE -Force

$ErrorActionPreference = "Stop"

# Log helper - write to both console and file
function Write-Step($msg) { 
    $text = "`n>>> $msg"
    Write-Host $text -ForegroundColor Cyan
    $text | Out-File $LOG_FILE -Append
}
function Write-Ok($msg) { 
    $text = "    [OK] $msg"
    Write-Host $text -ForegroundColor Green
    $text | Out-File $LOG_FILE -Append
}
function Write-Skip($msg) { 
    $text = "    [SKIP] $msg"
    Write-Host $text -ForegroundColor Yellow
    $text | Out-File $LOG_FILE -Append
}
function Write-Err($msg) { 
    $text = "    [ERROR] $msg"
    Write-Host $text -ForegroundColor Red
    $text | Out-File $LOG_FILE -Append
}

try {

# ===== 1. Find and extract project zip =====
Write-Step "Finding project zip..."
$zipFiles = @(Get-ChildItem -Path $SCRIPT_DIR -Filter "*.zip" -File | Where-Object { $_.Name -ne "jdk.zip" -and $_.Name -ne "cmdline-tools.zip" })
if ($zipFiles.Count -eq 0) {
    Write-Err "No zip file found. Put your project zip in the same folder as this script."
    throw "No zip file found"
} elseif ($zipFiles.Count -eq 1) {
    $zipFile = $zipFiles[0].FullName
    Write-Ok "Found: $($zipFiles[0].Name)"
} else {
    # Auto-select the largest zip (project zip is usually the biggest)
    $largest = $zipFiles | Sort-Object Length -Descending | Select-Object -First 1
    Write-Host "    Multiple zip files found, auto-selecting largest:" -ForegroundColor Yellow
    foreach ($z in $zipFiles) {
        Write-Host "      $($z.Name) ($([math]::Round($z.Length / 1MB, 1)) MB)"
    }
    $zipFile = $largest.FullName
    Write-Ok "Selected: $($largest.Name)"
}

$PROJECT_DIR = "$WORKSPACE\project"
if (Test-Path $PROJECT_DIR) { 
    Write-Host "    Cleaning old project dir..." -ForegroundColor Gray
    cmd /c "rmdir /s /q `"$PROJECT_DIR`"" 2>$null
    Start-Sleep -Seconds 1
    if (Test-Path $PROJECT_DIR) {
        Remove-Item -Recurse -Force $PROJECT_DIR -ErrorAction SilentlyContinue
    }
}
New-Item -ItemType Directory -Force -Path $PROJECT_DIR | Out-Null

Write-Step "Extracting project..."
$ProgressPreference = 'SilentlyContinue'
Expand-Archive -Path $zipFile -DestinationPath $PROJECT_DIR -Force *>&1 | Out-Null
$ProgressPreference = 'Continue'
Write-Ok "Extracted"

# Navigate into the single subfolder if needed
$subDirs = Get-ChildItem -Path $PROJECT_DIR -Directory | Where-Object { $_.Name -ne "__MACOSX" }
if ($subDirs.Count -eq 1 -and -not (Test-Path "$PROJECT_DIR\build.gradle") -and -not (Test-Path "$PROJECT_DIR\gradlew.bat")) {
    $PROJECT_DIR = $subDirs[0].FullName
}
Write-Ok "Project dir: $PROJECT_DIR"

# ===== 1b. Patch unityLibrary/build.gradle - disable IL2CPP build tasks =====
$unityBuildGradle = "$PROJECT_DIR\unityLibrary\build.gradle"
if (Test-Path $unityBuildGradle) {
    Write-Step "Patching unityLibrary/build.gradle (disable IL2CPP tasks)..."
    $lines = Get-Content $unityBuildGradle
    $patched = $false

    # Comment out entire blocks: def BuildIl2Cpp function, BuildIl2CppTask,
    # afterEvaluate referencing BuildIl2CppTask, sourceSets with Il2CppOutputProject
    $inBlock = $false
    $braceDepth = 0
    $blockStartKeywords = @("def BuildIl2Cpp", "task BuildIl2CppTask")
    $blockStartLine = -1

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]

        if (-not $inBlock) {
            # Check if this line starts a block we want to disable
            $startBlock = $false
            foreach ($kw in $blockStartKeywords) {
                if ($line -match [regex]::Escape($kw)) { $startBlock = $true; break }
            }
            # Also catch afterEvaluate that references BuildIl2CppTask (look ahead)
            if (-not $startBlock -and $line -match 'afterEvaluate\s*\{') {
                $lookAhead = ($lines[$i..([Math]::Min($i+10, $lines.Count-1))]) -join "`n"
                if ($lookAhead -match 'BuildIl2CppTask') { $startBlock = $true }
            }
            # Also catch sourceSets with Il2CppOutputProject
            if (-not $startBlock -and $line -match 'sourceSets\s*\{') {
                $lookAhead = ($lines[$i..([Math]::Min($i+10, $lines.Count-1))]) -join "`n"
                if ($lookAhead -match 'Il2CppOutputProject') { $startBlock = $true }
            }

            if ($startBlock) {
                $inBlock = $true
                $braceDepth = 0
                $blockStartLine = $i
            }
        }

        if ($inBlock) {
            # Count braces
            foreach ($ch in $line.ToCharArray()) {
                if ($ch -eq '{') { $braceDepth++ }
                elseif ($ch -eq '}') { $braceDepth-- }
            }
            # Comment out this line
            if ($line -notmatch '^\s*//') {
                $lines[$i] = "// [DISABLED] $line"
                $patched = $true
            }
            # Block ends when braces balance back to 0 (and we opened at least one)
            if ($braceDepth -le 0 -and $i -gt $blockStartLine) {
                $inBlock = $false
            }
        }
    }

    if ($patched) {
        [System.IO.File]::WriteAllLines($unityBuildGradle, $lines)
        Write-Ok "IL2CPP build tasks commented out"
    } else {
        Write-Skip "No IL2CPP tasks found to patch"
    }
} else {
    Write-Skip "No unityLibrary/build.gradle found"
}

# ===== 2. Detect project structure =====
Write-Step "Detecting project structure..."

# Find the app module (could be app/, launcher/, etc.)
$appModule = $null
$appBuildGradle = $null
foreach ($candidate in @("launcher", "app")) {
    $gFile = "$PROJECT_DIR\$candidate\build.gradle"
    $gFileKts = "$PROJECT_DIR\$candidate\build.gradle.kts"
    if (Test-Path $gFile) {
        $content = Get-Content $gFile -Raw
        if ($content -match "com\.android\.application") {
            $appModule = $candidate
            $appBuildGradle = $content
            break
        }
    }
    if (Test-Path $gFileKts) {
        $content = Get-Content $gFileKts -Raw
        if ($content -match "com\.android\.application") {
            $appModule = $candidate
            $appBuildGradle = $content
            break
        }
    }
}

# Fallback: scan all subdirs for the application plugin
if (-not $appModule) {
    $dirs = Get-ChildItem -Path $PROJECT_DIR -Directory
    foreach ($d in $dirs) {
        $gFile = "$($d.FullName)\build.gradle"
        if (Test-Path $gFile) {
            $content = Get-Content $gFile -Raw
            if ($content -match "com\.android\.application") {
                $appModule = $d.Name
                $appBuildGradle = $content
                break
            }
        }
    }
}

if (-not $appModule) {
    Write-Err "Cannot find application module. Directory contents:"
    Get-ChildItem $PROJECT_DIR | ForEach-Object { Write-Host "  $_" }
    throw "Cannot find application module"
}
Write-Ok "App module: $appModule"

# ===== 3. Read project config =====
Write-Step "Reading project config..."

$compileSdk = 34
if ($appBuildGradle -match 'compileSdk[Vv]ersion?\s+(\d+)') { $compileSdk = $Matches[1] }
elseif ($appBuildGradle -match 'compileSdk[Vv]ersion?\s*[=:]\s*(\d+)') { $compileSdk = $Matches[1] }
elseif ($appBuildGradle -match 'compileSdk\s*[=:]\s*(\d+)') { $compileSdk = $Matches[1] }

$buildTools = "$compileSdk.0.0"
if ($appBuildGradle -match "buildToolsVersion\s*[=:]*\s*[`"']([^`"']+)") { $buildTools = $Matches[1] }

$minSdk = ""; $targetSdk = ""
if ($appBuildGradle -match 'minSdk[Vv]ersion?\s*(\d+)') { $minSdk = $Matches[1] }
if ($appBuildGradle -match 'targetSdk[Vv]ersion?\s*(\d+)') { $targetSdk = $Matches[1] }

# Detect JDK version from JavaVersion.VERSION_XX
$jdkVersion = 17
if ($appBuildGradle -match 'JavaVersion\.VERSION_(\d+)') { $jdkVersion = [int]$Matches[1] }

$gradleVersion = "8.7"
$wrapperProps = "$PROJECT_DIR\gradle\wrapper\gradle-wrapper.properties"
if (Test-Path $wrapperProps) {
    $wc = Get-Content $wrapperProps -Raw
    if ($wc -match 'gradle-(\d+\.\d+(\.\d+)?)-') { $gradleVersion = $Matches[1] }
}

Write-Host "    Config:" -ForegroundColor White
Write-Host "      compileSdk:     $compileSdk"
Write-Host "      buildTools:     $buildTools"
Write-Host "      minSdk:         $minSdk"
Write-Host "      targetSdk:      $targetSdk"
Write-Host "      Gradle:         $gradleVersion"
Write-Host "      JDK needed:     $jdkVersion"

# ===== 4. Check / Install JDK =====
Write-Step "Checking JDK..."

$javaOk = $false
try {
    $javaVer = cmd /c "java -version 2>&1" | Select-Object -First 1
    if ($javaVer -match '(\d+)[\.\"]') {
        $existingMajor = [int]$Matches[1]
        if ($existingMajor -ge $jdkVersion) {
            Write-Skip "JDK $existingMajor found (need >= $jdkVersion)"
            $javaOk = $true
            # Make sure JAVA_HOME is set
            if (-not $env:JAVA_HOME) {
                try {
                    $javaPath = (cmd /c "where java 2>&1") | Select-Object -First 1
                    if ($javaPath -and (Test-Path $javaPath)) {
                        $env:JAVA_HOME = (Split-Path (Split-Path $javaPath))
                    }
                } catch {}
            }
            # Also ensure keytool is on PATH
            $env:PATH = "$env:JAVA_HOME\bin;$env:PATH"
        } else {
            Write-Host "    JDK $existingMajor found but need >= $jdkVersion" -ForegroundColor Yellow
        }
    }
} catch {}

if (-not $javaOk) {
    # Check if we already downloaded JDK in a previous run
    $existingJdkDir = $null
    if (Test-Path $TOOLS_DIR) {
        $existingJdkDir = Get-ChildItem $TOOLS_DIR -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^jdk' } | Select-Object -First 1
    }

    if ($existingJdkDir) {
        Write-Skip "JDK already downloaded: $($existingJdkDir.FullName)"
        $env:JAVA_HOME = $existingJdkDir.FullName
        $env:PATH = "$($existingJdkDir.FullName)\bin;$env:PATH"
    } else {
        Write-Host "    Installing JDK $jdkVersion..." -ForegroundColor White
        New-Item -ItemType Directory -Force -Path $TOOLS_DIR | Out-Null

        $jdkUrls = @{
            17 = "https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.12%2B7/OpenJDK17U-jdk_x64_windows_hotspot_17.0.12_7.zip"
            21 = "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.4%2B7/OpenJDK21U-jdk_x64_windows_hotspot_21.0.4_7.zip"
        }

        if ($jdkVersion -le 17) {
            $jdkUrl = $jdkUrls[17]
            $jdkVersion = 17
            Write-Host "    Using Adoptium JDK 17 (free, no login required)" -ForegroundColor Yellow
        } elseif ($jdkUrls.ContainsKey($jdkVersion)) {
            $jdkUrl = $jdkUrls[$jdkVersion]
        } else {
            $jdkUrl = $jdkUrls[17]
            $jdkVersion = 17
            Write-Host "    No preset URL for requested JDK, using JDK 17" -ForegroundColor Yellow
        }

        $jdkZip = "$TOOLS_DIR\jdk.zip"
        # Skip download if zip already exists
        if (Test-Path $jdkZip) {
            Write-Skip "JDK zip already downloaded, extracting..."
        } else {
            Write-Host "    Downloading JDK... (may take a few minutes)" -ForegroundColor White
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $jdkUrl -OutFile $jdkZip -UseBasicParsing
        }
        Write-Host "    Extracting JDK..." -ForegroundColor White
        Expand-Archive $jdkZip -DestinationPath $TOOLS_DIR -Force

        $jdkDir = Get-ChildItem $TOOLS_DIR -Directory | Where-Object { $_.Name -match '^jdk' } | Select-Object -First 1
        $env:JAVA_HOME = $jdkDir.FullName
        $env:PATH = "$($jdkDir.FullName)\bin;$env:PATH"
        Write-Ok "JDK installed: $($jdkDir.FullName)"
    }
} else {
    if (-not $env:JAVA_HOME) {
        $env:JAVA_HOME = (Get-Command java).Source | Split-Path | Split-Path
    }
}

# ===== 5. Check / Install Android SDK =====
Write-Step "Checking Android SDK..."

$sdkOk = $false
if ($env:ANDROID_HOME -and (Test-Path "$env:ANDROID_HOME\cmdline-tools")) {
    Write-Skip "ANDROID_HOME found: $env:ANDROID_HOME"
    $sdkOk = $true
} elseif ($env:ANDROID_SDK_ROOT -and (Test-Path "$env:ANDROID_SDK_ROOT")) {
    $env:ANDROID_HOME = $env:ANDROID_SDK_ROOT
    Write-Skip "ANDROID_SDK_ROOT found: $env:ANDROID_SDK_ROOT"
    $sdkOk = $true
}

if (-not $sdkOk) {
    $sdkDir = "$TOOLS_DIR\android-sdk"

    # Check if SDK was downloaded in a previous run
    if (Test-Path "$sdkDir\cmdline-tools\latest\bin\sdkmanager.bat") {
        Write-Skip "Android SDK already downloaded: $sdkDir"
        $env:ANDROID_HOME = $sdkDir
        $env:PATH = "$sdkDir\cmdline-tools\latest\bin;$sdkDir\platform-tools;$env:PATH"
    } else {
        Write-Host "    Installing Android SDK..." -ForegroundColor White
        New-Item -ItemType Directory -Force -Path $TOOLS_DIR | Out-Null
        New-Item -ItemType Directory -Force -Path "$sdkDir\cmdline-tools" | Out-Null

        $cmdToolsUrl = "https://dl.google.com/android/repository/commandlinetools-win-11076708_latest.zip"
        $cmdToolsZip = "$TOOLS_DIR\cmdline-tools.zip"
        if (Test-Path $cmdToolsZip) {
            Write-Skip "SDK zip already downloaded, extracting..."
        } else {
            Write-Host "    Downloading SDK command-line tools..." -ForegroundColor White
            Invoke-WebRequest -Uri $cmdToolsUrl -OutFile $cmdToolsZip -UseBasicParsing
        }
        Expand-Archive $cmdToolsZip -DestinationPath "$sdkDir\cmdline-tools" -Force

        $extractedDir = "$sdkDir\cmdline-tools\cmdline-tools"
        $latestDir = "$sdkDir\cmdline-tools\latest"
        if (Test-Path $extractedDir) {
            if (Test-Path $latestDir) { Remove-Item -Recurse -Force $latestDir }
            Rename-Item $extractedDir "latest"
        }

        $env:ANDROID_HOME = $sdkDir
        $env:PATH = "$sdkDir\cmdline-tools\latest\bin;$sdkDir\platform-tools;$env:PATH"

        Write-Host "    Accepting licenses..." -ForegroundColor White
        $yesInput = ("y`n" * 30)
        $yesInput | & "$sdkDir\cmdline-tools\latest\bin\sdkmanager.bat" --licenses 2>$null

        Write-Ok "Android SDK installed: $sdkDir"
    }
}

# Install required SDK components
Write-Step "Installing SDK components (compileSdk=$compileSdk, buildTools=$buildTools)..."
$sdkmanager = "$env:ANDROID_HOME\cmdline-tools\latest\bin\sdkmanager.bat"
if (Test-Path $sdkmanager) {
    & $sdkmanager "platforms;android-$compileSdk" "build-tools;$buildTools" "platform-tools" 2>$null
    Write-Ok "SDK components installed"
} else {
    Write-Skip "sdkmanager not found, assuming SDK components are present"
}

# ===== 6. Fix local.properties =====
Write-Step "Configuring local.properties..."
$localProps = "$PROJECT_DIR\local.properties"
$sdkPath = $env:ANDROID_HOME -replace '\\', '/'
Set-Content $localProps "sdk.dir=$sdkPath"
Write-Ok "sdk.dir=$sdkPath"

# ===== 7. Create signing keystore =====
Write-Step "Setting up signing..."

$keystorePath = "$PROJECT_DIR\release.keystore"

# Find keytool - try multiple locations
$keytool = $null
$keytoolSearchPaths = @()

# Try 1: JAVA_HOME from environment
if ($env:JAVA_HOME) { $keytoolSearchPaths += "$env:JAVA_HOME\bin\keytool.exe" }

# Try 2: Common user JDK locations (all users)
foreach ($userDir in @(Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue)) {
    $jdksDir = "$($userDir.FullName)\.jdks"
    if (Test-Path $jdksDir) {
        foreach ($jdk in @(Get-ChildItem $jdksDir -Directory -ErrorAction SilentlyContinue)) {
            $keytoolSearchPaths += "$($jdk.FullName)\bin\keytool.exe"
        }
    }
}

# Try 3: Our downloaded JDK
if (Test-Path $TOOLS_DIR) {
    foreach ($d in @(Get-ChildItem $TOOLS_DIR -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^jdk' })) {
        $keytoolSearchPaths += "$($d.FullName)\bin\keytool.exe"
    }
}

# Try 4: Program Files
foreach ($pf in @("C:\Program Files\Java", "C:\Program Files\Eclipse Adoptium", "C:\Program Files (x86)\Java")) {
    if (Test-Path $pf) {
        foreach ($found in @(Get-ChildItem $pf -Recurse -Filter "keytool.exe" -ErrorAction SilentlyContinue)) {
            $keytoolSearchPaths += $found.FullName
        }
    }
}

# Find first existing keytool
foreach ($kt in $keytoolSearchPaths) {
    if (Test-Path $kt) {
        $keytool = $kt
        $env:JAVA_HOME = (Split-Path (Split-Path $kt))
        $env:PATH = "$(Split-Path $kt);$env:PATH"
        break
    }
}

if (-not $keytool) {
    throw "Cannot find keytool.exe anywhere. Searched: $($keytoolSearchPaths -join ', ')"
}
Write-Ok "keytool found: $keytool"

if (Test-Path $keystorePath) { Remove-Item $keystorePath -Force }

Write-Host "    Creating new signing keystore..." -ForegroundColor White
Write-Host "    (password/alias/country are required, others can be skipped)" -ForegroundColor Gray

# Required fields - loop until not empty
$storePass = ""
while ([string]::IsNullOrEmpty($storePass) -or $storePass.Length -lt 6) {
    $storePass = Read-Host "    Keystore password (min 6 chars, required)"
}

$keyAlias = ""
while ([string]::IsNullOrEmpty($keyAlias)) {
    $keyAlias = Read-Host "    Key alias (e.g. mykey, required)"
}

$keyPass = Read-Host "    Key password (Enter if same as keystore)"
if ([string]::IsNullOrEmpty($keyPass)) { $keyPass = $storePass }

$country = ""
while ([string]::IsNullOrEmpty($country)) {
    $country = Read-Host "    Country code (e.g. CN, required)"
}

# Optional fields
$cnName = Read-Host "    Your name (CN, Enter to skip)"
$org = Read-Host "    Organization (O, Enter to skip)"

if ([string]::IsNullOrEmpty($cnName)) { $cnName = "Developer" }

$dname = "CN=$cnName, C=$country"
if (-not [string]::IsNullOrEmpty($org)) { $dname += ", O=$org" }

    & $keytool -genkeypair -v `
        -keystore $keystorePath `
        -alias $keyAlias `
        -keyalg RSA -keysize 2048 -validity 10000 `
        -storepass $storePass -keypass $keyPass `
        -dname $dname

    if (-not (Test-Path $keystorePath)) {
        Write-Err "Failed to create keystore"
        throw "Failed to create keystore"
    }
    Write-Ok "Keystore created: $keystorePath"

# ===== 8. Inject signing config into build.gradle =====
Write-Step "Injecting signing config..."

$appGradlePath = "$PROJECT_DIR\$appModule\build.gradle"
$gradleContent = Get-Content $appGradlePath -Raw

# Build the signingConfigs block
$ksPathEscaped = ($keystorePath -replace '\\', '/').Replace("'", "\\'")
$signingBlock = @"

    signingConfigs {
        release {
            storeFile file('$ksPathEscaped')
            storePassword '$storePass'
            keyAlias '$keyAlias'
            keyPassword '$keyPass'
        }
    }
"@

# Insert signingConfigs inside android { } block, right after the opening
if ($gradleContent -notmatch 'signingConfigs\s*\{[^}]*release') {
    # Match exactly "android {" at line start, not "androidJunkCode {" etc.
    $gradleContent = $gradleContent -replace '(?m)(^android\b\s*\{)', "`$1`n$signingBlock"
    Write-Ok "signingConfigs block added"
} else {
    Write-Skip "signingConfigs already exists"
}

# Point release buildType to our signing config
$gradleContent = $gradleContent -replace 'signingConfig\s+signingConfigs\.\w+', 'signingConfig signingConfigs.release'
Write-Ok "release buildType -> signingConfigs.release"

[System.IO.File]::WriteAllText($appGradlePath, $gradleContent)
Write-Ok "build.gradle updated"

# ===== 9. Fix NDK path (remove hardcoded Mac path) =====
if ($gradleContent -match 'ndkPath\s') {
    $gradleContent = Get-Content $appGradlePath -Raw
    $gradleContent = $gradleContent -replace '(?m)^\s*ndkPath\s.*$', '    // ndkPath removed by build script'
    [System.IO.File]::WriteAllText($appGradlePath, $gradleContent)
    Write-Ok "Removed hardcoded ndkPath (not needed for AAB)"
}

# ===== 10. Set Gradle JDK =====
Write-Step "Configuring Gradle..."
$gpFile = "$PROJECT_DIR\gradle.properties"
$javaHomePath = $env:JAVA_HOME -replace '\\', '/'
if (Test-Path $gpFile) {
    $gpContent = Get-Content $gpFile -Raw
    if ($gpContent -notmatch 'org\.gradle\.java\.home') {
        Add-Content $gpFile "`norg.gradle.java.home=$javaHomePath"
    } else {
        $gpContent = $gpContent -replace 'org\.gradle\.java\.home=.*', "org.gradle.java.home=$javaHomePath"
        [System.IO.File]::WriteAllText($gpFile, $gpContent)
    }
} else {
    Set-Content $gpFile "org.gradle.java.home=$javaHomePath"
}
Write-Ok "Gradle JDK -> $javaHomePath"

# ===== 11. Download Gradle wrapper if missing =====
Set-Location $PROJECT_DIR

# Replace Gradle distribution URL with Tencent mirror (faster in China)
$wrapperProps = "$PROJECT_DIR\gradle\wrapper\gradle-wrapper.properties"
if (Test-Path $wrapperProps) {
    $wpContent = Get-Content $wrapperProps -Raw
    $wpContent = $wpContent -replace 'https\\://services\.gradle\.org/distributions/', 'https\://mirrors.cloud.tencent.com/gradle/'
    # Use ASCII encoding to avoid BOM (PS 5.1 UTF8 adds BOM which breaks Gradle)
    [System.IO.File]::WriteAllText($wrapperProps, $wpContent)
    Write-Ok "Gradle mirror -> Tencent (faster download)"
}

if (-not (Test-Path "gradlew.bat")) {
    Write-Step "gradlew.bat not found, creating wrapper..."
    # Download gradle wrapper jar
    $wrapperDir = "$PROJECT_DIR\gradle\wrapper"
    New-Item -ItemType Directory -Force -Path $wrapperDir | Out-Null
    $wrapperJarUrl = "https://raw.githubusercontent.com/gradle/gradle/master/gradle/wrapper/gradle-wrapper.jar"
    Invoke-WebRequest -Uri $wrapperJarUrl -OutFile "$wrapperDir\gradle-wrapper.jar" -UseBasicParsing

    # Create gradlew.bat
    $gradlewBat = @'
@rem Gradle startup script for Windows
@if "%DEBUG%"=="" @echo off
set DIRNAME=%~dp0
set APP_BASE_NAME=%~n0
set APP_HOME=%DIRNAME%
set DEFAULT_JVM_OPTS="-Xmx64m" "-Xms64m"
set CLASSPATH=%APP_HOME%\gradle\wrapper\gradle-wrapper.jar
@rem Execute Gradle
"%JAVA_HOME%/bin/java.exe" %DEFAULT_JVM_OPTS% %JAVA_OPTS% -classpath "%CLASSPATH%" org.gradle.wrapper.GradleWrapperMain %*
'@
    Set-Content "gradlew.bat" $gradlewBat -Encoding ASCII
    Write-Ok "gradlew.bat created"
}

# ===== 12. Build AAB =====
Write-Step "Building AAB... (this may take several minutes)"
Write-Host "    Running: gradlew.bat :${appModule}:bundleRelease" -ForegroundColor White
Write-Host "    Build output also saved to: $LOG_FILE" -ForegroundColor Gray

$ErrorActionPreference = "Continue"
$buildLog = & .\gradlew.bat ":${appModule}:bundleRelease" --no-daemon --stacktrace 2>&1
$buildExitCode = $LASTEXITCODE
$ErrorActionPreference = "Stop"

# Write build output to console and log
foreach ($line in $buildLog) {
    Write-Host $line
    "$line" | Out-File $LOG_FILE -Append
}

if ($buildExitCode -ne 0) {
    Write-Err "Build failed! Last 30 lines:"
    $buildLog | Select-Object -Last 30 | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
    Write-Host "`nCommon fixes:" -ForegroundColor Yellow
    Write-Host "  - Missing SDK component: check compileSdk/buildTools versions"
    Write-Host "  - Memory error: increase org.gradle.jvmargs in gradle.properties"
    Write-Host "  - NDK error: install NDK via sdkmanager"
    throw "Build failed"
}

# ===== 13. Find and copy AAB =====
Write-Step "Finding AAB output..."
$aabFiles = Get-ChildItem -Path $PROJECT_DIR -Recurse -Filter "*.aab"
if ($aabFiles.Count -gt 0) {
    foreach ($aab in $aabFiles) {
        $destName = "output-$(Get-Date -Format 'yyyyMMdd-HHmmss').aab"
        Copy-Item $aab.FullName "$SCRIPT_DIR\$destName"
        Write-Ok "AAB ready: $SCRIPT_DIR\$destName"
        Write-Host "    Source: $($aab.FullName)" -ForegroundColor Gray
        Write-Host "    Size:   $([math]::Round($aab.Length / 1MB, 2)) MB" -ForegroundColor Gray
    }
} else {
    Write-Err "No AAB file found. Check build output."
}

Write-Host "`n===== DONE =====" -ForegroundColor Green
Write-Host "Log saved to: $LOG_FILE" -ForegroundColor Gray

} catch {
    Write-Host "`n!!! ERROR: $_" -ForegroundColor Red
    Write-Host "Stack: $($_.ScriptStackTrace)" -ForegroundColor Red
    Write-Host "`nLog saved to: $LOG_FILE" -ForegroundColor Yellow
    "ERROR: $_" | Out-File $LOG_FILE -Append
    "Stack: $($_.ScriptStackTrace)" | Out-File $LOG_FILE -Append
    exit 1
}

"Build completed: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" | Out-File $LOG_FILE -Append
