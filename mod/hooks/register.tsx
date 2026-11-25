import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, RenderChildren } from 'claude-code'

import type { Config, Delegation, Run } from '../types'
import { ago, parseHealth, parseHistory, tone } from './board'

const PANE = 'crewtier'
const runs = atom({ plugin: 'crewtier', key: 'runs' } as const, [], { shape: 'runs-1' })
const now = atom({ plugin: 'crewtier', key: 'now' } as const, 0)
const workers = atom({ plugin: 'crewtier', key: 'workers' } as const, '')
const EMPTY: Config = { workers: [], routing: {}, health: {}, stats: {}, recent: [], total: 0, passed: 0 }
const config = atom({ plugin: 'crewtier', key: 'config' } as const, EMPTY, { shape: 'config-2' })
// The mod runs inside Claude Code, so it edits the claude lead's routing.
const LEAD = ['--lead', 'claude']

// Delegation switch; mirrored in $.store so it outlasts the session.
const delegation = atom({ plugin: 'crewtier', key: 'delegation' } as const, 'on' as Delegation)

const OFF_RULE = {
  id: 'crewtier:off',
  text: 'crewtier delegation is OFF (switched off in the crewtier band). Do all coding work yourself this session; do not run `crewtier do`, whatever the size of the task.',
  scope: 'session',
} as const

const DO = /\bcrewtier\s+do\s+(t\d-[\w-]+)/
// do.sh's report line: "<task> PASS ...", "<task> VERIFY-ERROR ...", "<task> <status> (last tier: ...)"
const REPORT = /^\S+ (PASS\b|VERIFY-ERROR\b|\S+ \(last tier).*$/m
const SUBCOMMANDS = ['health', 'workers', 'routing', 'status', 'doctor']
const SWITCHES = ['on', 'off']

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

// `crewtier workers` rows: "  codex     on    ready" or "  codex     off   (crewtier enable codex)".
export const parseWorkers = (text: string): Config['workers'] =>
  [...text.matchAll(/^\s+(\S+)\s+(on|off)\b[ \t]*(.*)$/gm)].map(([, name = '', state, rest = '']) => ({
    name,
    on: state === 'on',
    status: state === 'on' ? rest.trim() : '',
  }))

export const parseRouting = (json: string): Config['routing'] => {
  try {
    const tiers = (
      JSON.parse(json) as { tiers?: Record<string, { backend: string; model?: string; effort?: string }[]> }
    ).tiers
    const out: Config['routing'] = {}
    for (const [tier, list] of Object.entries(tiers ?? {})) {
      out[tier] = list.map(c => ({
        backend: c.backend,
        id: `${c.backend}/${c.model ?? 'default'}`,
        label: `${c.backend}/${c.model ?? 'default'}${c.effort ? `@${c.effort}` : ''}`,
      }))
    }
    return out
  } catch {
    return {}
  }
}

async function loadConfig($: EngineInterface) {
  // shortcut: crewtier keeps its state in ~/.crewtier with no override; read it there.
  const dir = `${await $.env.get('HOME')}/.crewtier`
  const file = (name: string) => $.fs.read(`${dir}/${name}`).catch(() => '')
  const [w, r, h, results, usage] = await Promise.all([
    crewtier($, ['workers']),
    crewtier($, ['routing', 'json', ...LEAD]),
    file('health.tsv'),
    file('results.tsv'),
    file('worker-usage.tsv'),
  ])
  await update($, config, () => ({
    workers: parseWorkers(w),
    routing: parseRouting(r),
    health: parseHealth(h),
    ...parseHistory(results, usage),
  }))
}

// A press gets 10s: start the command and return; the pane redraws when it lands.
function change($: EngineInterface, args: string[]) {
  void crewtier($, args, 30_000).then(async out => {
    $.ui.toast(out.split('\n')[0] ?? '', { timeoutMs: 5000 })
    await loadConfig($)
  })
}

async function openPane($: EngineInterface) {
  const { isPlaced } = await $.ui.open({ id: PANE, title: 'crewtier' })
  void loadConfig($)
  return isPlaced
}

async function checkHealth($: EngineInterface) {
  await update($, workers, () => 'checking…')
  void crewtier($, ['health'], 180_000).then(async text => {
    await update($, workers, () => text)
    await loadConfig($)
  })
}

async function setDelegation($: EngineInterface, value: Delegation) {
  await update($, delegation, () => value)
  await $.store.set('delegation', value)
}

export const register: Register = on => {
  let ticker: { cancel: () => void } | undefined

  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'crew',
      description: 'crewtier: open the pane, on | off delegation, or run health | workers | routing | status | doctor',
    })
    const saved = await $.store.get('delegation')
    await update($, delegation, () => (saved === 'off' ? 'off' : 'on'))
    // A reload drops the hook that was waiting on a run: don't leave it "running" forever.
    await update($, runs, all =>
      all.map(one =>
        one.outcome === 'running' ? { ...one, outcome: 'fail' as const, line: 'lost track (mod reloaded)' } : one,
      ),
    )
    return next(e)
  })

  on('command.run', { command: 'crew' }, async ($, e) => {
    const sub = e.args.trim().split(/\s+/)[0] || 'pane'
    if (sub === 'pane') {
      return { text: (await openPane($)) ? 'crewtier pane opened.' : 'crewtier pane waits for a wider terminal.' }
    }
    if (sub === 'on' || sub === 'off') {
      await setDelegation($, sub)
      return { text: `crewtier delegation ${sub}.` }
    }
    if (!SUBCOMMANDS.includes(sub)) {
      return { text: `Usage: /crew [pane | ${[...SWITCHES, ...SUBCOMMANDS].join(' | ')}]` }
    }
    // shortcut: subcommand only, no extra args (routing edits stay in the terminal), so nothing mutates config from here.
    return { text: await crewtier($, [sub], 180_000) }
  })

  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    const tier = e.command.match(DO)?.[1]
    if (!tier) return next(e)
    if ((await read($, delegation)) === 'off') {
      return { deny: 'crewtier delegation is off (crewtier band). Do this task yourself.' }
    }

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
    // The worker already ran: nothing below may throw, or the engine would skip this hook and run it again.
    try {
      const done =
        ran.deny !== undefined ? { outcome: 'fail' as const, line: `denied: ${ran.deny}` } : report(ran.text ?? '')
      const endedAt = await $.clock.now()
      const list = await update($, runs, all =>
        all.map(one => (one.id === run.id ? { ...one, ...done, endedAt } : one)),
      )
      if (!list.some(one => one.outcome === 'running')) {
        ticker?.cancel()
        ticker = undefined
      }
      $.ui.toast(`crewtier ${tier}: ${done.line || done.outcome}`, { timeoutMs: 8000 })
    } catch {}
    return ran
  })

  on('prompt.compose', async ($, e, next) => {
    const composed = await next(e)
    if ((await read($, delegation)) === 'on') return composed
    return { sections: [...composed.sections, OFF_RULE] }
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.props.hasSurvey) return next(e)
    // Other mods (ponytail) share this slot: draw theirs below ours.
    const below = await next(e).catch(() => undefined)

    const { Box, Text, Button } = $.ui.resolve(e)
    const mode = await read($, delegation)
    const list = await read($, runs)
    const t = await read($, now)
    const active = list.filter(one => one.outcome === 'running')
    const passed = list.filter(one => one.outcome === 'pass').length
    const failed = list.filter(one => one.outcome === 'fail').length
    const width = e.surface === 'terminal' ? e.props.bodyColumns : undefined

    const row = (
      <Box flexDirection="row" alignItems="center" gap={1} width={width}>
        <Text dimColor>crewtier</Text>
        {(['off', 'on'] as const).map(value => (
          <Button
            key={`mode-${value}`}
            label={value}
            {...(value === mode ? { variant: 'primary' as const } : { plain: true as const, dimColor: true })}
            onPress={() => setDelegation($, value)}
          />
        ))}
        {active.map(one => (
          <Text key={one.id} color="yellow">
            ⚙ {one.tier} {elapsed(t - one.startedAt)}
          </Text>
        ))}
        {list.length > 0 && (
          <Text dimColor>
            {list.length} delegated · {passed} ✓ · {failed} ✗
          </Text>
        )}
        <Box flexGrow={1} />
        <Button key="board" plain label="Board" onPress={() => void openPane($)} />
        <Button key="health" plain label="Health" onPress={() => void openPane($).then(() => checkHealth($))} />
      </Box>
    )
    return below ? (
      <Box flexDirection="column">
        {row}
        {below}
      </Box>
    ) : (
      row
    )
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text, Button } = $.ui.resolve(e)
    const list = await read($, runs)
    const checking = (await read($, workers)) === 'checking…'
    const mode = await read($, delegation)
    const c = await read($, config)
    const t = await $.clock.now()
    const off = new Set(c.workers.filter(a => !a.on).map(a => a.name))
    const width = e.surface === 'terminal' ? e.props.bodyColumns : undefined
    const healthOf = (id: string, agent: string) => c.health[id] ?? c.health[agent]
    const ready = c.workers.filter(a => a.on && c.health[a.name]?.status === 'ready').length
    const limited = c.workers.filter(a => a.on && tone(c.health[a.name]?.status) === 'warning').length
    const broken = c.workers.filter(a => a.on && tone(c.health[a.name]?.status) === 'error').length
    const record = (id: string) => {
      const s = c.stats[id]
      if (!s) return ''
      const avg = s.timed ? ` · ⌀ ${elapsed((s.seconds / s.timed) * 1000)}` : ''
      return `${s.pass}/${s.runs} pass${avg}`
    }
    const dot = (status: string | undefined, isOff: boolean) => (
      <Text color={isOff ? 'inactive' : tone(status)}>{isOff ? '○' : '●'}</Text>
    )
    const card = (key: string, title: string, note: string, body: RenderChildren, actions?: RenderChildren) => (
      <Box key={key} flexDirection="column" borderStyle="round" borderDimColor paddingX={1} width={width}>
        <Box gap={1}>
          <Text bold color="claude">
            {title}
          </Text>
          <Text dimColor wrap="truncate-end">
            {note}
          </Text>
          <Box flexGrow={1} />
          {actions}
        </Box>
        {body}
      </Box>
    )

    const header = (
      <Box key="header" gap={2} paddingX={1} width={width}>
        <Text bold>crewtier</Text>
        <Text>
          delegation <Text color={mode === 'on' ? 'success' : 'inactive'}>● {mode}</Text>
        </Text>
        <Text color="success">{ready} ready</Text>
        {limited > 0 && <Text color="warning">{limited} limited</Text>}
        {broken > 0 && <Text color="error">{broken} failing</Text>}
        {off.size > 0 && <Text dimColor>{off.size} off</Text>}
        <Box flexGrow={1} />
        <Button
          key="health"
          plain
          label={checking ? 'Checking…' : 'Check health'}
          onPress={() => (checking ? undefined : checkHealth($))}
        />
        <Button key="reload" plain label="Reload" onPress={() => void loadConfig($)} />
      </Box>
    )

    const workerRows =
      c.workers.length === 0 ? (
        <Text dimColor>No workers found. Is the crewtier CLI installed?</Text>
      ) : (
        c.workers.map(a => {
          const hl = c.health[a.name]
          const isOff = !a.on
          return (
            <Box key={`w-${a.name}`} flexDirection="column">
              <Box gap={1}>
                <Button
                  key={`toggle-${a.name}`}
                  label={a.on ? ' on' : 'off'}
                  {...(a.on ? { variant: 'primary' as const } : { plain: true as const, dimColor: true })}
                  onPress={() => change($, [a.on ? 'disable' : 'enable', a.name])}
                />
                {dot(hl?.status, isOff)}
                <Box width={14}>
                  <Text bold={!isOff} dimColor={isOff}>
                    {a.name}
                  </Text>
                </Box>
                <Box width={17}>
                  <Text color={isOff ? 'inactive' : tone(hl?.status)}>
                    {isOff ? 'off' : (hl?.status ?? 'not checked')}
                  </Text>
                </Box>
                <Text dimColor>{hl ? ago(t - hl.at) : ''}</Text>
              </Box>
              {!isOff && hl && hl.status !== 'ready' && hl.detail && (
                <Box paddingLeft={8}>
                  <Text dimColor wrap="truncate-end">
                    └ {hl.detail}
                  </Text>
                </Box>
              )}
            </Box>
          )
        })
      )

    const routingRows = Object.entries(c.routing).map(([tier, models]) => (
      <Box key={`t-${tier}`} flexDirection="column">
        <Text color="suggestion">{tier}</Text>
        {models.map((m, i) => {
          const isOff = off.has(m.backend)
          return (
            <Box key={`r-${tier}-${i}`} gap={1}>
              <Text dimColor>{`  ${i + 1}`}</Text>
              <Button
                key={`up-${tier}-${i + 1}`}
                plain
                label="↑"
                dimColor={i === 0}
                onPress={() => i > 0 && change($, ['routing', 'move', tier, String(i + 1), String(i), ...LEAD])}
              />
              <Button
                key={`down-${tier}-${i + 1}`}
                plain
                label="↓"
                dimColor={i === models.length - 1}
                onPress={() =>
                  i < models.length - 1 && change($, ['routing', 'move', tier, String(i + 1), String(i + 2), ...LEAD])
                }
              />
              {dot(healthOf(m.id, m.backend)?.status, isOff)}
              <Box width={36}>
                <Text dimColor={isOff} strikethrough={isOff} wrap="truncate-end">
                  {m.label}
                </Text>
              </Box>
              <Text dimColor>{record(m.id)}</Text>
            </Box>
          )
        })}
      </Box>
    ))

    const history = c.recent.map((task, i) => (
      <Box key={`h-${i}`} gap={1}>
        <Text color={task.pass ? 'success' : 'error'}>{task.pass ? '✓' : '✗'}</Text>
        <Box width={11}>
          <Text dimColor>{task.date}</Text>
        </Box>
        <Box width={22}>
          <Text wrap="truncate-end">
            {task.repo} {task.task}
          </Text>
        </Box>
        <Box width={10}>
          <Text color="suggestion">{task.tier}</Text>
        </Box>
        <Text dimColor wrap="truncate-end">
          {task.worker === '-' ? 'no worker ran' : `${task.worker} · ${task.lines} lines`}
        </Text>
      </Box>
    ))

    const session =
      list.length === 0 ? (
        <Text dimColor>Nothing delegated yet.</Text>
      ) : (
        list
          .slice()
          .reverse()
          .map(one => (
            <Box key={`s-${one.id}`} gap={1}>
              <Text color={one.outcome === 'pass' ? 'success' : one.outcome === 'fail' ? 'error' : 'warning'}>
                {one.outcome === 'running' ? '…' : one.outcome === 'pass' ? '✓' : '✗'}
              </Text>
              <Text color="suggestion">{one.tier}</Text>
              <Text dimColor wrap="truncate-end">
                {one.outcome === 'running' ? `running · ${elapsed(t - one.startedAt)}` : one.line}
              </Text>
            </Box>
          ))
      )

    const rate = c.total ? Math.round((c.passed / c.total) * 100) : 0
    return (
      <Box flexDirection="column">
        {header}
        {card('workers', 'Workers', 'on/off · health', workerRows)}
        {card('routing', 'Routing', 'tried top to bottom · ↑↓ reorder', routingRows)}
        {card('history', 'History', c.total ? `${c.total} tasks · ${rate}% pass` : 'no tasks yet', history)}
        {card('session', 'This session', `${list.length} delegated`, session)}
      </Box>
    )
  })
}
