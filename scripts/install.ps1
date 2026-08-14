# One-command installer: mount the ezprot bundle into a dsh profile.
#
# Canonical path: `dsh plugin --profile <name> add <pkg-or-path>` — the bundle
# declaration makes dsh register the layer in dsh.profile.bundles
# automatically. When dsh/pnpm is unavailable this script falls back to a
# physical copy into the profile node_modules plus a manual bundles append.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File scripts\install.ps1 [-Profile web] [-PluginPath <repo root>]
param(
  [string]$Profile = 'web',
  [string]$PluginPath = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
$profileDir = Join-Path $env:DSH_HOME 'profiles' $Profile
if (-not (Test-Path $profileDir)) { throw "profile not found: $profileDir" }

$pkgJson = Get-Content (Join-Path $PluginPath 'package.json') -Raw | ConvertFrom-Json
$pkgName = $pkgJson.name
Write-Host "Installing bundle $pkgName from $PluginPath into profile '$Profile'"

# 1) canonical path: dsh plugin add (needs dsh + pnpm on PATH)
if (Get-Command dsh -ErrorAction SilentlyContinue) {
  $ref = 'file:' + ($PluginPath -replace '\\', '/')
  & dsh plugin --profile $Profile add $ref
  if ($LASTEXITCODE -eq 0) {
    Write-Host 'installed via dsh plugin add; bundle auto-registered in dsh.profile.bundles'
    Write-Host "Done. Restart 'dsh web' to activate the plugin."
    exit 0
  }
  Write-Host 'dsh plugin add failed - falling back to manual copy'
}

# 2) fallback: physical copy + manual bundles registration
$profilePkg = Join-Path $profileDir 'package.json'
$json = Get-Content $profilePkg -Raw | ConvertFrom-Json
$fileRef = 'file:' + ($PluginPath -replace '\\', '/')
if (-not $json.dependencies) { $json | Add-Member -NotePropertyName dependencies -NotePropertyValue (@{}) }
$json.dependencies | Add-Member -NotePropertyName $pkgName -NotePropertyValue $fileRef -Force
$bundles = @($json.dsh.profile.bundles)
if ($bundles -notcontains $pkgName) { $bundles += $pkgName }
$json.dsh.profile.bundles = $bundles
$enc = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($profilePkg, ($json | ConvertTo-Json -Depth 8), $enc)
Write-Host '  profile package.json updated (dependency + bundles)'

$target = Join-Path (Split-Path -Parent $profileDir) 'node_modules' $pkgName
robocopy $PluginPath $target /MIR /XD node_modules .git tests\projects tests\.runtime /NFL /NDL /NJH /NJS | Out-Null
if (-not (Test-Path (Join-Path $target 'package.json'))) { throw "copy failed: $target" }
Write-Host "  copied to $target"

Write-Host "Done. Restart 'dsh web' to activate the plugin."
