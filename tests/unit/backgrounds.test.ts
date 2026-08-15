import { describe, expect, it } from 'vitest'
import { rDownloadCommand } from '../../src/backgrounds.js'

describe('rDownloadCommand', () => {
  it('builds a single-quoted R download expression', () => {
    const cmd = rDownloadCommand('https://rest.uniprot.org/x?q=1&y=2', '/Users/A B/out.tsv')
    expect(cmd).toBe("options(timeout=900); download.file('https://rest.uniprot.org/x?q=1&y=2', '/Users/A B/out.tsv', mode='wb')")
  })
  it('keeps paths with spaces inside the quotes', () => {
    expect(rDownloadCommand('https://e/x', '/a b/c d.tsv')).toContain("'/a b/c d.tsv'")
  })
})
