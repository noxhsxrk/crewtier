export type Run = {
  id: string
  tier: string
  startedAt: number
  endedAt: number | null
  outcome: 'running' | 'pass' | 'fail'
  line: string
}

export type Health = { status: string; detail: string; at: number }
export type Stat = { runs: number; pass: number; seconds: number; timed: number }
export type Task = { date: string; repo: string; task: string; tier: string; worker: string; pass: boolean; lines: number }

export type Config = {
  workers: { name: string; on: boolean; status: string }[]
  // id is "<agent>/<model>", the key health and history use
  routing: Record<string, { backend: string; id: string; label: string }[]>
  health: Record<string, Health>
  stats: Record<string, Stat>
  recent: Task[]
  total: number
  passed: number
}

export type Delegation = 'on' | 'off'

declare module 'claude-code' {
  interface PluginState {
    crewtier: { runs: Shaped<Run[]>; now: number; workers: string; delegation: Delegation; config: Shaped<Config> }
  }
}
