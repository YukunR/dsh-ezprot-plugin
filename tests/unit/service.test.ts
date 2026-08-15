import { describe, expect, it } from 'vitest'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { ProteomicsService, STEPS } from '../../src/service.js'

describe('STEPS', () => {
  it('follows the documented order', () => {
    expect([...STEPS]).toEqual(['normalization', 'pca', 'batch_remove', 'dea', 'enrich', 'gsea', 'all'])
  })
})

describe('resolveBackend', () => {
  it('prefers local R in auto mode', async () => {
    const svc = new ProteomicsService({ dataDir: '' })
    expect(await svc.resolveBackend(true, true)).toBe('local')
    expect(await svc.resolveBackend(true, false)).toBe('local')
  })
  it('falls back to docker when no local R exists', async () => {
    const svc = new ProteomicsService({ dataDir: '' })
    expect(await svc.resolveBackend(false, true)).toBe('docker')
    expect(await svc.resolveBackend(false, false)).toBe('local')
  })
  it('honors explicit backends', async () => {
    expect(await new ProteomicsService({ backend: 'local', dataDir: '' }).resolveBackend(false, true)).toBe('local')
    expect(await new ProteomicsService({ backend: 'docker', dataDir: '' }).resolveBackend(true, false)).toBe('docker')
  })
  it('honors the persisted setup choice over auto detection', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'ezprot-be-'))
    try {
      const svc = new ProteomicsService({ dataDir: dir })
      await svc.runtime.setState({ backend: 'docker', dockerImage: 'test/ezprot:latest' })
      expect(await svc.resolveBackend(true, true)).toBe('docker') // local R exists, but user chose docker
      await svc.runtime.setState({ backend: 'local' })
      expect(await svc.resolveBackend(false, true)).toBe('local') // docker exists, but user chose local R
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })
  it('rejects the persisted docker choice when Docker is unavailable', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'ezprot-be-'))
    try {
      const svc = new ProteomicsService({ dataDir: dir })
      await svc.runtime.setState({ backend: 'docker' })
      await expect(svc.resolveBackend(true, false)).rejects.toThrow(/Docker is not available/)
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })
})

describe('preflightProject', () => {
  it('completes with a generated sample_info.txt and survives a re-run on the same project', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'ezprot-proj-'))
    try {
      const matrix = join(dir, 'matrix.txt')
      writeFileSync(matrix, [
        'Accession\tGeneName\tDescription\tNC_1\tNC_2',
        'P1\tG1\td1\t10.5\t11.2',
        'P2\tG2\td2\t8.1\tNaN',
        '',
      ].join('\n'), 'utf8')
      const svc = new ProteomicsService({ dataDir: join(dir, 'ds') })
      const projectDir = join(dir, 'proj')
      const out = await svc.preflightProject({ projectDir, proteinFile: matrix, organism: 'mouse' })
      expect(out).toContain('preflight OK')
      expect(out).toContain('sample_info.txt generated')
      // Re-run on the same project: its own origin_data.txt/sample_info.txt
      // are passed back in, so create() must not copy files onto themselves.
      const again = await svc.preflightProject({
        projectDir,
        proteinFile: join(projectDir, 'data', 'origin_data.txt'),
        sampleInfoFile: join(projectDir, 'data', 'sample_info.txt'),
        organism: 'mouse',
      })
      expect(again).toContain('preflight OK')
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })
})

describe('assertDockerReady', () => {
  it('accepts a present CLI with a pulled image', async () => {
    const svc = new ProteomicsService({})
    svc.runtime.dockerImageReady = async () => true
    await expect(svc.assertDockerReady('yukunru/ezprot:latest', true)).resolves.toBeUndefined()
  })
  it('rejects when the CLI is missing', async () => {
    const svc = new ProteomicsService({})
    svc.runtime.dockerImageReady = async () => true
    await expect(svc.assertDockerReady('yukunru/ezprot:latest', false)).rejects.toThrow(/Docker is unavailable/)
  })
  it('rejects when the image has not been pulled', async () => {
    const svc = new ProteomicsService({})
    svc.runtime.dockerImageReady = async () => false
    await expect(svc.assertDockerReady('yukunru/ezprot:latest', true)).rejects.toThrow(/not present on this machine/)
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
