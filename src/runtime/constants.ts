// Pinned versions, mirrors, and shared constants for the managed runtime.
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

/** Plugin package root (one level above src/). */
export const packageDir = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..')

export const R_VERSION = '4.4.0'
export const BIOC_VERSION = '3.20'

export const DEFAULT_MIRRORS = {
  cran: 'https://mirrors.westlake.edu.cn/CRAN',
  bioc: 'https://mirrors.westlake.edu.cn/bioconductor',
  rBase: 'https://mirrors.westlake.edu.cn/CRAN/bin/windows/base',
  fallbackCran: 'https://packagemanager.posit.co/cran/latest',
  fallbackBioc: 'https://bioconductor.org',
  fallbackRBase: 'https://cloud.r-project.org/bin/windows/base',
}

// Linux has no CRAN binary repo on the Westlake mirrors; Posit PPM serves
// pre-built Ubuntu binaries (the installer swaps in the container's codename).
// Date-pinned to the Bioc 3.20 era: PPM "latest" now targets R >= 4.5 and
// ships CRAN versions (ggplot2 4.x, ...) that Bioc 3.20 packages were never
// built against.
export const LINUX_BINARY_CRAN = 'https://packagemanager.posit.co/cran/__linux__/jammy/2024-11-15'

/** Fallback image when no dockerImage is configured or persisted. */
export const DEFAULT_DOCKER_IMAGE = 'ezprot:latest'

/** The package-install script shipped inside the package. */
export const installScriptPath = () => join(packageDir, 'r', 'setup', 'install_packages.R')

/** The runtime probe script shipped inside the package. */
export const checkScriptPath = () => join(packageDir, 'r', 'setup', 'check_runtime.R')
