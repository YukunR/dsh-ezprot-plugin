// Shared runtime types. Split from the old monolithic runtime.ts so each
// runtime concern (R detection, packages, docker, state, snapshot) owns its
// own module while the Runtime facade keeps the public API unchanged.
export interface RuntimeConfig {
  dataDir?: string
  libraryDir?: string
  rscript?: string
  cranRepo?: string
  biocRepo?: string
  enableInstall?: boolean
  defaultTimeoutMs?: number
  backend?: string
  dockerImage?: string
}

export interface PackageManifest {
  rVersion?: string
  cran: string[]
  bioc: string[]
}

export interface RuntimeStatus {
  ok: boolean
  rscript: string | null
  rVersion: string | null
  libraryDir: string
  missing: string[] | null
  message: string
}

export type LogSink = (chunk: string) => void

/** Directory/mirror context every runtime submodule needs. */
export interface RuntimePaths {
  dataDir: string
  runtimeDir: string
  downloadsDir: string
  libraryDir: string
  cranRepo: string
  biocRepo: string
  rBase: string
}
