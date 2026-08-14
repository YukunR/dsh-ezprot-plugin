import { describe, expect, it } from 'vitest'
import { ProteomicsService, STEPS } from '../../src/service.js'

describe('STEPS', () => {
  it('follows the documented order', () => {
    expect([...STEPS]).toEqual(['normalization', 'pca', 'batch_remove', 'dea', 'enrich', 'gsea', 'all'])
  })
})

describe('resolveBackend', () => {
  const svc = new ProteomicsService({})

  it('prefers local R in auto mode', () => {
    expect(svc.resolveBackend(true, true)).toBe('local')
    expect(svc.resolveBackend(true, false)).toBe('local')
  })
  it('falls back to docker when no local R exists', () => {
    expect(svc.resolveBackend(false, true)).toBe('docker')
    expect(svc.resolveBackend(false, false)).toBe('local')
  })
  it('honors explicit backends', () => {
    expect(new ProteomicsService({ backend: 'local' }).resolveBackend(false, true)).toBe('local')
    expect(new ProteomicsService({ backend: 'docker' }).resolveBackend(true, false)).toBe('docker')
  })
})

describe('formatSummary', () => {
  const svc = new ProteomicsService({})

  it('formats DEA summaries with thresholds and top proteins', () => {
    const lines = svc.formatSummary('dea', {
      dea: {
        'HD_vs_NC': {
          fcThreshold: 1.8,
          pThreshold: 0.05,
          fcSource: 'auto_coverage',
          up: 178,
          down: 234,
          total: 7928,
          topUp: [{ accession: 'P43137', gene: 'Reg1', log2fc: 4.087, p: 0.02 }],
          topDown: [{ accession: 'Q8QZW3', gene: 'Fam151a', log2fc: -3.256, p: 0.007 }],
          volcano: 'res/dea_results/HD_vs_NC/volcano_plot.pdf',
        },
      },
    })
    expect(lines.join('\n')).toContain('HD_vs_NC: 178 up / 234 down (FC 1.8, p 0.05, source: auto_coverage)')
    expect(lines.join('\n')).toContain('top up: Reg1(4.09)')
    expect(lines.join('\n')).toContain('top down: Fam151a(-3.26)')
  })

  it('formats batch summary for both outcomes', () => {
    expect(svc.formatSummary('batch_remove', { batch: { performed: false, batches: [], pcaAfter: 'x' } }).join('\n'))
      .toContain('batch removal: skipped')
    expect(svc.formatSummary('batch_remove', { batch: { performed: true, batches: ['1', '2'], pcaAfter: 'res/x' } }).join('\n'))
      .toContain('performed with batches [1, 2]')
  })

  it('formats enrichment and GSEA summaries', () => {
    const enrichment = svc.formatSummary('enrich', {
      enrichment: {
        'HC_vs_NC': {
          goTerms: 390,
          keggPathways: 52,
          topGo: [{ id: 'GO:0050660', description: 'flavin adenine dinucleotide binding', pAdjust: 1.19e-5, count: 18 }],
          topKegg: [{ id: 'mmu04610', description: 'Complement and coagulation cascades', pAdjust: 5.58e-12, count: 30 }],
        },
      },
    })
    expect(enrichment.join('\n')).toContain('390 GO terms, 52 KEGG pathways')
    expect(enrichment.join('\n')).toContain('Complement and coagulation cascades (p.adjust=0.00)')

    const gsea = svc.formatSummary('gsea', {
      gsea: {
        'HC_vs_NC': {
          totalSets: 258,
          topPositive: [{ id: 'mmu04380', description: 'Osteoclast differentiation', nes: 2.566, padj: 1.2e-5 }],
          topNegative: [{ id: 'mmu00983', description: 'Drug metabolism - other enzymes', nes: -3.025, padj: 1.29e-8 }],
        },
      },
    })
    expect(gsea.join('\n')).toContain('258 gene sets evaluated')
    expect(gsea.join('\n')).toContain('Osteoclast differentiation (NES=2.57)')
    expect(gsea.join('\n')).toContain('Drug metabolism - other enzymes (NES=-3.02)')
  })
})
