// Reads crewtier's own state files (~/.crewtier) into what the pane draws.
import type { Health, Stat, Task } from '../types'

// health.tsv: "<agent>[/<model>]|<status>|<detail>|<epoch seconds>"
export const parseHealth = (text: string): Record<string, Health> => {
  const out: Record<string, Health> = {}
  for (const line of text.split('\n')) {
    const [key, status, detail = '', at = '0'] = line.split('|')
    if (key && status) out[key] = { status, detail: detail.trim(), at: Number(at) * 1000 }
  }
  return out
}

const rows = (tsv: string) => {
  const [head = '', ...lines] = tsv.split('\n').filter(Boolean)
  const cols = head.split('\t')
  return lines.map(line => {
    const cells = line.split('\t')
    return Object.fromEntries(cols.map((c, i) => [c, cells[i] ?? ''])) as Record<string, string>
  })
}

// results.tsv holds each task's outcome, worker-usage.tsv each worker run's seconds.
export const parseHistory = (results: string, usage: string) => {
  const tasks: Task[] = rows(results).map(r => ({
    date: r.date ?? '',
    repo: r.repo ?? '',
    task: r.task ?? '',
    tier: r.tier ?? '',
    worker: r.worker ?? '',
    pass: r.outcome === 'pass',
    lines: Number(r.diff_lines) || 0,
  }))
  const stats: Record<string, Stat> = {}
  const stat = (w: string) => (stats[w] ??= { runs: 0, pass: 0, seconds: 0, timed: 0 })
  for (const t of tasks) {
    const s = stat(t.worker)
    s.runs++
    if (t.pass) s.pass++
  }
  for (const u of rows(usage)) {
    if (!u.worker || !Number(u.seconds)) continue
    const s = stat(u.worker)
    s.seconds += Number(u.seconds)
    s.timed++
  }
  return { stats, recent: tasks.slice(-6).reverse(), total: tasks.length, passed: tasks.filter(t => t.pass).length }
}

export const ago = (ms: number) => {
  const m = Math.max(0, Math.round(ms / 60_000))
  return m < 1
    ? 'just now'
    : m < 60
      ? `${m}m ago`
      : m < 1440
        ? `${Math.round(m / 60)}h ago`
        : `${Math.round(m / 1440)}d ago`
}

// Theme key for a health status: ready, out of quota (comes back by itself), broken, or never checked.
export const tone = (status?: string) =>
  !status ? 'inactive' : status === 'ready' ? 'success' : /quota|rate|limit/.test(status) ? 'warning' : 'error'
