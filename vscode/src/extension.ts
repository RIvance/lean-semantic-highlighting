import { dirname, join } from 'node:path'
import * as vscode from 'vscode'
import { addLauncherToPath, installLaunchers } from './launcher'
import type { LeanExports } from './leanApi'

export async function activate(context: vscode.ExtensionContext): Promise<void> {
  if (!vscode.workspace.isTrusted) return
  const output = vscode.window.createOutputChannel('Lean Semantic Highlighting')
  context.subscriptions.push(output)

  let disposed = false
  context.subscriptions.push(new vscode.Disposable(() => { disposed = true }))
  const report = (error: unknown) => {
    if (disposed) return
    output.appendLine(String(error))
    void vscode.window.showWarningMessage(
      'Lean Semantic Highlighting could not start. See its Output channel for details. Lean remains available.',
    )
  }
  try {
    const lean = vscode.extensions.getExtension<LeanExports>('leanprover.lean4')
    if (!lean) throw new Error('The official Lean 4 extension (leanprover.lean4) is required.')
    const api = await lean.activate()
    if (!api?.lean4EnabledFeatures) throw new Error('The Lean 4 extension does not expose the expected client API.')

    // Let the official extension finish toolchain setup first, without blocking
    // this extension's activation on its prompts.
    void api.lean4EnabledFeatures.then(async ({ clientProvider }) => {
      if (disposed) return
      const document = vscode.window.activeTextEditor?.document
      const cwd = document?.uri.scheme === 'file' && document.languageId === 'lean4'
        ? dirname(document.uri.fsPath) : vscode.workspace.workspaceFolders?.[0]?.uri.fsPath
      const bin = await installLaunchers(join(context.extensionPath, 'server'), context.globalStorageUri.fsPath, cwd)
      if (disposed) return
      const removeFromPath = addLauncherToPath(bin)
      context.subscriptions.push(new vscode.Disposable(removeFromPath))
      const restorePriority = () => { if (!disposed) addLauncherToPath(bin) }
      context.subscriptions.push(
        vscode.workspace.onDidChangeConfiguration(event => {
          if (event.affectsConfiguration('lean4.envPathExtensions')) restorePriority()
        }),
        vscode.workspace.onDidChangeWorkspaceFolders(restorePriority),
      )
      output.appendLine(`Highlighting launcher ready. Toolchain builds are cached in ${join(context.globalStorageUri.fsPath, 'cache')}.`)

      // Servers already starting/running need one restart to pick up the new PATH;
      // subsequent servers automatically use the launcher.
      for (const client of clientProvider.getClients()) {
        const restart = () => {
          const timer = setTimeout(() => {
            if (!disposed && client.isRunning()) void client.restart().catch(report)
          }, 0)
          context.subscriptions.push(new vscode.Disposable(() => clearTimeout(timer)))
        }
        if (client.isRunning()) restart()
        else {
          const subscription = client.restarted(() => {
            subscription.dispose()
            restart()
          })
          context.subscriptions.push(subscription)
        }
      }
    }).catch(report)
  } catch (error) {
    if (!disposed) report(error)
  }
}
