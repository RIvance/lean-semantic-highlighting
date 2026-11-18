import type { Event } from 'vscode'

// Structural subset of leanprover.lean4's exports. Keep this boundary small: the
// official extension owns all LSP clients, semantic token providers, and UI.
// https://github.com/leanprover/vscode-lean4/blob/master/vscode-lean4/src/exports.ts
export interface LeanClient {
  isRunning(): boolean
  restart(): Promise<void>
  restarted: Event<unknown>
}

export interface LeanFeatures {
  clientProvider: { getClients(): LeanClient[] }
}

export interface LeanExports {
  lean4EnabledFeatures: Promise<LeanFeatures>
}
