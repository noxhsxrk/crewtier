import { expect, test } from 'claude-code/testing'

import { parseHistory } from '../hooks/board'
import { parseWorkers, report } from '../hooks/register'

const PANE = {
  plugin: 'crewtier',
  component: 'Pane',
  requestId: 'crewtier',
  props: {
    title: 'crewtier',
    isFocused: false,
    bodyColumns: 80,
    placement: 'dock',
    scroll: { offset: 0, bodyRows: 20 },
    view: {},
  },
} as const

test('report reads do.sh result lines', () => {
  expect(report('D3 PASS codex/gpt · 412 lines (5 files) · 3m2s · commit abc1234')).toEqual({
    outcome: 'pass',
    line: 'D3 PASS codex/gpt · 412 lines (5 files) · 3m2s · commit abc1234',
  })
  expect(report('noise\nD4 failed (last tier: t3-hard, last worker: agy/x) · 9m0s\nlog: x').outcome).toBe('fail')
  expect(report('D5 VERIFY-ERROR: the check command didn\'t run').outcome).toBe('fail')
})

test('a crewtier do call lands in the pane as PASS; other Bash is ignored', async ($, on) => {
  on('command.register', () => ({ value: { command: 'crew' } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('store.get', () => ({ value: undefined }))
  on('clock.now', () => ({ value: 1000 }))
  on('clock.every', () => ({ value: undefined }))
  on('ui.toast', () => ({ value: undefined }))
  on('tool.call', (_, e) =>
    'command' in e && /crewtier do/.test(String(e.command))
      ? { result: {}, text: 'D1 PASS codex/gpt-6 · 350 lines (4 files) · 2m10s' }
      : { result: {}, text: 'ok' },
  )

  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  await $.tool.call({ tool: 'Bash', command: 'ls' })
  await $.tool.call({
    tool: 'Bash',
    command: 'CREWTIER_LEAD=claude crewtier do t2-normal --spec s.md --commit "x"',
  })

  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  const row = await ui.find({ type: 'Text', text: /D1 PASS/ })
  expect(row?.text).toBe('D1 PASS codex/gpt-6 · 350 lines (4 files) · 2m10s')
  expect(await ui.find({ type: 'Text', text: '✓' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /Nothing delegated/ })).toBe(undefined)
  await ui.unmount()
})

const COMPOSE = { model: 'm', promptModel: 'm', surfaces: [], tools: [], outputStyle: null, traits: [] }

test('band off switch: denies crewtier do and adds the off rule to the system prompt', async ($, on) => {
  const store = new Map<string, unknown>()
  on('command.register', () => ({ value: { command: 'crew' } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('store.get', (_, e) => ({ value: store.get(e.key) }))
  on('store.set', (_, e) => (store.set(e.key, e.value), { value: undefined }))
  on('clock.now', () => ({ value: 1000 }))
  on('tool.call', () => ({ result: {}, text: 'D1 PASS x' }))
  on('prompt.compose', () => ({ sections: [{ id: 'intro', text: 'hi', scope: 'shared' }] }))

  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  const band = await $.ui.mount({
    plugin: 'crewtier',
    component: 'AbovePrompt',
    surface: 'terminal',
    props: { bodyColumns: 120, hasSurvey: false, isCollapsed: false, isWorking: false, maxRows: 10, scroll: { offset: 0, bodyRows: 1 }, view: {} },
  })
  await band.press({ key: 'mode-off' })
  expect(store.get('delegation')).toBe('off')

  const ran = await $.tool.call({ tool: 'Bash', command: 'crewtier do t2-normal --spec s.md' })
  expect(ran.deny).toMatch(/delegation is off/)
  const composed = await $.prompt.compose(COMPOSE)
  expect(composed.sections.map(s => s.id)).toEqual(['intro', 'crewtier:off'])

  await band.press({ key: 'mode-on' })
  expect(store.get('delegation')).toBe('on')
  expect((await $.prompt.compose(COMPOSE)).sections.map(s => s.id)).toEqual(['intro'])
  await band.unmount()
})

test('parseWorkers reads on and off rows', () => {
  expect(
    parseWorkers('Workers\n  claude    on    ready\n  codex     off   (crewtier enable codex)\ncrewtier disable <agent…>'),
  ).toEqual([
    { name: 'claude', on: true, status: 'ready' },
    { name: 'codex', on: false, status: '' },
  ])
})

test('pane: toggling a worker and moving a model run the crewtier CLI', async ($, on) => {
  const calls: string[] = []
  let codexOn = true
  on('clock.now', () => ({ value: 1000 }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('ui.toast', () => ({ value: undefined }))
  on('env.get', () => ({ value: '/home/me' }))
  on('fs.read', (_, e) => {
    const files: Record<string, string> = {
      '/home/me/.crewtier/health.tsv': 'claude|ready|ping ok|1\ncodex|quota-exhausted|weekly limit hit|1\n',
      '/home/me/.crewtier/results.tsv':
        'date\trepo\ttask\ttier\tworker\toutcome\tdiff_lines\n2026-11-20\tapp\tD1\tt1-easy\tagy/a\tpass\t120\n',
      '/home/me/.crewtier/worker-usage.tsv': 'date\tworker\tseconds\n2026-11-20\tagy/a\t90\n',
    }
    const text = files[(e as { path: string }).path]
    return text === undefined ? { deny: 'missing' } : { value: text }
  })
  on('process.run', (_, e) => {
    const argv = (e as { argv: string[] }).argv.slice(1)
    calls.push(argv.join(' '))
    if (argv[0] === 'disable') codexOn = false
    const stdout =
      argv[0] === 'workers'
        ? `Workers\n  claude    on    ready\n  codex     ${codexOn ? 'on    ready' : 'off   (crewtier enable codex)'}\n`
        : argv[1] === 'json'
          ? JSON.stringify({ tiers: { 't1-easy': [{ backend: 'agy', model: 'a' }, { backend: 'codex', model: 'b' }] } })
          : 'ok'
    return { value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })

  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  // Presses start the CLI and return; let it land before the next look.
  const settle = async () => {
    for (let i = 0; i < 50; i++) await Promise.resolve()
  }
  await ui.press({ key: 'reload' })
  await settle()
  expect(await ui.find({ type: 'Text', text: 'quota-exhausted' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /weekly limit hit/ })).toBeDefined()
  await ui.press({ key: 'toggle-codex' })
  await settle()
  await ui.press({ key: 'up-t1-easy-2' })
  await settle()
  expect(calls).toContain('disable codex')
  expect(calls).toContain('routing move t1-easy 2 1 --lead claude')
  expect((await ui.find({ type: 'Text', text: 'codex' }))?.props.dimColor).toBe(true)
  expect(await ui.find({ type: 'Text', text: /1\/1 pass · ⌀ 1m30s/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /app D1/ })).toBeDefined()
  await ui.unmount()
})

test('parseHistory: pass rate and average time per worker, newest task first', () => {
  const h = parseHistory(
    'date\tworker\toutcome\tdiff_lines\trepo\ttask\ttier\nd1\tx/m\tpass\t5\tr\tD1\tt1\nd2\tx/m\tfail\t0\tr\tD2\tt1\n',
    'date\tworker\tseconds\nd1\tx/m\t60\nd2\tx/m\t120\n',
  )
  expect(h.stats['x/m']).toEqual({ runs: 2, pass: 1, seconds: 180, timed: 2 })
  expect(h.recent.map(t => t.task)).toEqual(['D2', 'D1'])
  expect([h.total, h.passed]).toEqual([2, 1])
})
