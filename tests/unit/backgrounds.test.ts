import { describe, expect, it } from 'vitest'
import { backgroundScriptPath, rDownloadCommand } from '../../src/backgrounds.js'

describe('rDownloadCommand', () => {
  it('builds a single-quoted R download expression', () => {
    const cmd = rDownloadCommand('https://rest.uniprot.org/x?q=1&y=2', '/Users/A B/out.tsv')
    expect(cmd).toBe("options(timeout=900); download.file('https://rest.uniprot.org/x?q=1&y=2', '/Users/A B/out.tsv', mode='wb')")
  })
  it('keeps paths with spaces inside the quotes', () => {
    expect(rDownloadCommand('https://e/x', '/a b/c d.tsv')).toContain("'/a b/c d.tsv'")
  })
})

describe('backgroundScriptPath', () => {
  it('uses the container mount path for the docker backend', () => {
    expect(backgroundScriptPath('build_kegg_background.R', 'docker')).toBe('/opt/ezprot-bg/build_kegg_background.R')
    expect(backgroundScriptPath('build_go_background.R', 'docker')).toBe('/opt/ezprot-bg/build_go_background.R')
  })
  it('uses the host script path for the local backend', () => {
    const p = backgroundScriptPath('build_kegg_background.R', 'local')
    expect(p.replace(/\\/g, '/')).toMatch(/r\/background\/build_kegg_background\.R$/)
  })
})
