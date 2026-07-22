# ============================================================================
# BizFirstAI - Push MinIO to Server
# ============================================================================
# PURPOSE:
#   Automates deployment of MinIO docker compose setup to the Linux server.
#   1. Validates the local docker-compose files exist
#   2. Tests SSH connectivity to the remote server
#   3. Creates a timestamped backup of the current MinIO setup on remote server
#   4. Uploads the new docker-compose files via SCP
#   5. Verifies the file count matches between local and remote
#   6. Starts/restarts docker containers via docker compose
#
# SUPPORTS: Windows (PuTTY plink/pscp), macOS/Linux (sshpass)
#
# USAGE:
#   .\push-minio.ps1                           # Uses defaults from CONFIGURATION section
#   .\push-minio.ps1 -FilesToDeploy "docker-compose.minio.yml", "other-file.conf"
#   .\push-minio.ps1 -RemoteUser "ubuntu" -RemoteHost "15.204.243.180"
#
# CONFIGURATION:
#   Edit the CONFIGURATION section below to set default files and remote server settings
#   Command-line parameters override configuration section settings
#
# PREREQUISITES:
#   - SSH access to remote server (with password in PasswordFile)
#   - Docker and docker-compose installed on remote server
#   - Adequate disk space on remote server
# ============================================================================

param(
    [string]$DeploymentPath = "",
    [string[]]$FilesToDeploy = @(),
    [string]$RemoteUser = "",
    [string]$RemoteHost = "",
    [string]$RemoteBasePath = "",
    [string]$PasswordFile = "",
    [switch]$SkipVerification,
    [switch]$SkipRestart
)

# ============================================================================
# Configuration - EDIT THESE SETTINGS
# ============================================================================
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# ============================================================================
# CONFIGURATION: Files to Deploy
# ============================================================================
# Specify which files from the deployment directory to push to the server
# These can be overridden via the -FilesToDeploy parameter
if ($FilesToDeploy.Count -eq 0) {
    $FilesToDeploy = @(
        "docker-compose.minio.yml",
        "ofelia.ini"
    )
}

# ============================================================================
# CONFIGURATION: Remote Server Settings
# ============================================================================
# These can be overridden via command-line parameters
if ([string]::IsNullOrEmpty($RemoteUser)) {
    $RemoteUser = "ubuntu"
}
if ([string]::IsNullOrEmpty($RemoteHost)) {
    $RemoteHost = "15.204.243.180"
}
if ([string]::IsNullOrEmpty($RemoteBasePath)) {
    $RemoteBasePath = "/opt/bizfirst/minio"
}

# Get script directory for resolving relative paths
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Detect operating system
$PlatformIsWindows = $PSVersionTable.Platform -eq "Win32NT" -or $PSVersionTable.PSVersion.Major -lt 6

# Initialize SSH variables
$plinkPath = $null
$pscpPath = $null
$sshpassCmd = $null
$Password = $null

# Read password file and setup SSH method based on platform
if ([string]::IsNullOrEmpty($PasswordFile)) {
    if ($PlatformIsWindows) {
        $PasswordFile = 'C:\BizFirstGO_FI_AI\Deployment\BizFirstStorageAi\src\_Deployment\Server-180.md'
    } else {
        $PasswordFile = "$HOME/Documents/Work/BizFirstAI/BizFirstStorageAi/src/_Deployment/Server-180.md"
    }
}

if (-not (Test-Path $PasswordFile)) {
    Write-Host "ERROR: Password file not found: $PasswordFile" -ForegroundColor Red
    exit 1
}

$Password = (Get-Content -Path $PasswordFile -Raw).Trim()
if ([string]::IsNullOrEmpty($Password)) {
    Write-Host "ERROR: Password file is empty: $PasswordFile" -ForegroundColor Red
    exit 1
}

if ($PlatformIsWindows) {
    # Windows: Use PuTTY
    if (Test-Path "C:\ProgramData\chocolatey\bin\plink.exe") {
        $plinkPath = "C:\ProgramData\chocolatey\bin\plink.exe"
    } elseif (Test-Path "C:\Program Files\PuTTY\plink.exe") {
        $plinkPath = "C:\Program Files\PuTTY\plink.exe"
    } elseif (Test-Path "C:\Program Files (x86)\PuTTY\plink.exe") {
        $plinkPath = "C:\Program Files (x86)\PuTTY\plink.exe"
    } else {
        $plinkCmd = Get-Command plink.exe -ErrorAction SilentlyContinue
        if ($plinkCmd) {
            $plinkPath = $plinkCmd.Source
        }
    }

    if (Test-Path "C:\ProgramData\chocolatey\bin\pscp.exe") {
        $pscpPath = "C:\ProgramData\chocolatey\bin\pscp.exe"
    } elseif (Test-Path "C:\Program Files\PuTTY\pscp.exe") {
        $pscpPath = "C:\Program Files\PuTTY\pscp.exe"
    } elseif (Test-Path "C:\Program Files (x86)\PuTTY\pscp.exe") {
        $pscpPath = "C:\Program Files (x86)\PuTTY\pscp.exe"
    } else {
        $pscpCmd = Get-Command pscp.exe -ErrorAction SilentlyContinue
        if ($pscpCmd) {
            $pscpPath = $pscpCmd.Source
        }
    }
} else {
    # macOS/Linux: Use sshpass
    $sshpassCmd = Get-Command sshpass -ErrorAction SilentlyContinue
    if (-not $sshpassCmd) {
        Write-Host "ERROR: sshpass is not installed or not in PATH" -ForegroundColor Red
        Write-Host "  macOS: brew install sshpass" -ForegroundColor Yellow
        Write-Host "  Linux: sudo apt-get install sshpass" -ForegroundColor Yellow
        exit 1
    }
}

# ============================================================================
# Helper Functions for Cross-Platform SSH
# ============================================================================

function Invoke-RemoteCommand {
    param([string]$Command)

    try {
        if ($PlatformIsWindows) {
            $output = & $plinkPath -l $RemoteUser -pw $Password -batch -C $RemoteHost $Command
        } else {
            $output = sshpass -p $Password ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "${RemoteUser}@${RemoteHost}" $Command
        }

        if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne $null) {
            throw "Remote command failed with exit code $LASTEXITCODE"
        }

        return $output
    } catch {
        throw $_
    }
}

function Copy-FileToRemote {
    param([string]$LocalPath, [string]$RemotePath)

    try {
        if ($PlatformIsWindows) {
            & $pscpPath -l $RemoteUser -pw $Password -batch -C -r "$LocalPath" "${RemoteUser}@${RemoteHost}:${RemotePath}" | Out-Null
        } else {
            sshpass -p $Password scp -o StrictHostKeyChecking=no -o ConnectTimeout=10 -r "$LocalPath" "${RemoteUser}@${RemoteHost}:${RemotePath}" | Out-Null
        }

        if ($LASTEXITCODE -ne 0) {
            throw "File copy failed with exit code $LASTEXITCODE"
        }
    } catch {
        throw $_
    }
}

function Remove-OldBackups {
    param(
        [string]$BackupDirectoryPath,
        [int]$MaxBackups = 3
    )

    try {
        $listCmd = "ls -1dt '$BackupDirectoryPath'/*/ 2>/dev/null | head -n +$($MaxBackups + 1) | tail -n +$($MaxBackups + 1)"
        $backupsToDelete = Invoke-RemoteCommand -Command $listCmd

        if ($backupsToDelete) {
            foreach ($backup in $backupsToDelete) {
                $backup = $backup.Trim()
                if (-not [string]::IsNullOrEmpty($backup)) {
                    Invoke-RemoteCommand -Command "rm -rf '$backup'" | Out-Null
                    Write-Host "    Cleaned up old backup: $(Split-Path -Leaf $backup)" -ForegroundColor Gray
                }
            }
        }
    } catch {
        Write-Host "    Warning: Could not clean old backups: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# ============================================================================
# Display Header
# ============================================================================
Write-Host "====================================================================" -ForegroundColor Cyan
Write-Host " BizFirstAI - Push MinIO to Server" -ForegroundColor Cyan
Write-Host "====================================================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "CONFIGURATION:" -ForegroundColor Yellow
Write-Host "  Target Server: $RemoteUser@$RemoteHost" -ForegroundColor Gray
Write-Host "  Remote Path: $RemoteBasePath" -ForegroundColor Gray
Write-Host ""

# ============================================================================
# Step 1: Validate Deployment Path
# ============================================================================
Write-Host "[1] Validating deployment path..." -ForegroundColor Yellow

if ([string]::IsNullOrEmpty($DeploymentPath)) {
    # Default to the current script directory (the _Deployment directory)
    $DeploymentPath = $ScriptDir

    if (-not (Test-Path $DeploymentPath -PathType Container)) {
        Write-Host "  [ERROR] Deployment folder not found" -ForegroundColor Red
        exit 1
    }
    Write-Host "  [OK] Using script directory as deployment path" -ForegroundColor Green
} else {
    $ResolvedPath = Resolve-Path -Path $DeploymentPath -ErrorAction SilentlyContinue
    if (-not $ResolvedPath -or -not (Test-Path $ResolvedPath -PathType Container)) {
        Write-Host "  [ERROR] Deployment path not found: $DeploymentPath" -ForegroundColor Red
        exit 1
    }
    $DeploymentPath = $ResolvedPath.Path
    Write-Host "  [OK] Using provided deployment path: $DeploymentPath" -ForegroundColor Green
}

# Validate required files
$deployFilePaths = @()
foreach ($fileName in $FilesToDeploy) {
    $filePath = Join-Path -Path $DeploymentPath -ChildPath $fileName
    if (-not (Test-Path $filePath -PathType Leaf)) {
        Write-Host "  [ERROR] $fileName not found in deployment directory: $DeploymentPath" -ForegroundColor Red
        exit 1
    }
    $deployFilePaths += $filePath
}

# Calculate size for only the deployment files
$FileCount = $deployFilePaths.Count
$FolderSize = 0
foreach ($file in $deployFilePaths) {
    $FolderSize += (Get-Item $file).Length
}
$FolderSizeMB = [math]::Round($FolderSize / 1MB, 2)

Write-Host "  [OK] Deployment files validated" -ForegroundColor Green
Write-Host "    Files: $FileCount ($($FilesToDeploy -join ', '))" -ForegroundColor Green
Write-Host "    Size: $FolderSizeMB MB" -ForegroundColor Green
Write-Host ""

# ============================================================================
# Step 2: Check SSH Connectivity
# ============================================================================
Write-Host "[2] Checking SSH connectivity..." -ForegroundColor Yellow

if ($PlatformIsWindows) {
    if (-not $plinkPath) {
        Write-Host "  [ERROR] plink.exe not found. Install PuTTY: choco install putty" -ForegroundColor Red
        exit 1
    }
    if (-not $pscpPath) {
        Write-Host "  [ERROR] pscp.exe not found. Install PuTTY: choco install putty" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "  [INFO] Using sshpass for password authentication" -ForegroundColor Cyan
}

try {
    Write-Host "    Attempting connection to $RemoteUser@$RemoteHost..." -ForegroundColor Gray
    $testCmd = "echo 'SSH connected'"
    $sshTest = Invoke-RemoteCommand -Command $testCmd

    if ($LASTEXITCODE -eq 0 -or $sshTest) {
        Write-Host "  [OK] SSH connection successful" -ForegroundColor Green
    } else {
        throw "SSH connection failed"
    }
} catch {
    Write-Host "  [ERROR] Cannot connect to $RemoteUser@$RemoteHost" -ForegroundColor Red
    Write-Host "    Error: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
Write-Host ""

# ============================================================================
# Step 3: Create Backup on Remote Server
# ============================================================================
Write-Host "[3] Creating backup on remote server..." -ForegroundColor Yellow

$BackupTimestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$BackupBaseDir = "/opt/bizfirst/backups/minio"
$BackupDir = "$BackupBaseDir/minio_${BackupTimestamp}"

try {
    Invoke-RemoteCommand -Command "mkdir -p '$BackupBaseDir'" | Out-Null
    Write-Host "  [OK] Backup directory ready" -ForegroundColor Green

    $minioExists = Invoke-RemoteCommand -Command "if [ -d '$RemoteBasePath' ]; then echo 'exists'; else echo 'missing'; fi"

    if ($minioExists -like "*exists*") {
        Invoke-RemoteCommand -Command "cp -r '$RemoteBasePath' '$BackupDir'" | Out-Null
        Write-Host "  [OK] Backed up existing MinIO setup to: $BackupDir" -ForegroundColor Green

        Write-Host "  [INFO] Cleaning up old backups (keeping 3 most recent)..." -ForegroundColor Cyan
        Remove-OldBackups -BackupDirectoryPath $BackupBaseDir
    } else {
        Write-Host "  [INFO] MinIO setup does not exist yet, skipping backup" -ForegroundColor Cyan
    }
} catch {
    Write-Host "  [ERROR] Backup failed" -ForegroundColor Red
    Write-Host "    Error: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
Write-Host ""

# ============================================================================
# Step 4: Remove Old Deployment Directory
# ============================================================================
Write-Host "[4] Removing old deployment directory..." -ForegroundColor Yellow

try {
    Invoke-RemoteCommand -Command "rm -rf '$RemoteBasePath'" | Out-Null
    Write-Host "  [OK] Old deployment directory removed: $RemoteBasePath" -ForegroundColor Green
} catch {
    Write-Host "  [ERROR] Failed to remove old directory" -ForegroundColor Red
    Write-Host "    Error: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
Write-Host ""

# ============================================================================
# Step 5: Upload Deployment Files
# ============================================================================
Write-Host "[5] Uploading deployment files..." -ForegroundColor Yellow
Write-Host "    From: $DeploymentPath" -ForegroundColor Gray
Write-Host "    To:   $RemoteBasePath" -ForegroundColor Gray
Write-Host "    Files: $FileCount" -ForegroundColor Gray
Write-Host "    Size: $FolderSizeMB MB" -ForegroundColor Gray
Write-Host ""

try {
    Invoke-RemoteCommand -Command "mkdir -p '$RemoteBasePath'" | Out-Null
    Write-Host "  [OK] Remote directory ready" -ForegroundColor Green

    $startTime = Get-Date

    # Copy each deployment file
    foreach ($filePath in $deployFilePaths) {
        $fileName = Split-Path -Leaf $filePath
        Copy-FileToRemote -LocalPath $filePath -RemotePath "$RemoteBasePath/$fileName"
    }

    $endTime = Get-Date
    $duration = $endTime - $startTime

    Write-Host "  [OK] Upload completed successfully" -ForegroundColor Green
    Write-Host "    Duration: $([math]::Round($duration.TotalSeconds, 2)) seconds" -ForegroundColor Green
    if ($duration.TotalSeconds -gt 0) {
        Write-Host "    Speed: $([math]::Round($FolderSizeMB / $duration.TotalSeconds, 2)) MB/s" -ForegroundColor Green
    }
} catch {
    Write-Host "  [ERROR] Upload failed" -ForegroundColor Red
    Write-Host "    Error: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
Write-Host ""

# ============================================================================
# Step 6: Verification
# ============================================================================
if (-not $SkipVerification) {
    Write-Host "[6] Verifying files on remote server..." -ForegroundColor Yellow
    try {
        # Check for each deployment file
        $allFilesOk = $true
        foreach ($fileName in $FilesToDeploy) {
            $fileExists = Invoke-RemoteCommand -Command "test -f '$RemoteBasePath/$fileName' && echo 'yes' || echo 'no'"
            $isPresent = $fileExists -like "*yes*"
            $statusIcon = if ($isPresent) { "✓" } else { "✗" }
            Write-Host "    $statusIcon $fileName" -ForegroundColor $(if ($isPresent) { "Green" } else { "Red" })
            $allFilesOk = $allFilesOk -and $isPresent
        }

        if ($allFilesOk) {
            Write-Host "  [OK] All deployment files present on remote server" -ForegroundColor Green
        } else {
            Write-Host "  [WARNING] Some files missing on remote server" -ForegroundColor Yellow
        }

        Write-Host ""
        Write-Host "  Remote directory contents:" -ForegroundColor Gray
        $dirStructure = Invoke-RemoteCommand -Command "ls -lh '$RemoteBasePath/'"
        foreach ($line in $dirStructure) {
            Write-Host "    $line" -ForegroundColor Gray
        }
    } catch {
        Write-Host "  [WARNING] Verification failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}
Write-Host ""

# ============================================================================
# Step 7: Start/Restart Docker Containers
# ============================================================================
if (-not $SkipRestart) {
    Write-Host "[7] Managing Docker containers..." -ForegroundColor Yellow
    try {
        # Check if containers are running
        $containerStatus = Invoke-RemoteCommand -Command "cd '$RemoteBasePath' && docker compose -f docker-compose.minio.yml ps 2>/dev/null | grep -c 'running' || echo '0'"
        $runningCount = $containerStatus -as [int]

        if ($runningCount -gt 0) {
            Write-Host "  [INFO] Found $runningCount running containers, restarting..." -ForegroundColor Cyan
            Invoke-RemoteCommand -Command "cd '$RemoteBasePath' && docker compose -f docker-compose.minio.yml restart" | Out-Null
            Write-Host "  [OK] Containers restarted successfully" -ForegroundColor Green
        } else {
            Write-Host "  [INFO] No running containers found, starting them..." -ForegroundColor Cyan
            Invoke-RemoteCommand -Command "cd '$RemoteBasePath' && docker compose -f docker-compose.minio.yml up -d" | Out-Null
            Write-Host "  [OK] Containers started successfully" -ForegroundColor Green
        }

        # Show container status
        Write-Host ""
        Write-Host "  Container status:" -ForegroundColor Gray
        $status = Invoke-RemoteCommand -Command "cd '$RemoteBasePath' && docker compose -f docker-compose.minio.yml ps"
        foreach ($line in $status) {
            Write-Host "    $line" -ForegroundColor Gray
        }
    } catch {
        Write-Host "  [ERROR] Failed to manage docker containers" -ForegroundColor Red
        Write-Host "    Error: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "    Run manually: ssh $RemoteUser@$RemoteHost" -ForegroundColor Yellow
        Write-Host "    Then: cd $RemoteBasePath && docker compose -f docker-compose.minio.yml up -d" -ForegroundColor Yellow
        exit 1
    }
}
Write-Host ""

# ============================================================================
# Summary
# ============================================================================
Write-Host "====================================================================" -ForegroundColor Cyan
Write-Host " MinIO deployed successfully!" -ForegroundColor Green
Write-Host "====================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Deployment Details:" -ForegroundColor Gray
Write-Host "  Local Source: $DeploymentPath" -ForegroundColor Gray
Write-Host "  Remote Location: $RemoteBasePath" -ForegroundColor Gray
Write-Host "  Backup Location: $BackupDir" -ForegroundColor Gray
Write-Host ""
Write-Host "Docker Compose Services:" -ForegroundColor Gray
Write-Host "  - bizfirst-primary (MinIO S3 - Port 9000/9001)" -ForegroundColor Gray
Write-Host "  - bizfirst-hotstandby (Hot Standby - Port 9010/9011)" -ForegroundColor Gray
Write-Host "  - bizfirst-archival (Archival - Port 9020/9021)" -ForegroundColor Gray
Write-Host "  - bizfirst-compliance (Compliance - Port 9030/9031)" -ForegroundColor Gray
Write-Host "  - bizfirst-pitr (Point-in-Time Restore - Port 9040/9041)" -ForegroundColor Gray
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. SSH to the server: ssh $RemoteUser@$RemoteHost" -ForegroundColor Gray
Write-Host "  2. Navigate to MinIO directory: cd $RemoteBasePath" -ForegroundColor Gray
Write-Host "  3. Check container status: docker compose -f docker-compose.minio.yml ps" -ForegroundColor Gray
Write-Host "  4. View logs: docker compose -f docker-compose.minio.yml logs -f" -ForegroundColor Gray
Write-Host "  5. Access MinIO Console:" -ForegroundColor Gray
Write-Host "     - Primary: http://$RemoteHost:9001" -ForegroundColor Gray
Write-Host "     - HotStandby: http://$RemoteHost:9011" -ForegroundColor Gray
Write-Host "     - Archival: http://$RemoteHost:9021" -ForegroundColor Gray
Write-Host "     - Compliance: http://$RemoteHost:9031" -ForegroundColor Gray
Write-Host "     - PITR: http://$RemoteHost:9041" -ForegroundColor Gray
Write-Host ""
Write-Host "If you need to restore from backup:" -ForegroundColor Yellow
Write-Host "  rm -rf $RemoteBasePath && cp -r $BackupDir $RemoteBasePath" -ForegroundColor Gray
Write-Host "  cd $RemoteBasePath && docker compose -f docker-compose.minio.yml up -d" -ForegroundColor Gray
Write-Host ""
