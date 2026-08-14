import { describe, expect, it } from 'vitest'
import { parseCsv, rComparisons, rEscape, rLogical, rNaThreshold, rNumber, rString, rVector } from '../../src/pipeline.js'

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
