import { describe, expect, it } from 'vitest'
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { ProteomicsService } from '../../src/service.js'

function makeProject(): string {
  const dir = mkdtempSync(join(tmpdir(), 'ezprot-batch-'))
  mkdirSync(join(dir, 'data'), { recursive: true })
  writeFileSync(join(dir, 'data', 'sample_info.txt'), 'Sample\tGroup\nNC_1\tNC\nNC_2\tNC\nHC_1\tHC\nHC_2\tHC\n', 'utf8')
  return dir
}

describe('proteomics_batch service', () => {
  it('lists samples and reports no Batch column', async () => {
    const dir = makeProject()
    try {
      const svc = new ProteomicsService({ dataDir: join(dir, 'runtime') })
      const out = await svc.batchList(dir)
      expect(out).toContain('4 samples')
      expect(out).toContain('NC_1')
      expect(out).toContain('no Batch column yet')
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })

  it('set writes the Batch column and clear removes it', async () => {
    const dir = makeProject()
    try {
      const svc = new ProteomicsService({ dataDir: join(dir, 'runtime') })
      const out = await svc.setBatch(dir, { NC_1: '1', NC_2: '1', HC_1: '2', HC_2: '2' })
      expect(out).toContain('2 batch(es): 1, 2')
      const text = readFileSync(join(dir, 'data', 'sample_info.txt'), 'utf8')
      expect(text).toContain('Sample\tGroup\tBatch')
      expect(text).toContain('NC_1\tNC\t1')
      // updating only one sample keeps the others
      await svc.setBatch(dir, { HC_2: '3' })
      const text2 = readFileSync(join(dir, 'data', 'sample_info.txt'), 'utf8')
      expect(text2).toContain('HC_2\tHC\t3')
      expect(text2).toContain('NC_1\tNC\t1')
      const cleared = await svc.clearBatch(dir)
      expect(cleared).toContain('Batch column removed')
      const text3 = readFileSync(join(dir, 'data', 'sample_info.txt'), 'utf8')
      expect(text3).not.toContain('Batch')
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })
})
