param(
  [ValidateSet("production", "stable", "canary")]
  [string]$Channel = "production",
  [string]$Version = "",
  [string]$Build = "",
  [Alias("DashHome")]
  [string]$HutchHome = $(
    if ($env:HUTCH_HOME) { $env:HUTCH_HOME }
    elseif ($env:DASH_HOME) { $env:DASH_HOME }
    else { Join-Path $HOME ".hutch" }
  ),
  [string]$ArtifactsBaseUrl = $(if ($env:DASH_ARTIFACTS_BASE_URL) { $env:DASH_ARTIFACTS_BASE_URL } else { "https://hutch.blackboard.sh" }),
  [switch]$NoModifyPath
)

$ErrorActionPreference = "Stop"
if ($Channel -eq "stable") { $Channel = "production" }
if ($Version -and $Build) {
  throw "Hutch installer: -Version and -Build are mutually exclusive"
}

$platform = "windows-x64"
$temporary = Join-Path ([System.IO.Path]::GetTempPath()) ("hutch-install-" + [guid]::NewGuid())
$stageRoot = $null
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
  $sha256 = [System.Security.Cryptography.SHA256]::Create()
  $archiveStream = [System.IO.File]::OpenRead($archive)
  try {
    $actualHash = [System.BitConverter]::ToString($sha256.ComputeHash($archiveStream)).Replace("-", "").ToLowerInvariant()
  } finally {
    $archiveStream.Dispose()
    $sha256.Dispose()
  }
  $actualSize = (Get-Item $archive).Length
  if ($actualHash -ne $artifact.sha256) {
    throw "Hutch installer: archive checksum mismatch"
  }
  if ($actualSize -ne [long]$artifact.size) {
    throw "Hutch installer: archive size mismatch"
  }

  $installRoot = Join-Path $HutchHome "releases\hutch\$($manifest.version)\$($manifest.revision)\$platform"
  $installParent = Split-Path $installRoot
  New-Item -ItemType Directory -Force -Path $installParent | Out-Null
  $stageRoot = Join-Path $installParent (".hutch-install-$platform-" + [guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Path $stageRoot | Out-Null
  & tar.exe -xzf $archive --strip-components=1 -C $stageRoot
  if ($LASTEXITCODE -ne 0) { throw "Hutch installer: archive extraction failed" }

  $metadataPath = Join-Path $stageRoot "hutch-release.json"
  $launcherPath = Join-Path $stageRoot "bin\hutch.exe"
  $enginePath = Join-Path $stageRoot "bin\hutch-engine.exe"
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

  [System.IO.File]::WriteAllBytes(
    (Join-Path $stageRoot ".dash-installed"),
    [System.Text.Encoding]::ASCII.GetBytes([string]$artifact.sha256)
  )
  $bootstrapEngine = Join-Path $temporary "hutch-engine.exe"
  Copy-Item -Path $enginePath -Destination $bootstrapEngine

  $previousHutchHome = $env:HUTCH_HOME
  try {
    $env:HUTCH_HOME = $HutchHome
    & $bootstrapEngine self bootstrap-install $Channel $stageRoot
    if ($LASTEXITCODE -ne 0) { throw "Hutch installer: could not bootstrap release selection" }
  } finally {
    $env:HUTCH_HOME = $previousHutchHome
  }

  $finalLauncherPath = Join-Path $installRoot "bin\hutch.exe"
  $finalEnginePath = Join-Path $installRoot "bin\hutch-engine.exe"
  if (!(Test-Path $finalLauncherPath) -or !(Test-Path $finalEnginePath)) {
    throw "Hutch installer: bootstrap did not publish the release"
  }

  $binDir = Join-Path $HutchHome "bin"
  New-Item -ItemType Directory -Force -Path $binDir | Out-Null
  $commandName = if ($Channel -eq "canary") { "hutch-canary.exe" } else { "hutch.exe" }
  $commandPath = Join-Path $binDir $commandName
  $commandTemporary = "$commandPath.tmp-$([guid]::NewGuid().ToString('N'))"
  Copy-Item -Force $finalLauncherPath $commandTemporary
  Move-Item -Force $commandTemporary $commandPath

  if (!$NoModifyPath) {
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
  }

  Write-Host "Installed Hutch $($manifest.version) ($Channel) at $installRoot"
} finally {
  if ($stageRoot) {
    Remove-Item -Recurse -Force $stageRoot -ErrorAction SilentlyContinue
  }
  Remove-Item -Recurse -Force $temporary -ErrorAction SilentlyContinue
}
