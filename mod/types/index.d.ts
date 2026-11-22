export type Run = {
  id: string
  tier: string
  startedAt: number
  endedAt: number | null
  outcome: 'running' | 'pass' | 'fail'
  line: string
}

declare module 'claude-code' {
  interface PluginState {
    crewtier: { runs: Shaped<Run[]>; now: number; workers: string }
  }
}
