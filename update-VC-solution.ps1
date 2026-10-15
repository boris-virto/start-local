param (
    [string]$solutionFolder = "VirtoLocal",
    [ValidateSet("latest-stable", "edge", "custom")]
    [string]$vcSolutionVersion = "latest-stable",
    [string]$customPackagesJson,
    [string]$customFrontendUrl,
    [bool]$skipFrontend = $false,
    [bool]$skipBackup = $false,
    [bool]$allowDowngrade = $false,
    [string]$backupFolder
)

# Updates an installed solution to a new backend (platform + modules) and frontend build while
# KEEPING its data: the database, cms-content, uploaded assets, the search index and Redis stay.
# Only the platform and frontend containers are replaced. Before the swap it backs up the
# database, cms-content and assets, and writes rollback instructions next to the backup.
# For a clean reinstall use remove-VC-solution.ps1 + build-VC-solution.ps1 instead.

$databaseName = "VirtoCommerce3"
$platformService = "vc-platform-web"
$frontendService = "vc-frontend"
$dbService = "vc-db"
$platformRoot = "/opt/virtocommerce/platform"
$modulesPath = "$platformRoot/modules"
$assetsPath = "$platformRoot/wwwroot/assets"
$cmsContentPath = "$platformRoot/wwwroot/cms-content"
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
# an Invoke-WebRequest progress bar can stall the download on Linux pwsh (VCST-5302)
$ProgressPreference = 'SilentlyContinue'

function Exit-WithError([string]$message) {
    Write-Host "Error: $message" -ForegroundColor Red
    exit 1
}

# resolve the solution folder and its configuration
try {
    $solutionFolder = (Resolve-Path -Path $solutionFolder -ErrorAction Stop).Path
}
catch {
    Exit-WithError "Solution folder not found: $solutionFolder"
}
$dockerComposePath = Join-Path $solutionFolder "docker-compose.yml"
$envFile = Join-Path $solutionFolder ".env"
$scriptsDir = Join-Path $solutionFolder "scripts"
$backendDir = Join-Path $solutionFolder "backend"
$frontendDir = Join-Path $solutionFolder "frontend"
foreach ($requiredPath in @($dockerComposePath, $envFile)) {
    if (-not (Test-Path -Path $requiredPath)) {
        Exit-WithError "Required file not found: $requiredPath"
    }
}

. "$scriptsDir/docker-compose-helper.ps1"

$envValues = @{}
foreach ($envLine in Get-Content $envFile) {
    if ($envLine -match '^\s*([^#=\s][^=]*)=(.*)$') {
        $envValues[$matches[1].Trim()] = $matches[2].Trim()
    }
}
$dbProvider = "$($envValues['DB_PROVIDER'])".ToLower()
if ($dbProvider -notin @("postgres", "mysql", "sqlserver")) {
    Exit-WithError "Invalid or missing DB_PROVIDER '$dbProvider' in $envFile"
}
$dbOverridePath = Join-Path $solutionFolder "docker-compose.$dbProvider.yml"
if (-not (Test-Path -Path $dbOverridePath)) {
    Exit-WithError "Docker compose override file not found: $dbOverridePath"
}
# same defaults as the docker-compose files
$dbPassword = if ($envValues['DB_PASSWORD']) { $envValues['DB_PASSWORD'] } else { 'v!rto_Labs!' }
$platformPort = if ($envValues['PLATFORM_PORT']) { $envValues['PLATFORM_PORT'] } else { "8090" }
$platformApiUrl = "http://localhost:$platformPort"

$composeArgs = @("-f", $dockerComposePath, "-f", $dbOverridePath)
function Invoke-SolutionCompose {
    Invoke-DockerCompose @composeArgs @args
}

function Get-ServiceContainerId([string]$service) {
    $containerId = Invoke-SolutionCompose ps -a -q $service 2>$null | Select-Object -First 1
    return "$containerId".Trim()
}

function Test-ContainerRunning([string]$containerId) {
    return (docker inspect -f '{{.State.Running}}' $containerId 2>$null) -eq "true"
}

function Get-ContainerMount([string]$containerId, [string]$destination) {
    $mounts = docker inspect -f '{{json .Mounts}}' $containerId | ConvertFrom-Json
    return $mounts | Where-Object { $_.Destination -eq $destination } | Select-Object -First 1
}

function Get-PlatformVersion([string]$dllPath) {
    $fileVersion = [version]([System.Diagnostics.FileVersionInfo]::GetVersionInfo($dllPath).FileVersion)
    return "$($fileVersion.Major).$($fileVersion.Minor).$($fileVersion.Build)"
}

# -1 / 0 / 1. A prerelease sorts below the release with the same number; two prerelease tags
# of the same number cannot be ordered and compare as equal.
function Compare-VcVersion([string]$left, [string]$right) {
    $leftParts = $left -split '-', 2
    $rightParts = $right -split '-', 2
    $numeric = ([version]$leftParts[0]).CompareTo([version]$rightParts[0])
    if ($numeric -ne 0) {
        return [Math]::Sign($numeric)
    }
    if ($leftParts.Count -eq $rightParts.Count) {
        return 0
    }
    if ($leftParts.Count -eq 1) {
        return 1
    }
    return -1
}

function ConvertFrom-ManifestText([string[]]$manifestTexts) {
    $modules = @{}
    foreach ($manifestText in $manifestTexts) {
        $manifestText = "$manifestText".Trim().TrimStart([char]0xFEFF)
        if ([string]::IsNullOrWhiteSpace($manifestText)) {
            continue
        }
        $manifest = [xml]$manifestText
        $version = "$($manifest.module.version)".Trim()
        $versionTag = "$($manifest.module.'version-tag')".Trim()
        if ($versionTag) {
            $version = "$version-$versionTag"
        }
        $modules["$($manifest.module.id)".Trim()] = $version
    }
    return $modules
}

function Get-ContainerModules([string]$containerId) {
    $listScript = 'for f in {0}/*/module.manifest; do cat "$f"; echo "<!--manifest-end-->"; done' -f $modulesPath
    $rawOutput = (docker exec $containerId sh -c $listScript) -join "`n"
    if ($LASTEXITCODE -ne 0) {
        Exit-WithError "Could not read the module manifests from container $containerId"
    }
    return ConvertFrom-ManifestText ($rawOutput -split '<!--manifest-end-->')
}

function Get-FolderModules([string]$modulesDir) {
    $manifestTexts = Get-ChildItem -Path $modulesDir -Directory |
        ForEach-Object { Join-Path $_.FullName "module.manifest" } |
        Where-Object { Test-Path -Path $_ } |
        ForEach-Object { Get-Content -Raw -Path $_ }
    return ConvertFrom-ManifestText $manifestTexts
}

function Get-SqlCmdPath([string]$dbContainerId) {
    foreach ($candidate in @("/opt/mssql-tools18/bin/sqlcmd", "/opt/mssql-tools/bin/sqlcmd")) {
        docker exec $dbContainerId test -x $candidate 2>$null
        if ($LASTEXITCODE -eq 0) {
            return $candidate
        }
    }
    return $null
}

function Invoke-ContainerSqlCmd([string]$dbContainerId, [string]$sqlcmdPath, [string]$query) {
    $sqlcmdArgs = @("-S", "localhost", "-U", "sa", "-b", "-Q", $query)
    if ($sqlcmdPath -like "*mssql-tools18*") {
        # sqlcmd 18 encrypts by default and the container uses a self-signed certificate
        $sqlcmdArgs = @("-C") + $sqlcmdArgs
    }
    docker exec -e "SQLCMDPASSWORD=$dbPassword" $dbContainerId $sqlcmdPath @sqlcmdArgs | Out-Host
    return $LASTEXITCODE
}

# Writes a backup of the database into $targetDir and returns the file path.
function Backup-Database([string]$dbContainerId, [string]$targetDir) {
    switch ($dbProvider) {
        "sqlserver" {
            $sqlcmdPath = Get-SqlCmdPath $dbContainerId
            if (-not $sqlcmdPath) {
                Exit-AndRestartPlatform "sqlcmd was not found in the database container, so the database cannot be backed up."
            }
            $fileName = "$databaseName-$timestamp.bak"
            $containerFile = "/var/opt/mssql/backup/$fileName"
            docker exec $dbContainerId mkdir -p /var/opt/mssql/backup | Out-Host
            $backupQuery = "BACKUP DATABASE [$databaseName] TO DISK = N'$containerFile' WITH COPY_ONLY, INIT, CHECKSUM"
            # backup compression is not available on SQL Server Express
            if ((Invoke-ContainerSqlCmd $dbContainerId $sqlcmdPath "$backupQuery, COMPRESSION") -ne 0) {
                if ((Invoke-ContainerSqlCmd $dbContainerId $sqlcmdPath $backupQuery) -ne 0) {
                    Exit-AndRestartPlatform "The database backup failed."
                }
            }
            if ((Invoke-ContainerSqlCmd $dbContainerId $sqlcmdPath "RESTORE VERIFYONLY FROM DISK = N'$containerFile' WITH CHECKSUM") -ne 0) {
                Exit-AndRestartPlatform "The database backup did not pass RESTORE VERIFYONLY."
            }
        }
        "postgres" {
            $fileName = "$databaseName-$timestamp.dump"
            $containerFile = "/tmp/$fileName"
            docker exec -e "PGPASSWORD=$dbPassword" $dbContainerId pg_dump -U postgres -d $databaseName -Fc -f $containerFile | Out-Host
        }
        "mysql" {
            $fileName = "$databaseName-$timestamp.sql"
            $containerFile = "/tmp/$fileName"
            docker exec -e "MYSQL_PWD=$dbPassword" $dbContainerId sh -c "mysqldump -uroot --single-transaction --routines --triggers --databases $databaseName > $containerFile" | Out-Host
        }
    }
    if ($LASTEXITCODE -ne 0) {
        Exit-AndRestartPlatform "The database backup failed."
    }
    docker cp "${dbContainerId}:$containerFile" $targetDir | Out-Host
    if ($LASTEXITCODE -ne 0) {
        Exit-AndRestartPlatform "Could not copy the database backup out of the container."
    }
    docker exec $dbContainerId rm -f $containerFile | Out-Host
    return (Join-Path $targetDir $fileName)
}

function Get-RestoreDatabaseCommands([string]$dbContainerId, [string]$databaseBackupFile) {
    $fileName = Split-Path -Leaf $databaseBackupFile
    switch ($dbProvider) {
        "sqlserver" {
            $sqlcmdPath = Get-SqlCmdPath $dbContainerId
            $trustFlag = if ($sqlcmdPath -like "*mssql-tools18*") { "-C " } else { "" }
            # docker cp creates the file as root, and SQL Server runs as the mssql user
            return @(
                "docker cp `"$databaseBackupFile`" ${dbContainerId}:/var/opt/mssql/backup/$fileName",
                "docker exec -u 0 $dbContainerId chmod 644 /var/opt/mssql/backup/$fileName",
                "docker exec -e SQLCMDPASSWORD=<DB_PASSWORD> $dbContainerId $sqlcmdPath $trustFlag-S localhost -U sa -b -Q `"RESTORE DATABASE [$databaseName] FROM DISK = N'/var/opt/mssql/backup/$fileName' WITH REPLACE`""
            )
        }
        "postgres" {
            return @(
                "docker cp `"$databaseBackupFile`" ${dbContainerId}:/tmp/$fileName",
                "docker exec -e PGPASSWORD=<DB_PASSWORD> $dbContainerId dropdb -U postgres --if-exists --force $databaseName",
                "docker exec -e PGPASSWORD=<DB_PASSWORD> $dbContainerId createdb -U postgres $databaseName",
                "docker exec -e PGPASSWORD=<DB_PASSWORD> $dbContainerId pg_restore -U postgres -d $databaseName /tmp/$fileName"
            )
        }
        "mysql" {
            return @(
                "docker cp `"$databaseBackupFile`" ${dbContainerId}:/tmp/$fileName",
                "docker exec -e MYSQL_PWD=<DB_PASSWORD> $dbContainerId sh -c `"mysql -uroot -e 'DROP DATABASE IF EXISTS $databaseName' && mysql -uroot < /tmp/$fileName`""
            )
        }
    }
}

# Used between stopping the old platform and swapping it: puts everything back as it was.
function Exit-AndRestartPlatform([string]$message) {
    Write-Host "Error: $message" -ForegroundColor Red
    Write-Host "Restoring the previous images and starting the previous platform container..." -ForegroundColor Yellow
    docker tag $previousPlatformImage "vc-platform:local-latest" | Out-Host
    if ($previousFrontendImage) {
        docker tag $previousFrontendImage "vc-frontend:local-latest" | Out-Host
    }
    Invoke-SolutionCompose start $platformService | Out-Host
    Write-Host "Nothing was changed; the previous platform is running again." -ForegroundColor Yellow
    exit 1
}

# The platform only starts answering HTTP after every module (and its migrations) is initialized.
function Wait-PlatformResponse([string]$containerId, [int]$timeoutMinutes = 20) {
    $deadline = (Get-Date).AddMinutes($timeoutMinutes)
    $lastLogAt = Get-Date
    while ((Get-Date) -lt $deadline) {
        try {
            $response = Invoke-WebRequest -Uri "$platformApiUrl/health" -TimeoutSec 30 -SkipHttpErrorCheck
            if ($response.StatusCode -in @(200, 503)) {
                return $response
            }
        }
        catch {
            # not listening yet
        }
        if (((Get-Date) - $lastLogAt).TotalSeconds -ge 60) {
            Write-Host "... platform is still starting (migrations can take a few minutes). Last log lines:" -ForegroundColor Yellow
            docker logs --tail 5 $containerId 2>&1 | Out-Host
            $lastLogAt = Get-Date
        }
        Start-Sleep -Seconds 10
    }
    return $null
}

#
# 1. Read what is installed now
#
Write-Host "Reading the installed solution..." -ForegroundColor Yellow
$platformId = Get-ServiceContainerId $platformService
$dbId = Get-ServiceContainerId $dbService
if (-not $platformId -or -not (Test-ContainerRunning $platformId)) {
    Exit-WithError "The platform container is not running. Start the solution with start-VC-solution.ps1 first: the update reads the installed versions from it."
}
if (-not $dbId -or -not (Test-ContainerRunning $dbId)) {
    Exit-WithError "The database container is not running. Start the solution with start-VC-solution.ps1 first."
}
$frontendId = Get-ServiceContainerId $frontendService

$workDir = Join-Path ([System.IO.Path]::GetTempPath()) "vc-update-$timestamp"
New-Item -ItemType Directory -Path $workDir | Out-Null
docker cp "${platformId}:$platformRoot/VirtoCommerce.Platform.Web.dll" $workDir | Out-Null
if ($LASTEXITCODE -ne 0) {
    Exit-WithError "Could not read the platform version from container $platformId"
}
$currentPlatformVersion = Get-PlatformVersion (Join-Path $workDir "VirtoCommerce.Platform.Web.dll")
$currentModules = Get-ContainerModules $platformId
$modulesMount = Get-ContainerMount $platformId $modulesPath
$assetsMount = Get-ContainerMount $platformId $assetsPath
$assetsExist = (docker exec $platformId sh -c "test -d $assetsPath && echo yes") -eq "yes"
$previousCustomPackages = Join-Path $backendDir "custom-packages.json"
if (Test-Path -Path $previousCustomPackages) {
    Copy-Item -Path $previousCustomPackages -Destination (Join-Path $workDir "previous-custom-packages.json")
}
Write-Host "... installed: platform $currentPlatformVersion, $($currentModules.Count) modules, database provider $dbProvider" -ForegroundColor Green

#
# 2. Resolve the target backend manifest and frontend
#
$packagesJsonPath = $null
$frontendZipUrl = $null
if ($vcSolutionVersion -eq "latest-stable") {
    $packagesJsonPath = Join-Path $backendDir "stable-packages.json"
    Invoke-WebRequest -Uri "https://raw.githubusercontent.com/VirtoCommerce/vc-modules/refs/heads/master/bundles/latest/package.json" -OutFile $packagesJsonPath -TimeoutSec 120
    $frontendZipUrl = (Get-Content -Raw -Path $packagesJsonPath | ConvertFrom-Json).ThemeB2BVue
}
elseif ($vcSolutionVersion -eq "edge") {
    $releaseInfo = Invoke-RestMethod -Uri "https://api.github.com/repos/VirtoCommerce/vc-frontend/releases/latest" -TimeoutSec 120
    $frontendZipUrl = $releaseInfo.assets.browser_download_url | Where-Object { $_ -like "*.zip" } | Select-Object -First 1
}
else {
    if ([string]::IsNullOrWhiteSpace($customPackagesJson)) {
        Exit-WithError "-customPackagesJson is required when -vcSolutionVersion is 'custom'."
    }
    $packagesJsonPath = Join-Path $backendDir "custom-packages.json"
    if ($customPackagesJson -match '^https?://') {
        Invoke-WebRequest -Uri $customPackagesJson -OutFile $packagesJsonPath -TimeoutSec 120
    }
    else {
        try {
            $resolvedSource = (Resolve-Path -Path $customPackagesJson -ErrorAction Stop).Path
        }
        catch {
            Exit-WithError "Custom package manifest not found at '$customPackagesJson'."
        }
        Copy-Item -Path $resolvedSource -Destination $packagesJsonPath -Force
    }
    # unlike a fresh build, an update does not fall back to the latest vc-frontend release:
    # without -customFrontendUrl the installed frontend is kept
    $frontendZipUrl = $customFrontendUrl
}
if ($skipFrontend) {
    $frontendZipUrl = $null
}

if ($packagesJsonPath) {
    try {
        $targetPlatformVersion = (Get-Content -Raw -Path $packagesJsonPath | ConvertFrom-Json -ErrorAction Stop).PlatformVersion
    }
    catch {
        Exit-WithError "Package manifest at '$packagesJsonPath' is not valid JSON: $($_.Exception.Message)"
    }
    if (-not $targetPlatformVersion) {
        Exit-WithError "Package manifest at '$packagesJsonPath' is missing the required field 'PlatformVersion'."
    }
    # fail before the long build: the database is already migrated for the installed version
    if ((Compare-VcVersion $targetPlatformVersion $currentPlatformVersion) -lt 0 -and -not $allowDowngrade) {
        Exit-WithError "Target platform $targetPlatformVersion is older than the installed $currentPlatformVersion. The database has already been migrated forward, so a downgrade needs a database restore. Pass -allowDowngrade `$true only if you know it is safe."
    }
}

#
# 3. Build the new images; the running solution is not touched yet
#
$previousPlatformImage = "vc-platform:pre-update-$timestamp"
docker tag (docker inspect -f '{{.Image}}' $platformId) $previousPlatformImage | Out-Host
$previousFrontendImage = $null
if ($frontendId) {
    $previousFrontendImage = "vc-frontend:pre-update-$timestamp"
    docker tag (docker inspect -f '{{.Image}}' $frontendId) $previousFrontendImage | Out-Host
}
Write-Host "... previous images tagged $previousPlatformImage $(if ($previousFrontendImage) { "and $previousFrontendImage" })" -ForegroundColor Green

Write-Host "Building backend..." -ForegroundColor Yellow
$publishDir = Join-Path $backendDir "publish"
if (Test-Path -Path $publishDir) {
    Remove-Item -Recurse -Force $publishDir
}
$vcBuildArgs = @("install")
if ($vcSolutionVersion -eq "edge") {
    $vcBuildArgs += "-Edge"
}
else {
    $vcBuildArgs += @("--package-manifest-path", $packagesJsonPath)
}
$vcBuildArgs += @(
    "--probing-path", "$publishDir/app_data/modules",
    "--discovery-path", "$publishDir/modules",
    "--root", $publishDir,
    "--skip-dependency-solving",
    "--target-architecture", "X64"
)
vc-build @vcBuildArgs
if ($LASTEXITCODE -ne 0) {
    Exit-WithError "vc-build install failed with exit code $LASTEXITCODE. The running solution was not changed."
}

$newPlatformVersion = Get-PlatformVersion (Join-Path $publishDir "VirtoCommerce.Platform.Web.dll")
$newModules = Get-FolderModules (Join-Path $publishDir "modules")
$downgrades = @()
$changes = @()
foreach ($moduleId in ($currentModules.Keys | Sort-Object)) {
    if (-not $newModules.ContainsKey($moduleId)) {
        $changes += "  - $moduleId $($currentModules[$moduleId]) (removed; its tables stay in the database)"
        continue
    }
    $comparison = Compare-VcVersion $newModules[$moduleId] $currentModules[$moduleId]
    if ($comparison -lt 0) {
        $downgrades += "  ! $moduleId $($currentModules[$moduleId]) -> $($newModules[$moduleId])"
    }
    elseif ($newModules[$moduleId] -ne $currentModules[$moduleId]) {
        $changes += "  ~ $moduleId $($currentModules[$moduleId]) -> $($newModules[$moduleId])"
    }
}
foreach ($moduleId in ($newModules.Keys | Sort-Object)) {
    if (-not $currentModules.ContainsKey($moduleId)) {
        $changes += "  + $moduleId $($newModules[$moduleId])"
    }
}
Write-Host "Platform: $currentPlatformVersion -> $newPlatformVersion" -ForegroundColor Cyan
Write-Host "Module changes ($($changes.Count + $downgrades.Count)):" -ForegroundColor Cyan
$changes | ForEach-Object { Write-Host $_ }
if ((Compare-VcVersion $newPlatformVersion $currentPlatformVersion) -lt 0) {
    $downgrades += "  ! Platform $currentPlatformVersion -> $newPlatformVersion"
}
if ($downgrades.Count -gt 0) {
    Write-Host "Downgrades:" -ForegroundColor Red
    $downgrades | ForEach-Object { Write-Host $_ -ForegroundColor Red }
    if (-not $allowDowngrade) {
        Remove-Item -Recurse -Force $publishDir
        Exit-WithError "The build would downgrade the items above, but database migrations only go forward. Pass -allowDowngrade `$true only if you know it is safe. The running solution was not changed."
    }
}

Write-Host "Building backend Docker image..." -ForegroundColor Yellow
docker build --no-cache -t "vc-platform:local-latest" -f "$backendDir/Dockerfile" $backendDir
if ($LASTEXITCODE -ne 0) {
    docker tag $previousPlatformImage "vc-platform:local-latest" | Out-Host
    Exit-WithError "Failed to build the backend Docker image. The running solution was not changed."
}
Remove-Item -Recurse -Force $publishDir
Write-Host "... Backend Docker image built" -ForegroundColor Green

if ($frontendZipUrl) {
    Write-Host "Building frontend Docker image from $frontendZipUrl..." -ForegroundColor Yellow
    $artifactDir = Join-Path $frontendDir "artifact"
    $frontendZip = Join-Path $frontendDir "frontend.zip"
    if (Test-Path -Path $artifactDir) {
        Remove-Item -Recurse -Force $artifactDir
    }
    Invoke-WebRequest -Uri $frontendZipUrl -OutFile $frontendZip -TimeoutSec 300
    Expand-Archive -Path $frontendZip -DestinationPath $artifactDir
    Remove-Item -Path $frontendZip -Force
    docker build -t "vc-frontend:local-latest" -f "$frontendDir/Dockerfile" $frontendDir
    $frontendBuildExitCode = $LASTEXITCODE
    Remove-Item -Recurse -Force $artifactDir
    if ($frontendBuildExitCode -ne 0) {
        docker tag $previousPlatformImage "vc-platform:local-latest" | Out-Host
        if ($previousFrontendImage) {
            docker tag $previousFrontendImage "vc-frontend:local-latest" | Out-Host
        }
        Exit-WithError "Failed to build the frontend Docker image. The running solution was not changed."
    }
    Write-Host "... Frontend Docker image built" -ForegroundColor Green
}
else {
    Write-Host "Frontend is kept as installed." -ForegroundColor Yellow
}

#
# 4. Stop the platform and back up (database, search and Redis keep running)
#
Write-Host "Stopping the platform..." -ForegroundColor Yellow
Invoke-SolutionCompose stop $platformService | Out-Host

if (-not $backupFolder) {
    $backupFolder = Join-Path $solutionFolder "backups/update-$timestamp"
}
New-Item -ItemType Directory -Force -Path $backupFolder | Out-Null
$backupFolder = (Resolve-Path -Path $backupFolder).Path
$assetsBackupDir = Join-Path $backupFolder "assets"

$databaseBackupFile = $null
if ($skipBackup) {
    Write-Host "Skipping the database and cms-content backup (-skipBackup)" -ForegroundColor Yellow
}
else {
    Write-Host "Backing up the database to $backupFolder..." -ForegroundColor Yellow
    $databaseBackupFile = Backup-Database $dbId $backupFolder
    Write-Host "Backing up cms-content..." -ForegroundColor Yellow
    docker cp "${platformId}:$cmsContentPath" (Join-Path $backupFolder "cms-content") | Out-Host
    if ($LASTEXITCODE -ne 0) {
        Exit-AndRestartPlatform "Could not back up cms-content."
    }
}
# Assets that live in the container's own filesystem (no volume) would be lost with the
# container, so they are copied out even with -skipBackup.
if ($assetsExist -and (-not $assetsMount -or -not $skipBackup)) {
    Write-Host "Copying uploaded assets out of the platform container..." -ForegroundColor Yellow
    docker cp "${platformId}:$assetsPath" $assetsBackupDir | Out-Host
    if ($LASTEXITCODE -ne 0) {
        Exit-AndRestartPlatform "Could not copy the uploaded assets out of the platform container."
    }
}
$previousCustomPackagesCopy = Join-Path $workDir "previous-custom-packages.json"
if (Test-Path -Path $previousCustomPackagesCopy) {
    Copy-Item -Path $previousCustomPackagesCopy -Destination $backupFolder
}

$restoreCommands = @()
if ($databaseBackupFile) {
    $restoreCommands = Get-RestoreDatabaseCommands $dbId $databaseBackupFile
}
$composeCommand = "docker compose -f `"$dockerComposePath`" -f `"$dbOverridePath`""
$rollbackLines = @(
    "Rolling back the update of $timestamp (platform $currentPlatformVersion -> $newPlatformVersion).",
    "Database migrations only go forward: the previous images need the database backup restored.",
    "<DB_PASSWORD> is in $envFile.",
    "",
    "1. Put the previous images back:",
    "   docker tag $previousPlatformImage vc-platform:local-latest"
)
if ($previousFrontendImage) {
    $rollbackLines += "   docker tag $previousFrontendImage vc-frontend:local-latest"
}
$rollbackLines += @(
    "2. Remove the platform container and its modules volume (it is re-filled from the image):",
    "   $composeCommand rm -f -s $platformService"
)
if ($modulesMount -and $modulesMount.Type -eq "volume") {
    $rollbackLines += "   docker volume rm $($modulesMount.Name)"
}
$rollbackLines += "3. Restore the database:"
if ($restoreCommands.Count -gt 0) {
    $rollbackLines += $restoreCommands | ForEach-Object { "   $_" }
}
else {
    $rollbackLines += "   (no database backup was taken: the update ran with -skipBackup)"
}
$rollbackLines += @(
    "4. Recreate the platform, put the uploaded assets back, restart the frontend:",
    "   $composeCommand up --no-start --no-deps $platformService"
)
if (Test-Path -Path $assetsBackupDir) {
    $rollbackLines += "   docker cp `"$assetsBackupDir/.`" <new platform container id>:$assetsPath"
}
$rollbackLines += @(
    "   $composeCommand up -d --no-deps $platformService",
    "   $composeCommand up -d --no-deps --force-recreate $frontendService",
    "5. If search results look stale, rebuild the search indexes in the admin UI."
)
Set-Content -Path (Join-Path $backupFolder "ROLLBACK.txt") -Value ($rollbackLines -join [Environment]::NewLine)
[ordered]@{
    timestamp              = $timestamp
    dbProvider             = $dbProvider
    databaseBackup         = if ($databaseBackupFile) { Split-Path -Leaf $databaseBackupFile } else { $null }
    previousPlatformVersion = $currentPlatformVersion
    newPlatformVersion     = $newPlatformVersion
    previousPlatformImage  = $previousPlatformImage
    previousFrontendImage  = $previousFrontendImage
    assetsWereOnVolume     = [bool]$assetsMount
    previousModules        = $currentModules
    newModules             = $newModules
} | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $backupFolder "update-info.json")
Write-Host "... backup and rollback instructions written to $backupFolder" -ForegroundColor Green

#
# 5. Replace the platform container
#
Write-Host "Replacing the platform container..." -ForegroundColor Yellow
Invoke-SolutionCompose rm -f -s $platformService | Out-Host
if ($modulesMount -and $modulesMount.Type -eq "volume") {
    # Docker fills a named volume from the image only while it is empty: the old modules volume
    # would hide the new image's modules
    docker volume rm $modulesMount.Name | Out-Host
    if ($LASTEXITCODE -ne 0) {
        Exit-WithError "Could not remove the modules volume $($modulesMount.Name). Rollback instructions: $backupFolder/ROLLBACK.txt"
    }
}
Invoke-SolutionCompose up --no-start --no-deps $platformService | Out-Host
$newPlatformId = Get-ServiceContainerId $platformService
if (-not $newPlatformId) {
    Exit-WithError "Could not create the new platform container. Rollback instructions: $backupFolder/ROLLBACK.txt"
}
$expectedAssetFiles = 0
if ($assetsExist -and -not $assetsMount) {
    Write-Host "Moving uploaded assets into the new platform container..." -ForegroundColor Yellow
    docker cp "$assetsBackupDir/." "${newPlatformId}:$assetsPath" | Out-Host
    if ($LASTEXITCODE -ne 0) {
        Exit-WithError "Could not copy the uploaded assets into the new container. They are in $assetsBackupDir"
    }
    $expectedAssetFiles = @(Get-ChildItem -Path $assetsBackupDir -Recurse -File).Count
}
Invoke-SolutionCompose up -d --no-deps $platformService | Out-Host
# the frontend's nginx resolves the platform's address once at start: restart it in any case
Invoke-SolutionCompose up -d --no-deps --force-recreate $frontendService | Out-Host

#
# 6. Verify
#
Write-Host "Waiting for the platform to start..." -ForegroundColor Yellow
$healthResponse = Wait-PlatformResponse $newPlatformId
if (-not $healthResponse) {
    docker logs --tail 60 $newPlatformId 2>&1 | Out-Host
    Exit-WithError "The platform did not answer within 20 minutes. Rollback instructions: $backupFolder/ROLLBACK.txt"
}
$health = $healthResponse.Content | ConvertFrom-Json -AsHashtable
$unhealthy = @($health.GetEnumerator() | Where-Object { $_.Value.Status -ne "Healthy" })
foreach ($check in $unhealthy) {
    Write-Host "  $($check.Key): $($check.Value.Status) - $($check.Value.Description)" -ForegroundColor Red
}
if ($expectedAssetFiles -gt 0) {
    $actualAssetFiles = [int](docker exec $newPlatformId sh -c "find $assetsPath -type f | wc -l")
    if ($actualAssetFiles -lt $expectedAssetFiles) {
        Write-Host "  Uploaded assets: $actualAssetFiles of $expectedAssetFiles files in the new container; the full copy is in $assetsBackupDir" -ForegroundColor Red
    }
    else {
        Write-Host "  Uploaded assets: $actualAssetFiles files carried over" -ForegroundColor Green
    }
}
Remove-Item -Recurse -Force $workDir

if ($health.ContainsKey("Modules health") -and $health["Modules health"].Status -ne "Healthy") {
    Exit-WithError "Some modules did not load (see above). Rollback instructions: $backupFolder/ROLLBACK.txt"
}
Write-Host "... VC solution updated: platform $currentPlatformVersion -> $newPlatformVersion" -ForegroundColor Green
Write-Host "Backup and rollback instructions: $backupFolder" -ForegroundColor Green
Write-Host "If the release notes ask for it, rebuild the search indexes in the admin UI." -ForegroundColor Yellow
