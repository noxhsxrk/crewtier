import { expect, test } from 'claude-code/testing'

import { report } from '../hooks/register'

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
  const row = await ui.find({ type: 'Text', text: /t2-normal/ })
  expect(row?.text).toBe('✓ t2-normal D1 PASS codex/gpt-6 · 350 lines (4 files) · 2m10s')
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
