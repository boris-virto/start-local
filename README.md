# 🚀 Run Virto Commerce Locally with Docker

Set up a complete Virto Commerce environment on your local machine with a single PowerShell script. The solution includes:
- Virto Commerce Backend
- Virto Commerce Frontend
- Database (PostgreSQL, MySQL, or SQL Server)
- Redis
- Elasticsearch
- Kibana

> [!IMPORTANT]
> This setup is for local development and testing only. Not for production use!
>
> Elasticsearch and Kibana run with security features disabled (`xpack.security.enabled=false`, both HTTP and transport TLS off) to match the default `basic` self-generated license used in this local setup. There is no authentication on the search cluster — anyone with network access to the published ports can read or modify the indexes. **Do not expose these ports beyond your local machine.**
>
> For production deployments, enable security and consult the official documentation for [Elasticsearch](https://www.elastic.co/guide/en/elasticsearch/reference/current/secure-cluster.html) and [Kibana](https://www.elastic.co/guide/en/kibana/current/using-kibana-with-security.html).

## 💻 System Requirements
- ~5 GB available disk space
- [.NET SDK](https://dotnet.microsoft.com/download) (Required for `vc-build` installation)
- [vc-build tool](https://github.com/VirtoCommerce/vc-build) 3.1001.0 or later: the scripts pass `--target-architecture`, which earlier versions do not have (Install with: `dotnet tool install VirtoCommerce.GlobalTool -g`, update with: `dotnet tool update VirtoCommerce.GlobalTool -g`)
- [Docker](https://www.docker.com/) (On Linux/MacOS, configure Docker to run without sudo)
- Compatible with Windows (Requires PowerShell v.7)
- For Linux/MacOS: Requires PowerShell v.7 ([Linux install](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-linux), [macOS install](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-macos))

## 🏃‍♀️ Getting Started

### Initial Setup
Run this command to create a local `VirtoLocal` directory with all required files:

```pwsh
$installSCript = Invoke-WebRequest -Uri "https://raw.githubusercontent.com/VirtoCommerce/start-local/dev/VirtoLocal_create_local_files.ps1" -UseBasicParsing; Set-Content -Path ".\VirtoLocal_create_local_files.ps1" -Value $installSCript.Content; .\VirtoLocal_create_local_files.ps1
```

### Database Provider Selection

During initial setup, you'll be prompted to choose a database provider:

| Provider   | Default Version | Default Port |
|------------|-----------------|--------------|
| PostgreSQL | 18.3            | 5432         |
| MySQL      | 9.3             | 3306         |
| SQL Server | 2022-latest     | 1433         |

You can also pass the provider via parameter: `.\VirtoLocal_create_local_files.ps1 -dbProvider mysql`

#### Switching Database Providers

To switch providers after initial setup:
1. Edit `.env` and change `DB_PROVIDER` to `postgres`, `mysql`, or `sqlserver`
2. Run `stop-VC-solution.ps1` (if currently running)
3. Run `start-VC-solution.ps1`

Each provider stores its data in a separate Docker volume. Switching providers does **not** remove the previous provider's data. When you switch back, your data is still there. Only `remove-VC-solution.ps1` removes all volumes.

### Sample Data Installation

After the build completes and the solution starts, you'll be prompted to install sample data (catalogs, products, etc.). Installation is enabled by default — press Enter or `Y` to install, or `N` to skip.

You can also control sample data installation via parameter when running scripts directly:
- `.\build-VC-solution.ps1 -skipSampleData $true` — build and start without installing sample data (default: `$false`, sample data is installed)
- `.\start-VC-solution.ps1 -skipSampleData $false` — re-run the start step **and** install sample data. Direct `start-VC-solution.ps1` invocations default to **skipping** sample data, since `start` is most commonly used to restart an existing install that already has data.

### Created Files and Folders

The following files and folders will be created:
- `docker-compose.yml`: Docker Compose configuration for VirtoCommerce solution
- `backend` folder: Dockerfile and script(s) for the backend
- `frontend` folder: Dockerfile and config file(s) for the frontend
- `scripts` folder: Scripts in the build solution process
- `build-VC-solution.ps1`: Script to build docker images for backend and frontend
- `start-VC-solution.ps1`: Script to start a solution using built by `build-VC-solution.ps1` script
- `stop-VC-solution.ps1`: Script stops VC solution but does NOT remove the volumes associated with the docker containers
- `remove-VC-solution.ps1`: Script removes docker volumes associated with the containers, removes backend and frontend docker images from local docker storage
- `update-VC-solution.ps1`: Script updates an installed solution to a new backend and frontend build and keeps its data (database, cms-content, uploaded assets, search index), see [Updating to a new version](#-updating-to-a-new-version-keeps-your-data)

By default `build-VC-solution` script is executed automatically after the files are created and `start-VC-solution` script is executed automatically after the build is complete. However, the execution can be skipped.

You have three options for installing Virto Commerce: the latest stable release, the edge release, or a user-supplied custom package manifest. Learn more about our release strategy by [following this link](https://docs.virtocommerce.org/platform/developer-guide/Updating-Virto-Commerce-Based-Project/release-strategy-overview/).

### Endpoints
After running the script:
* **Virto Commerce Frontend** will be running at http://localhost:80
* **Virto Commerce Backed** will be running at http://localhost:8090

### Initial Configuration
1. Open the **Virto Commerce Backend** and sign in using the default credentials:
    * Username: **admin**
    * Password: **store**
1. You will be prompted to change the password upon first login.
1. Review or install the sample data set to populate the system with example products and catalogs.
1. Navigate to the Search Index section and ensure that all indexes are built successfully.
1. Open the Virto Commerce Frontend to view and explore the sample data.

Please take a look at [Virto Commerce Documentation](https://docs.virtocommerce.org/) for additional configuration and customisation guidance.

### Manual Installation
The manual installation steps are as follows:
1. First run `build-VC-solution.ps1` with these parameters:
- `vcSolutionVersion`:
    - `latest-stable`: Installs the latest stable backend bundle with compatible frontend
    - `edge`: Installs the newest backend and frontend releases
    - `custom`: Installs a user-supplied backend package manifest. Requires `-customPackagesJson`. Optionally accepts `-customFrontendUrl`; if omitted, the script prompts for it and falls back to the latest `vc-frontend` GitHub release when left blank.
- `customPackagesJson` (used only with `-vcSolutionVersion custom`): Path to a local `package.json` manifest **or** an `http(s)://` URL. Auto-detected. The file is copied/downloaded to `<targetFolder>\backend\custom-packages.json` and passed to `vc-build install --package-manifest-path`.
- `customFrontendUrl` (used only with `-vcSolutionVersion custom`, optional): Direct URL to a frontend ZIP artifact. If not provided, the script prompts; leaving the prompt empty falls back to the latest `vc-frontend` GitHub release.
- `skipSampleData` (optional, default `$false`): pass `$true` to skip sample data installation when the start step is invoked automatically

Custom-mode examples:

```pwsh
# Local manifest, frontend from GitHub release fallback
.\build-VC-solution.ps1 -vcSolutionVersion custom -customPackagesJson .\my-packages.json

# Remote manifest + explicit frontend ZIP URL (no prompts)
.\build-VC-solution.ps1 -vcSolutionVersion custom `
    -customPackagesJson https://example.com/my-bundle/package.json `
    -customFrontendUrl https://example.com/my-frontend.zip
```

2. Then run `start-VC-solution.ps1` to launch:
- Virtocommerce backend/frontend
- Database (PostgreSQL, MySQL, or SQL Server — configured in .env)
- Redis
- Elasticsearch
- Kibana

`start-VC-solution.ps1` accepts a `skipSampleData` parameter. When invoked directly (not via `build-VC-solution.ps1`), it defaults to `$true` — sample data is **not** installed on a bare `start` run. Pass `-skipSampleData $false` if you want to install sample data on a direct start.

Use `stop-VC-solution.ps1` to pause containers while preserving your data.

### Version Configuration
Customize versions and ports in the `.env` file. Default settings:

```
DB_PROVIDER=postgres

# PostgreSQL
PGSQL_VERSION=18.3
PGSQL_PORT=5432

# MySQL
MYSQL_VERSION=9.3
MYSQL_PORT=3306

# SQL Server
MSSQL_VERSION=2022-latest
MSSQL_PORT=1433

# Shared
DB_PASSWORD=$(New-RandomPassword)   # auto-generated at setup; do not edit manually unless you also reset the DB volume
STACK_VERSION=8.18.0
PLATFORM_PORT=8090
ES_PORT=9200
KIBANA_PORT=5601
REDIS_PASSWORD=$(New-RandomPassword)
ELASTIC_PASSWORD=$(New-RandomPassword)
KIBANA_PASSWORD=$(New-RandomPassword)
REDIS_PORT=6379
FRONTEND_PORT=80
ES_CLUSTER_NAME=elasticsearch
ES_LICENSE=basic
ES_MEM_LIMIT=1g
```

> [!IMPORTANT]
> After changing the `.env` file, restart the services using `stop-VC-solution.ps1` and `start-VC-solution.ps1`


## 🔄 Updating to a new version (keeps your data)

`update-VC-solution.ps1` moves an installed, running solution to a new backend (platform + modules) and frontend build without losing its data. It takes the same `-vcSolutionVersion`, `-customPackagesJson` and `-customFrontendUrl` parameters as `build-VC-solution.ps1`:

```pwsh
.\VirtoLocal\update-VC-solution.ps1 -vcSolutionVersion custom -customPackagesJson .\my-packages.json
```

What it does:
1. Reads the installed platform and module versions from the running platform container.
2. Builds the new images while the old ones keep running. It stops before changing anything if the platform or any module would be downgraded, because database migrations only go forward (override with `-allowDowngrade $true`). The `latest-stable` bundle can be older than an install that was built with `edge` or `custom`.
3. Stops only the platform and backs up the database (SQL Server: `BACKUP DATABASE`, checked with `RESTORE VERIFYONLY`; PostgreSQL: `pg_dump`; MySQL: `mysqldump`), cms-content and uploaded assets into `VirtoLocal/backups/update-<timestamp>/`, together with a `ROLLBACK.txt` for this exact update.
4. Replaces the platform container and the `virto_modules-data` volume. Docker fills a named volume from the image only while the volume is empty, so the old volume would hide the new image's modules.
5. Restarts the frontend (its nginx resolves the platform address only at start), waits for `/health` and reports every module that did not load.

The database, Elasticsearch and Redis containers keep running throughout.

Optional parameters:
- `-skipFrontend $true` keeps the installed frontend. With `-vcSolutionVersion custom` and no `-customFrontendUrl` the installed frontend is kept too; unlike a fresh build, an update does not fall back to the latest `vc-frontend` release.
- `-skipBackup $true` skips the database and cms-content backup. Uploaded assets that are not on a volume yet are still carried over.
- `-backupFolder <path>` puts the backup somewhere else.

> [!IMPORTANT]
> Uploaded assets (`wwwroot/assets`: product and page images, order documents) now live in the `virto_assets-data` volume. Before, they lived in the platform container's own filesystem and were lost every time the container was recreated, including `stop-VC-solution.ps1` followed by `start-VC-solution.ps1`, since `stop` runs `docker compose down`.
>
> On an existing install, run `update-VC-solution.ps1` first after taking the new `docker-compose.yml`: it carries the assets over into the volume. Running `stop-VC-solution.ps1` or `start-VC-solution.ps1` first recreates the platform container with an empty assets volume.

To roll an update back, follow `ROLLBACK.txt` in its backup folder. The previous images are kept as `vc-platform:pre-update-<timestamp>` and `vc-frontend:pre-update-<timestamp>`; the database has to be restored from the backup as well, because the new version has already migrated it.

## ⬆️ Upgrading from an earlier install

> [!WARNING]
> The multi-database release renames all Docker volumes with a `virto_` prefix (`virto_cms-content-data`, `virto_modules-data`, `virto_postgres_data`, `virto_esdata01`, `virto_redisdata`). If you already have a working install from an earlier version, running `start-VC-solution.ps1` after upgrading will create **new, empty** volumes — the old ones remain on disk but are no longer attached.
>
> Recommended upgrade path:
> 1. Start the old version and export anything you need (catalog data, modules, etc.).
> 2. Run `remove-VC-solution.ps1` on the old version to clean up orphan volumes.
> 3. Re-run the initial setup with the new version.
>
> If you prefer to keep the old data in place and start fresh, the old volumes can be identified with `docker volume ls` and removed manually when you are sure they are no longer needed.

## 🛠️ Troubleshooting

### Clearing Docker builder cache

In some cases, a failed or interrupted build can leave stale layers in the Docker builder cache, causing subsequent `build-VC-solution.ps1` runs to fail or produce unexpected results (e.g., missing files, outdated dependencies, or errors that disappear after a fresh pull). If you suspect this, inspect and clear the cache, then rebuild.

Check overall Docker disk usage (images, containers, volumes, build cache):

```pwsh
docker system df
```

For a detailed breakdown of individual build cache entries and their sizes:

```pwsh
docker system df -v
```

Or list builder cache records directly:

```pwsh
docker builder du
```

Remove all build cache:

```pwsh
docker builder prune -af
```

To reclaim space from unused images, containers, networks, **and** build cache in one go:

```pwsh
docker system prune -af
```

> [!WARNING]
> These commands remove cache/data on the host globally, not just for this solution. Subsequent builds of other projects will be slower until their caches are repopulated, and `docker system prune` will also delete any stopped containers and dangling images from unrelated projects.

## 🗑️ Uninstallation
To fully uninstall and erase all data:
1. Run `/VirtoLocal/remove-VC-solution.ps1`
- Stops containers
- Deletes persistent volumes
- Removes vc-platform:local-latest and vc-frontend:local-latest images

> [!WARNING]  
> This permanently destroys all data.

> [!WARNING]  
> Database (PostgreSQL, MySQL, or SQL Server), Redis, Elasticsearch, and Kibana base images remain installed.

## 🧪 Advanced / Testing

`VirtoLocal_create_local_files.ps1` supports a `-branch` parameter (default `dev`) that controls which branch of the [start-local](https://github.com/VirtoCommerce/start-local) repository is used to fetch the management scripts and docker-compose files. Use this when testing changes from a feature branch:

```pwsh
.\VirtoLocal_create_local_files.ps1 -branch feature/my-test-branch
```

This parameter has no interactive prompt and is intended for development/testing of the `start-local` scripts themselves.

## References
* [Home](https://virtocommerce.com)
* [Community](https://www.virtocommerce.org)
* [Documentation](https://docs.virtocommerce.org/)

## License

Copyright (c) Virto Solutions LTD.  All rights reserved.

Licensed under the Virto Commerce Open Software License (the "License"); you
may not use this file except in compliance with the License. You may
obtain a copy of the License at

http://virtocommerce.com/opensourcelicense

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
implied.
