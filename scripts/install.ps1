# Repository and version information
$REPO_OWNER = "DaveHyperspace"
$REPO_SLUG = "aios-cli"
$CUDA_VERSION = "12.5.1"
$CUDA_PACKAGE_VERSION = "12-5"
$CUDA_PATH_VERSION = "12.5"

$LOG_FILE = "$env:TEMP\hyperspace_install.log"
$VERBOSE = $false

function Log {
    param (
        [string]$level,
        [string]$message
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp [$level] $message" | Out-File -Append -FilePath $LOG_FILE
    if ($VERBOSE -or $level -eq "ERROR") {
        Write-Host "[$level] $message"
    }
}

function Echo-And-Log {
    param (
        [string]$level,
        [string]$message
    )
    Write-Host $message
    Log $level $message
}

# Parse command line arguments
$args | ForEach-Object {
    switch ($_) {
        {$_ -in "-v", "--verbose"} { $VERBOSE = $true }
    }
}

function Detect-WindowsVersion {
    $osInfo = Get-CimInstance -ClassName Win32_OperatingSystem
    if ($osInfo.Caption -like "*Server 2022*") {
        return "Server2022"
    } elseif ([System.Environment]::OSVersion.Version.Major -eq 10) {
        if ([System.Environment]::OSVersion.Version.Build -ge 22000) {
            return "Windows11"
        } else {
            return "Windows10"
        }
    } else {
        return "Unknown"
    }
}

function Check-NvidiaGPU {
    $gpu = Get-WmiObject Win32_VideoController | Where-Object { $_.Name -like "*NVIDIA*" }
    return $null -ne $gpu
}

function Check-CUDA {
    return Test-Path "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v$CUDA_PATH_VERSION"
}

function Install-CUDA {
    $windowsVersion = Detect-WindowsVersion
    $cudaUrl = "https://developer.download.nvidia.com/compute/cuda/$CUDA_VERSION/local_installers/cuda_${CUDA_VERSION}_555.85_windows.exe"

    Echo-And-Log "INFO" "Downloading CUDA installer..."
    $installerPath = "$env:TEMP\cuda_installer.exe"
    Invoke-WebRequest -Uri $cudaUrl -OutFile $installerPath

    Echo-And-Log "INFO" "Installing CUDA..."
    Start-Process -FilePath $installerPath -ArgumentList "/s" -Wait

    # Clean up
    Remove-Item $installerPath

    Echo-And-Log "INFO" "CUDA $CUDA_VERSION installation complete."

    if (-not (Check-CUDA)) {
        Echo-And-Log "ERROR" "CUDA installation validation failed. Please check your installation."
        return $false
    }

    # Set up environment variables
    $cudaPath = "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v$CUDA_PATH_VERSION"
    $env:PATH += ";$cudaPath\bin"
    $env:PATH += ";$cudaPath\libnvvp"
    [System.Environment]::SetEnvironmentVariable("PATH", $env:PATH, [System.EnvironmentVariableTarget]::Machine)

    return $true
}

function Fetch-LatestRelease {
    $url = "https://api.github.com/repos/$REPO_OWNER/$REPO_SLUG/releases/latest"
    $response = Invoke-RestMethod -Uri $url
    return $response
}

function Get-DownloadUrl {
    param (
        [bool]$hasCuda
    )
    if ($hasCuda) {
        return "https://github.com/$REPO_OWNER/$REPO_SLUG/releases/latest/download/aios-cli-x86_64-pc-windows-msvc-cuda.zip"
    } else {
        return "https://github.com/$REPO_OWNER/$REPO_SLUG/releases/latest/download/aios-cli-x86_64-pc-windows-msvc.zip"
    }
}

function Download-WithRetry {
    param (
        [string]$url,
        [string]$output
    )
    $maxAttempts = 3
    $attempt = 1

    while ($attempt -le $maxAttempts) {
        try {
            Invoke-WebRequest -Uri $url -OutFile $output
            Echo-And-Log "INFO" "Download successful: $output"
            return $true
        } catch {
            Echo-And-Log "WARN" "Attempt $attempt failed. Retrying in 5 seconds..."
            Start-Sleep -Seconds 5
            $attempt++
        }
    }

    Echo-And-Log "ERROR" "Failed to download after $maxAttempts attempts."
    return $false
}

function Install-Binary {
    param (
        [string]$filename
    )
    $installDir = "$env:ProgramFiles\AIOS"

    Echo-And-Log "INFO" "Extracting $filename..."
    Expand-Archive -Path $filename -DestinationPath $env:TEMP\aios-temp

    $binaryName = "aios-cli.exe"
    $binaryPath = Get-ChildItem -Path $env:TEMP\aios-temp -Recurse -Filter $binaryName | Select-Object -First 1 -ExpandProperty FullName

    if (-not $binaryPath) {
        Echo-And-Log "ERROR" "Binary not found in the extracted files."
        return $false
    }

    Echo-And-Log "INFO" "Moving binary to $installDir"
    if (-not (Test-Path $installDir)) {
        New-Item -ItemType Directory -Path $installDir | Out-Null
    }
    Move-Item $binaryPath $installDir

    # Add to PATH
    $userPath = [Environment]::GetEnvironmentVariable("PATH", "User")
    if ($userPath -notlike "*$installDir*") {
        [Environment]::SetEnvironmentVariable("PATH", "$userPath;$installDir", "User")
    }

    # Clean up
    Remove-Item $filename
    Remove-Item $env:TEMP\aios-temp -Recurse

    # Validate installation
    if (-not (Get-Command aios-cli -ErrorAction SilentlyContinue)) {
        Echo-And-Log "ERROR" "Installation validation failed. The 'aios-cli' command is not available in PATH."
        return $false
    }

    return $true
}

function Main {
    Echo-And-Log "INFO" "Starting AIOS CLI installation..."

    $windowsVersion = Detect-WindowsVersion
    Echo-And-Log "INFO" "Detected Windows version: $windowsVersion"

    if ($windowsVersion -eq "Unknown") {
        Echo-And-Log "ERROR" "Unsupported Windows version."
        exit 1
    }

    Echo-And-Log "INFO" "Fetching latest release..."
    $releaseData = Fetch-LatestRelease
    if (-not $releaseData) {
        Echo-And-Log "ERROR" "Failed to fetch release data."
        exit 1
    }

    $version = $releaseData.tag_name
    Echo-And-Log "INFO" "Latest version: $version"

    $hasCuda = $false
    if (Check-NvidiaGPU) {
        Echo-And-Log "INFO" "NVIDIA GPU detected."
        if (-not (Check-CUDA)) {
            Echo-And-Log "INFO" "CUDA is not installed."
            $installCuda = Read-Host "Do you want to install CUDA drivers? (y/n)"
            if ($installCuda -eq "y") {
                if (Install-CUDA) {
                    Echo-And-Log "INFO" "CUDA installation completed successfully."
                    $hasCuda = $true
                } else {
                    Echo-And-Log "ERROR" "CUDA installation failed."
                    Echo-And-Log "INFO" "Proceeding with non-CUDA version."
                }
            } else {
                Echo-And-Log "INFO" "Proceeding without CUDA."
            }
        } else {
            Echo-And-Log "INFO" "CUDA is already installed."
            $hasCuda = $true
        }
    } else {
        Echo-And-Log "INFO" "No NVIDIA GPU detected. Proceeding without CUDA."
    }

    $downloadUrl = Get-DownloadUrl -hasCuda $hasCuda
    if (-not $downloadUrl) {
        Echo-And-Log "ERROR" "Failed to determine appropriate download URL."
        exit 1
    }

    Echo-And-Log "INFO" "Download URL: $downloadUrl"

    $filename = Split-Path -Leaf $downloadUrl
    Echo-And-Log "INFO" "Downloading $filename..."

    if (-not (Download-WithRetry $downloadUrl "$env:TEMP\$filename")) {
        Echo-And-Log "ERROR" "Download failed. Please check your internet connection and try again."
        exit 1
    }

    Echo-And-Log "INFO" "Download complete: $filename"

    if (-not (Install-Binary "$env:TEMP\$filename")) {
        Echo-And-Log "ERROR" "Installation failed."
        exit 1
    }

    Echo-And-Log "INFO" "Installation completed successfully."
}

# Run the main function
Main
