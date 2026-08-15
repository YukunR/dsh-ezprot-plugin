import { describe, expect, it } from 'vitest'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { parseCsv, preflight, rComparisons, rEscape, rLogical, rNaThreshold, rNumber, rString, rVector, toContainerPath, toHostPath, dockerMountArgs } from '../../src/pipeline.js'

async function withMatrix(content: string, fn: (file: string) => Promise<void>): Promise<void> {
  const dir = mkdtempSync(join(tmpdir(), 'ezprot-pf-'))
  const file = join(dir, 'origin_data.txt')
  try {
    writeFileSync(file, content, 'utf8')
    await fn(file)
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
}

describe('rEscape / rString', () => {
  it('doubles backslashes for R string content', () => {
    expect(rEscape('D:\\ResearchProject\\x')).toBe('D:\\\\ResearchProject\\\\x')
  })
  it('escapes double quotes', () => {
    expect(rEscape('say "hi"')).toBe('say \\"hi\\"')
  })
  it('rString wraps in quotes', () => {
    expect(rString('ab')).toBe('"ab"')
  })
  it('handles non-string values', () => {
    expect(rString(123)).toBe('"123"')
    expect(rEscape(null)).toBe('null')
  })
})

describe('rNumber / rLogical / rVector', () => {
  it('formats finite numbers', () => {
    expect(rNumber(1.5)).toBe('1.5')
    expect(rNumber('2')).toBe('2')
  })
  it('passes non-numeric values through', () => {
    expect(rNumber('abc')).toBe('abc')
  })
  it('builds logicals', () => {
    expect(rLogical(true)).toBe('TRUE')
    expect(rLogical(false)).toBe('FALSE')
  })
  it('builds string vectors', () => {
    expect(rVector(['a', 'b'])).toBe('c("a", "b")')
  })
})

describe('rNaThreshold', () => {
  it('defaults to the two-threshold pair', () => {
    expect(rNaThreshold(undefined)).toBe('c(0.6, 0.9)')
  })
  it('accepts a pair', () => {
    expect(rNaThreshold([0.7, 0.95])).toBe('c(0.7, 0.95)')
  })
  it('accepts a single threshold', () => {
    expect(rNaThreshold(0.8)).toBe('0.8')
  })
})

describe('rComparisons', () => {
  it('builds simple comparisons', () => {
    expect(rComparisons([{ control: 'NC', treatment: 'HC', name: 'HC_vs_NC' }])).toBe(
      'list(list(control = "NC", treatment = "HC", name = "HC_vs_NC"))',
    )
  })
  it('supports multi-group control and per-comparison thresholds', () => {
    expect(rComparisons([
      { control: ['HC', 'NC'], treatment: 'HD', name: 'HD_vs_Rest', fc_threshold: 2, p_threshold: 0.01 },
    ])).toBe(
      'list(list(control = c("HC", "NC"), treatment = "HD", name = "HD_vs_Rest", fc_threshold = 2, p_threshold = 0.01))',
    )
  })
  it('handles null comparisons', () => {
    expect(rComparisons(null)).toBe('list()')
  })
})

describe('parseCsv', () => {
  it('parses simple rows', () => {
    expect(parseCsv('a,b\n1,2\n3,4')).toEqual([
      { a: '1', b: '2' },
      { a: '3', b: '4' },
    ])
  })
  it('handles quoted fields with commas and escaped quotes', () => {
    expect(parseCsv('id,desc\na,"b, c"\nd,"say ""hi"""')).toEqual([
      { id: 'a', desc: 'b, c' },
      { id: 'd', desc: 'say "hi"' },
    ])
  })
  it('tolerates trailing newline and CRLF', () => {
    expect(parseCsv('a,b\r\n1,2\r\n')).toEqual([{ a: '1', b: '2' }])
  })
  it('returns [] for empty input', () => {
    expect(parseCsv('')).toEqual([])
  })
})

describe('docker path helpers', () => {
  it('converts host paths to forward slashes', () => {
    expect(toHostPath('C:\\Users\\A B\\.dsh\\x')).toBe('C:/Users/A B/.dsh/x')
  })
  it('strips the drive letter for container paths', () => {
    expect(toContainerPath('C:\\Users\\A B\\.dsh\\x')).toBe('/Users/A B/.dsh/x')
    expect(toContainerPath('C:/Users/A B/.dsh/x')).toBe('/Users/A B/.dsh/x')
  })
  it('builds --mount bind args with comma delimiters (no colon parsing)', () => {
    const args = dockerMountArgs('D:\\proj\\demo', 'C:\\Users\\A B\\.dsh\\proteomics\\backgrounds')
    expect(args).toEqual([
      '--mount', 'type=bind,source=D:/proj/demo,target=/workspace',
      '--mount', 'type=bind,source=C:/Users/A B/.dsh/proteomics/backgrounds,target=/Users/A B/.dsh/proteomics/backgrounds',
    ])
    // the two Windows drive-letter colons must not leak into the mounts
    for (const a of args) expect(a.startsWith('-v')).toBe(false)
  })
})

describe('preflight', () => {
  it('flags non-numeric columns that would be treated as samples', async () => {
    await withMatrix([
      'Accession\tGeneName\tDescription\tNC_1\tNC_2\tReverse\tPotential contaminant',
      'P1\tG1\tdesc one\t10.5\t11.2\t+\t+',
      'P2\tG2\tdesc two\t8.1\tNaN\t\t',
      'P3\tG3\tdesc three\t9.0\t9.5\t+\t',
      '',
    ].join('\n'), async (file) => {
      const qc = await preflight(file, null)
      expect(qc.nonNumericSampleColumns).toEqual(['Reverse', 'Potential contaminant'])
      expect(qc.sampleColumns).toEqual(['NC_1', 'NC_2', 'Reverse', 'Potential contaminant'])
      expect(qc.nProteins).toBe(3)
    })
  })
  it('accepts fully numeric sample columns without flags', async () => {
    await withMatrix([
      'Accession\tGeneName\tDescription\tNC_1\tNC_2\tHC_1',
      'P1\tG1\tdesc1\t10.5\t11.2\t12.1',
      'P2\tG2\tdesc2\t8.1\tNaN\t7.9',
      '',
    ].join('\n'), async (file) => {
      const qc = await preflight(file, null)
      expect(qc.nonNumericSampleColumns).toEqual([])
      expect(qc.nSamples).toBe(3)
    })
  })
})
