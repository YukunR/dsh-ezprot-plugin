# Create an offline R package snapshot for lab machines with poor network.
#
# Run this ONCE on a machine that already has a complete R 4.4 library
# (for example the renv library used during development). The zip can then be
# restored on any lab machine with:
#   proteomics_environment action=restore_snapshot snapshotPath=<zip>
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File scripts\create-offline-snapshot.ps1 `
#     -LibraryDir "D:\path\to\your\R-library" `
#     -Output "D:\ezprot-offline-snapshot.zip"
param(
  [Parameter(Mandatory = $true)]
  [string]$LibraryDir,
  [Parameter(Mandatory = $true)]
  [string]$Output
)

if (-not (Test-Path $LibraryDir)) {
  throw "Library directory not found: $LibraryDir"
}

Write-Host "Creating offline snapshot of $LibraryDir -> $Output"
Write-Host "This may take several minutes (1-2 GB)."

# Compress-Archive is slow on huge trees; prefer tar (bsdtar) when available.
if (Get-Command tar.exe -ErrorAction SilentlyContinue) {
  $parent = Split-Path -Parent $LibraryDir
  $leaf = Split-Path -Leaf $LibraryDir
  # The zip must contain the library directory itself so restore puts
  # packages back under <runtimeDir>/library.
  Push-Location $parent
  try {
    & tar.exe -a -cf $Output $leaf
    if ($LASTEXITCODE -ne 0) { throw "tar failed with exit code $LASTEXITCODE" }
  } finally {
    Pop-Location
  }
} else {
  Compress-Archive -Path $LibraryDir -DestinationPath $Output -CompressionLevel Optimal
}

if (Test-Path $Output) {
  $sizeMB = [math]::Round((Get-Item $Output).Length / 1MB, 1)
  Write-Host "Snapshot ready: $Output ($sizeMB MB)"
} else {
  throw "Snapshot was not created"
}
