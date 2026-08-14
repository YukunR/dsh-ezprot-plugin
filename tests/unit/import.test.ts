import { describe, expect, it } from 'vitest'
import { classifyColumns, inferGroupNames, parseTable } from '../../src/import.js'

describe('parseTable', () => {
  it('splits header and rows and counts missing conventions', () => {
    const t = parseTable('Majority protein IDs\tGene names\tMW [kDa]\tLFQ intensity HC_1\tLFQ intensity HC_2\nP12345\tAlb\t69.3\t0\t100.5\nQ9XYZ1\tHspa1a\t70.1\tNaN\t\n')
    expect(t.header).toEqual(['Majority protein IDs', 'Gene names', 'MW [kDa]', 'LFQ intensity HC_1', 'LFQ intensity HC_2'])
    expect(t.rows).toHaveLength(2)
    expect(t.missing.zero).toBe(1)
    expect(t.missing.nan).toBe(1)
    expect(t.missing.blank).toBe(1)
  })
})

describe('classifyColumns', () => {
  const header = ['Majority protein IDs', 'Gene names', 'Fasta headers', 'MW [kDa]', 'Sequence coverage [%]', 'LFQ intensity NC_1', 'LFQ intensity NC_2', 'LFQ intensity HC_1', 'LFQ intensity HC_2', 'Q-value']
  const rows = [
    ['P12345', 'Alb', 'sp|P12345|ALBU_MOUSE', '69.3', '45.1', '100.5', '99.2', '0', '88.4', '0.001'],
    ['Q9XYZ1', 'Hspa1a', 'sp|Q9XYZ1|HS71A_MOUSE', '70.1', '32.7', 'NaN', '50.1', '77.3', '81.9', '0.02'],
  ]

  it('labels id/gene/desc/annotation/sample roles', () => {
    const cols = classifyColumns(header, rows)
    const role = (name: string) => cols.find((c) => c.name === name)?.role
    expect(role('Majority protein IDs')).toBe('id')
    expect(role('Gene names')).toBe('gene')
    expect(role('Fasta headers')).toBe('desc')
    expect(role('MW [kDa]')).toBe('annotation')
    expect(role('Sequence coverage [%]')).toBe('annotation')
    expect(role('Q-value')).toBe('annotation')
    for (const s of ['LFQ intensity NC_1', 'LFQ intensity NC_2', 'LFQ intensity HC_1', 'LFQ intensity HC_2']) {
      expect(role(s)).toBe('sample')
    }
  })

  it('detects accession-like unknown columns as id candidates', () => {
    const cols = classifyColumns(['Whatever', 'X'], [['P12345', '1'], ['Q9XYZ1', '2']])
    expect(cols[0].role).toBe('id')
  })
})

describe('inferGroupNames', () => {
  it('strips replicate suffixes', () => {
    expect(inferGroupNames(['NC_1', 'NC_2', 'HC_1', 'HD_5'])).toEqual(['NC', 'HC', 'HD'])
  })
  it('handles dot and dash separators', () => {
    expect(inferGroupNames(['ctrl.1', 'ctrl-2', 'treat.1'])).toEqual(['ctrl', 'treat'])
  })
})
