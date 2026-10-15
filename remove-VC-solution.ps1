param (
    [string]$solutionFolder = "VirtoLocal"
)

$dockerComposePath = "$solutionFolder/docker-compose.yml"
if (-not (Test-Path -Path $dockerComposePath)) {
    Write-Host "Error: Docker compose file not found: $dockerComposePath" -ForegroundColor Red
    exit 1
}

. "$solutionFolder/scripts/docker-compose-helper.ps1"

# Merge ALL provider override files into a single 'down -v' call.
# The merged top-level volumes section will declare all DB volumes
# (postgres_data, mysql_data, mssql_data), so 'down -v' removes them
# all in one call regardless of which provider is currently active in .env.
$validProviders = @("postgres", "mysql", "sqlserver")
$composeArgs = @("-f", $dockerComposePath)
foreach ($provider in $validProviders) {
    $providerOverridePath = "$solutionFolder/docker-compose.$provider.yml"
    if (-not (Test-Path -Path $providerOverridePath)) {
        Write-Host "  - Override file not found, skipping: $providerOverridePath" -ForegroundColor DarkYellow
        continue
    }
    $composeArgs += "-f"
    $composeArgs += $providerOverridePath
}
$composeArgs += @("down", "-v", "--remove-orphans")

Write-Host "Stopping and removing VC solution from docker (all providers, all volumes)..." -ForegroundColor Yellow
Invoke-DockerCompose @composeArgs
if ($LASTEXITCODE -ne 0) {
    Write-Host "Warning: docker compose down returned exit code $LASTEXITCODE" -ForegroundColor Yellow
}

# Safety net: explicitly remove any project volume that might still exist.
# All compose volumes are explicitly named with a 'virto_' prefix in the compose files,
# so we can target them by exact name without relying on the compose project name.
$projectVolumes = @(
    "virto_postgres_data",
    "virto_mysql_data",
    "virto_mssql_data",
    "virto_cms-content-data",
    "virto_assets-data",
    "virto_modules-data",
    "virto_esdata01",
    "virto_redisdata"
)
foreach ($fullVolName in $projectVolumes) {
    docker volume inspect $fullVolName *> $null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  - Removing leftover volume: $fullVolName" -ForegroundColor Cyan
        docker volume rm $fullVolName *> $null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "    Warning: failed to remove volume $fullVolName" -ForegroundColor Yellow
        }
    }
}
Write-Host "... VC solution stopped and all project volumes removed" -ForegroundColor Green

Write-Host "Removing backend Docker image..." -ForegroundColor Yellow
docker rmi vc-platform:local-latest
if ($LASTEXITCODE -ne 0) {
    Write-Host "Error: Failed to remove backend Docker image" -ForegroundColor Red
    Write-Host "docker rmi command failed with exit code: $LASTEXITCODE" -ForegroundColor Red
    # exit 1
} else {
    Write-Host "... Backend Docker image removed" -ForegroundColor Green
}

Write-Host "Removing frontend Docker image..." -ForegroundColor Yellow
docker rmi vc-frontend:local-latest
if ($LASTEXITCODE -ne 0) {
    Write-Host "Error: Failed to remove frontend Docker image" -ForegroundColor Red
    Write-Host "docker rmi command failed with exit code: $LASTEXITCODE" -ForegroundColor Red
    # exit 1
} else {
    Write-Host "... Frontend Docker image removed" -ForegroundColor Green
}

Write-Host "Removing solution folder..." -ForegroundColor Yellow
try {
    Remove-Item -Recurse -Force $solutionFolder -ErrorAction Stop
    Write-Host "... Solution folder removed" -ForegroundColor Green
} catch {
    Write-Host "Error: Failed to remove solution folder '$solutionFolder'" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}

Write-Host "Done" -ForegroundColor Green
