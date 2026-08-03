param(
  [ValidateSet("production", "stable", "canary")]
  [string]$Channel = "production",
  [string]$Version = "",
  [string]$Build = "",
  [string]$DashHome = $(if ($env:DASH_HOME) { $env:DASH_HOME } else { Join-Path $HOME ".dash" }),
  [string]$ArtifactsBaseUrl = $(if ($env:DASH_ARTIFACTS_BASE_URL) { $env:DASH_ARTIFACTS_BASE_URL } else { "https://hutch.blackboard.sh" })
)

$ErrorActionPreference = "Stop"
if ($Channel -eq "stable") { $Channel = "production" }
if ($Version -and $Build) {
  throw "Hutch installer: -Version and -Build are mutually exclusive"
}

$platform = "windows-x64"
$temporary = Join-Path ([System.IO.Path]::GetTempPath()) ("hutch-install-" + [guid]::NewGuid())
New-Item -ItemType Directory -Force -Path $temporary | Out-Null

try {
  if ($Version) {
    $manifestUrl = "$ArtifactsBaseUrl/hutch/releases/$Version/manifest.json"
  } elseif ($Build) {
    $manifestUrl = "$ArtifactsBaseUrl/hutch/builds/$Build/manifest.json"
  } else {
    $channelManifest = Invoke-RestMethod -Uri "$ArtifactsBaseUrl/hutch/channels/$Channel.json"
    $manifestUrl = $channelManifest.release.url
    if (!$manifestUrl) { throw "Hutch installer: channel manifest has no release URL" }
  }

  $manifest = Invoke-RestMethod -Uri $manifestUrl
  $artifact = $manifest.platforms.$platform.archive
  if (!$manifest.version -or !$manifest.revision -or !$artifact.url -or !$artifact.sha256 -or !$artifact.size) {
    throw "Hutch installer: release manifest is incomplete for $platform"
  }

  $archive = Join-Path $temporary "hutch.tar.gz"
  Invoke-WebRequest -UseBasicParsing -Uri $artifact.url -OutFile $archive
  $actualHash = (Get-FileHash -Algorithm SHA256 -Path $archive).Hash.ToLowerInvariant()
  $actualSize = (Get-Item $archive).Length
  if ($actualHash -ne $artifact.sha256) {
    throw "Hutch installer: archive checksum mismatch"
  }
  if ($actualSize -ne [long]$artifact.size) {
    throw "Hutch installer: archive size mismatch"
  }

  $extractRoot = Join-Path $temporary "extracted"
  New-Item -ItemType Directory -Force -Path $extractRoot | Out-Null
  & tar.exe -xzf $archive --strip-components=1 -C $extractRoot
  if ($LASTEXITCODE -ne 0) { throw "Hutch installer: archive extraction failed" }

  $metadataPath = Join-Path $extractRoot "hutch-release.json"
  $launcherPath = Join-Path $extractRoot "bin\hutch.exe"
  $enginePath = Join-Path $extractRoot "bin\hutch-engine.exe"
  if (!(Test-Path $metadataPath) -or !(Test-Path $launcherPath) -or !(Test-Path $enginePath)) {
    throw "Hutch installer: archive is missing release files"
  }
  $metadata = Get-Content -Raw $metadataPath | ConvertFrom-Json
  if ($metadata.schema -ne 1 -or $metadata.product -ne "hutch" -or
      $metadata.version -ne $manifest.version -or
      $metadata.revision -ne $manifest.revision -or
      $metadata.platform -ne $platform) {
    throw "Hutch installer: archive metadata does not match the release manifest"
  }

  $installRoot = Join-Path $DashHome "products\hutch\$($manifest.version)\$($manifest.revision)\$platform"
  New-Item -ItemType Directory -Force -Path (Split-Path $installRoot) | Out-Null
  if (Test-Path $installRoot) { Remove-Item -Recurse -Force $installRoot }
  Set-Content -NoNewline -Path (Join-Path $extractRoot ".dash-installed") -Value $artifact.sha256
  Move-Item -Path $extractRoot -Destination $installRoot

  $channelDir = Join-Path $DashHome "channels\hutch"
  $binDir = Join-Path $DashHome "bin"
  New-Item -ItemType Directory -Force -Path $channelDir, $binDir | Out-Null
  Set-Content -Path (Join-Path $channelDir $Channel) -Value $installRoot

  $commandName = if ($Channel -eq "canary") { "hutch-canary.exe" } else { "hutch.exe" }
  $commandPath = Join-Path $binDir $commandName
  $commandTemporary = "$commandPath.tmp"
  Copy-Item -Force (Join-Path $installRoot "bin\hutch.exe") $commandTemporary
  Move-Item -Force $commandTemporary $commandPath

  $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
  $pathEntries = @($userPath -split ";" | Where-Object { $_ })
  if ($pathEntries -notcontains $binDir) {
    [Environment]::SetEnvironmentVariable(
      "Path",
      (($pathEntries + $binDir) -join ";"),
      "User"
    )
    Write-Host "Added $binDir to the user PATH. Open a new terminal to use it."
  }

  Write-Host "Installed Hutch $($manifest.version) ($Channel) at $installRoot"
} finally {
  Remove-Item -Recurse -Force $temporary -ErrorAction SilentlyContinue
}
