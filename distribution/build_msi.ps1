# VoxelShift MSI Build Script (WiX Toolset)
# Builds a classic MSI installer using WiX v4 (wix CLI)
# Usage: .\build_msi.ps1 [-SkipBuild]

param (
    [switch]$SkipBuild
)

Write-Host "[*] VoxelShift MSI Build Script" -ForegroundColor Cyan
Write-Host ""

$startTime = Get-Date
$rootPath = Split-Path -Parent $PSScriptRoot
$msiDir = Join-Path $PSScriptRoot "msi"
$releasesDir = Join-Path $PSScriptRoot "releases"
$upgradeCode = "0F6A2F8E-2C67-4E52-AE5D-98DF7E3C9B3D"

function Require-Command($name) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($null -eq $cmd) {
        throw "Missing required tool: $name"
    }
}

function Get-PubspecVersion($pubspecPath) {
    $line = Get-Content $pubspecPath | Where-Object { $_ -match '^version:' } | Select-Object -First 1
    if (-not $line) {
        throw "Could not read version from pubspec.yaml"
    }
    $version = $line.Split(':')[1].Trim()
    if ($version.Contains('+')) {
        $version = $version.Split('+')[0].Trim()
    }
    return $version
}

function Get-PathId([string]$prefix, [string]$basePath, [string]$fullPath) {
    $relative = Resolve-Path $fullPath | ForEach-Object {
        $_.Path.Substring($basePath.Length).TrimStart("\\")
    }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($relative.ToLowerInvariant())
    $hashBytes = [System.Security.Cryptography.SHA1]::Create().ComputeHash($bytes)
    $hash = [BitConverter]::ToString($hashBytes).Replace("-", "")
    return "{0}{1}" -f $prefix, $hash.Substring(0, 16)
}

function Convert-TextToRtf([string]$text) {
    $lines = $text -split "`r`n|`n|`r"
    $rtfLines = New-Object System.Collections.Generic.List[string]
    foreach ($line in $lines) {
        if ([string]::IsNullOrEmpty($line)) {
            $rtfLines.Add("\par") | Out-Null
            continue
        }

        $match = [regex]::Match($line, '^( +)')
        $indent = $match.Value.Length
        $tabs = [math]::Floor($indent / 4)
        $spaces = $indent % 4
        $prefix = ("\tab" * $tabs) + (" " * $spaces)

        $content = $line.Substring($indent)
        $escaped = $content -replace '\\', '\\\\'
        $escaped = $escaped -replace '{', '\{'
        $escaped = $escaped -replace '}', '\}'

        $rtfLines.Add("$prefix$escaped\line") | Out-Null
    }

    $body = ($rtfLines -join "`r`n")
    return "{\rtf1\ansi\deff0\viewkind4\uc1\pard`r`n$body`r`n}"
}

$global:fileCount = 0

function Write-DirectoryTree($writer, $basePath, $path, $componentIds) {
    $files = Get-ChildItem -Path $path -File
    foreach ($file in $files) {
        $global:fileCount++
        if ($global:fileCount % 100 -eq 0) {
            Write-Host -NoNewline "."
        }
        
        $cmpId = Get-PathId "cmp" $basePath $file.FullName
        $fileId = Get-PathId "fil" $basePath $file.FullName
        $writer.WriteStartElement("Component")
        $writer.WriteAttributeString("Id", $cmpId)
        $writer.WriteAttributeString("Guid", "*")
        $writer.WriteStartElement("File")
        $writer.WriteAttributeString("Id", $fileId)
        $writer.WriteAttributeString("Source", $file.FullName)
        $writer.WriteEndElement()
        $writer.WriteEndElement()
        $componentIds.Add($cmpId) | Out-Null
    }

    $dirs = Get-ChildItem -Path $path -Directory
    foreach ($dir in $dirs) {
        $dirId = Get-PathId "dir" $basePath $dir.FullName
        $writer.WriteStartElement("Directory")
        $writer.WriteAttributeString("Id", $dirId)
        $writer.WriteAttributeString("Name", $dir.Name)
        Write-DirectoryTree $writer $basePath $dir.FullName $componentIds
        $writer.WriteEndElement()
    }
}

function Write-AppFilesWxs($sourceDir, $outputPath) {
    $settings = New-Object System.Xml.XmlWriterSettings
    $settings.Indent = $true
    $settings.OmitXmlDeclaration = $false

    $componentIds = New-Object System.Collections.Generic.List[string]

    $writer = [System.Xml.XmlWriter]::Create($outputPath, $settings)
    $writer.WriteStartDocument()
    $writer.WriteStartElement("Wix", "http://wixtoolset.org/schemas/v4/wxs")

    $writer.WriteStartElement("Fragment")
    $writer.WriteStartElement("DirectoryRef")
    $writer.WriteAttributeString("Id", "INSTALLFOLDER")
    Write-DirectoryTree $writer $sourceDir $sourceDir $componentIds
    $writer.WriteEndElement()
    $writer.WriteEndElement()

    $writer.WriteStartElement("Fragment")
    $writer.WriteStartElement("ComponentGroup")
    $writer.WriteAttributeString("Id", "AppFiles")
    foreach ($id in $componentIds) {
        $writer.WriteStartElement("ComponentRef")
        $writer.WriteAttributeString("Id", $id)
        $writer.WriteEndElement()
    }
    $writer.WriteEndElement()
    $writer.WriteEndElement()

    $writer.WriteEndElement()
    $writer.WriteEndDocument()
    $writer.Close()
}

try {
    Set-Location $rootPath

    # Ensure WiX v4 CLI exists
    Require-Command wix

    # Get dependencies
    if (-not $SkipBuild) {
        Write-Host "[*] Getting Flutter dependencies..." -ForegroundColor Yellow
        flutter pub get
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to get dependencies"
        }

        # Build Windows app (release)
        Write-Host "`n[*] Building Flutter Windows app (Release)..." -ForegroundColor Yellow
        flutter build windows --release
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to build Windows app"
        }
    } else {
        Write-Host "[*] Skipping Flutter build (assumed pre-built)..." -ForegroundColor Gray
    }

    $pubspecPath = Join-Path $rootPath "pubspec.yaml"
    $productVersion = Get-PubspecVersion $pubspecPath
    $productName = "VoxelShift"
    $manufacturer = "Open Resin Alliance"

    $sourceDir = Join-Path $rootPath "build\windows\x64\runner\Release"
    if (-not (Test-Path $sourceDir)) {
        throw "Build output not found: $sourceDir"
    }

    # Generate WiX UI images if missing
    $bannerPath = Join-Path $msiDir "assets\ora_banner.png"
    $dialogPath = Join-Path $msiDir "assets\ora_dialog.png"
    $imageGenerator = Join-Path $msiDir "generate_wix_images.dart"
    if (-not (Test-Path $bannerPath) -or -not (Test-Path $dialogPath)) {
        Write-Host "`n[*] Generating WiX UI images..." -ForegroundColor Yellow
        & dart run $imageGenerator
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to generate WiX UI images"
        }
    }

    # Prepare output directories
    if (-not (Test-Path $msiDir)) {
        New-Item -ItemType Directory -Path $msiDir -Force | Out-Null
    }
    if (-not (Test-Path $releasesDir)) {
        New-Item -ItemType Directory -Path $releasesDir -Force | Out-Null
    }

    $msiAssetsDir = Join-Path $msiDir "assets"
    if (-not (Test-Path $msiAssetsDir)) {
        New-Item -ItemType Directory -Path $msiAssetsDir -Force | Out-Null
    }

    $licenseSource = Join-Path $rootPath "LICENSE"
    $licenseRtf = Join-Path $msiAssetsDir "license.rtf"
    if (-not (Test-Path $licenseSource)) {
        throw "LICENSE file not found: $licenseSource"
    }
    $licenseText = Get-Content -Raw -Path $licenseSource
    $licenseRtfContent = Convert-TextToRtf $licenseText
    Set-Content -Path $licenseRtf -Value $licenseRtfContent -Encoding UTF8

    Write-Host "`n[*] Harvesting build output..." -ForegroundColor Yellow
    $appFilesWxs = Join-Path $msiDir "AppFiles.wxs"
    $installerWxs = Join-Path $msiDir "installer.wxs"
    $timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $msiName = "VoxelShift_$productVersion_$timestamp.msi"
    $msiOut = Join-Path $releasesDir $msiName

    Write-AppFilesWxs $sourceDir $appFilesWxs

    Write-Host "`n[*] Building MSI with WiX v4..." -ForegroundColor Yellow
    & wix build $installerWxs $appFilesWxs -o $msiOut -ext WixToolset.UI.wixext -b $msiDir `
        -d ProductVersion=$productVersion `
        -d ProductName="$productName" `
        -d Manufacturer="$manufacturer" `
        -d UpgradeCode=$upgradeCode
    if ($LASTEXITCODE -ne 0) {
        throw "wix build failed"
    }

    $duration = (Get-Date) - $startTime
    Write-Host "`n[SUCCESS] MSI Build Complete!" -ForegroundColor Green
    Write-Host "    MSI File: $msiOut" -ForegroundColor Green
    Write-Host "    Version: $productVersion" -ForegroundColor Green
    Write-Host "    Time: $($duration.TotalSeconds) seconds" -ForegroundColor Green
    Write-Host ""

} catch {
    if ($_.Exception.Message -like "Missing required tool*") {
        Write-Host "`n[ERROR] WiX Toolset v4 not found." -ForegroundColor Red
        Write-Host "Install WiX v4 CLI with:" -ForegroundColor Yellow
        Write-Host "  dotnet tool install --global wix" -ForegroundColor Gray
    } else {
        Write-Host "`n[ERROR] Build Failed: $_" -ForegroundColor Red
    }
    exit 1
}
