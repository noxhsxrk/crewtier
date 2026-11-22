import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Run } from '../types'

const PANE = 'crewtier'
const runs = atom({ plugin: 'crewtier', key: 'runs' } as const, [], { shape: 'runs-1' })
const now = atom({ plugin: 'crewtier', key: 'now' } as const, 0)
const workers = atom({ plugin: 'crewtier', key: 'workers' } as const, '')

const DO = /\bcrewtier\s+do\s+(t\d-[\w-]+)/
// do.sh's report line: "<task> PASS ...", "<task> VERIFY-ERROR ...", "<task> <status> (last tier: ...)"
const REPORT = /^\S+ (PASS\b|VERIFY-ERROR\b|\S+ \(last tier).*$/m
const SUBCOMMANDS = ['health', 'workers', 'routing', 'status', 'doctor']

const plain = (text: string) => text.replace(/\x1b\[[0-9;?]*[A-Za-z]/g, '').trim()

export const report = (text: string): { outcome: 'pass' | 'fail'; line: string } => {
  const line = text.match(REPORT)?.[0] ?? plain(text).split('\n')[0] ?? ''
  return { outcome: / PASS\b/.test(line) ? 'pass' : 'fail', line }
}

export const elapsed = (ms: number) => {
  const s = Math.max(0, Math.round(ms / 1000))
  return s < 60 ? `${s}s` : `${Math.floor(s / 60)}m${s % 60}s`
}

async function crewtier($: EngineInterface, args: string[], timeoutMs = 60_000) {
  try {
    const { stdout, stderr } = await $.process.run(['crewtier', ...args], { timeoutMs })
    return plain(stdout || stderr) || '(no output)'
  } catch (err) {
    return `crewtier ${args.join(' ')} failed: ${String(err)}`
  }
}

export const register: Register = on => {
  let ticker: { cancel: () => void } | undefined

  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'crew',
      description: 'crewtier: open the pane, or run health | workers | routing | status | doctor',
    })
    // A reload drops the hook that was waiting on a run: don't leave it "running" forever.
    await update($, runs, all =>
      all.map(one => (one.outcome === 'running' ? { ...one, outcome: 'fail' as const, line: 'lost track (mod reloaded)' } : one)),
    )
    return next(e)
  })

  on('command.run', { command: 'crew' }, async ($, e) => {
    const sub = e.args.trim().split(/\s+/)[0] || 'pane'
    if (sub === 'pane') {
      const { isPlaced } = await $.ui.open({ id: PANE, title: 'crewtier' })
      if (!(await read($, workers))) void crewtier($, ['health', '--cached']).then(t => update($, workers, () => t))
      return { text: isPlaced ? 'crewtier pane opened.' : 'crewtier pane waits for a wider terminal.' }
    }
    if (!SUBCOMMANDS.includes(sub)) {
      return { text: `Usage: /crew [pane | ${SUBCOMMANDS.join(' | ')}]` }
    }
    // shortcut: subcommand only, no extra args (routing edits stay in the terminal), so nothing mutates config from here.
    return { text: await crewtier($, [sub], 180_000) }
  })

  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    const tier = e.command.match(DO)?.[1]
    if (!tier) return next(e)

    const run: Run = {
      id: e.tool_use_id ?? String(await $.clock.now()),
      tier,
      startedAt: await $.clock.now(),
      endedAt: null,
      outcome: 'running',
      line: '',
    }
    await update($, runs, list => [...list, run].slice(-50))
    await update($, now, () => run.startedAt)
    ticker ??= $.clock.every(5000, () => void $.clock.now().then(t => update($, now, () => t)))

    const ran = await next(e)
    const done = ran.deny !== undefined ? { outcome: 'fail' as const, line: `denied: ${ran.deny}` } : report(ran.text ?? '')
    const endedAt = await $.clock.now()
    const list = await update($, runs, all =>
      all.map(one => (one.id === run.id ? { ...one, ...done, endedAt } : one)),
    )
    if (!list.some(one => one.outcome === 'running')) {
      ticker?.cancel()
      ticker = undefined
    }
    $.ui.toast(`crewtier ${tier}: ${done.line || done.outcome}`, { timeoutMs: 8000 })

    return ran
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const active = (await read($, runs)).filter(one => one.outcome === 'running')
    if (e.props.hasSurvey || active.length === 0) return next(e)

    const { Box, Text } = $.ui.resolve(e)
    const t = await read($, now)

    return (
      <Box flexDirection="column">
        {active.map(one => (
          <Text color="yellow">
            ⚙ crewtier do {one.tier} · worker running · {elapsed(t - one.startedAt)}
          </Text>
        ))}
      </Box>
    )
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text, Button } = $.ui.resolve(e)
    const list = await read($, runs)
    const health = await read($, workers)

    return (
      <Box flexDirection="column">
        <Box>
          <Text bold>Workers </Text>
          <Button
            key="refresh"
            label="Refresh"
            onPress={async () => {
              await update($, workers, () => 'checking…')
              const text = await crewtier($, ['health'], 180_000)
              await update($, workers, () => text)
            }}
          />
        </Box>
        {(health || 'not checked yet').split('\n').map(line => (
          <Text dimColor={!health}>{line}</Text>
        ))}
        <Text> </Text>
        <Text bold>Delegated this session</Text>
        {list.length === 0 && <Text dimColor>Nothing delegated yet.</Text>}
        {list
          .slice()
          .reverse()
          .map(one => (
            <Text
              color={one.outcome === 'pass' ? 'green' : one.outcome === 'fail' ? 'red' : 'yellow'}
            >
              {one.outcome === 'running' ? '…' : one.outcome === 'pass' ? '✓' : '✗'} {one.tier}{' '}
              {one.line || 'running'}
            </Text>
          ))}
      </Box>
    )
  })
}
