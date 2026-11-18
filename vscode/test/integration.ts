import assert from 'node:assert/strict'
import { access, appendFile, cp, mkdtemp, readFile, readdir, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import * as vscode from 'vscode'
import { addLauncherToPath, installLaunchers } from '../src/launcher'

interface TestClient {
  isRunning(): boolean
  sendRequest(method: string, params: unknown): Promise<unknown>
  restart(): Promise<void>
}

interface TestLeanApi {
  lean4EnabledFeatures: Promise<{ clientProvider: { getClients(): TestClient[] } }>
}

async function eventually<T>(check: () => Promise<T | undefined>, description: string): Promise<T> {
  const deadline = Date.now() + 180_000
  let lastError: unknown
  while (Date.now() < deadline) {
    try {
      const result = await check()
      if (result !== undefined) return result
    } catch (error) { lastError = error }
    await new Promise(resolve => setTimeout(resolve, 250))
  }
  throw new Error(`Timed out: ${description}. Last error: ${String(lastError)}`)
}

async function classifications(document: vscode.TextDocument): Promise<Map<string, Set<string>> | undefined> {
  const [legend, tokens] = await Promise.all([
    vscode.commands.executeCommand<vscode.SemanticTokensLegend>('vscode.provideDocumentSemanticTokensLegend', document.uri),
    vscode.commands.executeCommand<vscode.SemanticTokens>('vscode.provideDocumentSemanticTokens', document.uri),
  ])
  if (!legend || !tokens) return undefined
  const result = new Map<string, Set<string>>()
  let line = 0
  let column = 0
  for (let i = 0; i < tokens.data.length; i += 5) {
    const delta = tokens.data[i]!
    line += delta
    column = (delta === 0 ? column : 0) + tokens.data[i + 1]!
    const length = tokens.data[i + 2]!
    const text = document.lineAt(line).text.slice(column, column + length)
    const kind = legend.tokenTypes[tokens.data[i + 3]!]!
    const kinds = result.get(text) ?? new Set<string>()
    kinds.add(kind)
    result.set(text, kinds)
  }
  return result
}

export async function run(): Promise<void> {
  const project = process.env.SEMANTIC_HIGHLIGHTING_TEST_PROJECT!
  const pathBefore = process.env.PATH
  const lakefile = await readFile(join(project, 'lakefile.toml'), 'utf8')
  const pin = await readFile(join(project, 'lean-toolchain'), 'utf8')
  const settingsBefore = JSON.stringify(vscode.workspace.getConfiguration('lean4').inspect('envPathExtensions'))
  const argsBefore = JSON.stringify(vscode.workspace.getConfiguration('lean4').inspect('serverArgs'))
  const document = await vscode.workspace.openTextDocument(join(project, 'Demo.lean'))
  const editor = await vscode.window.showTextDocument(document)
  const extension = vscode.extensions.getExtension('lean4-ide-tools.lean-semantic-highlighting')!
  assert.ok(extension, 'Development extension was discovered')
  assert.deepEqual(extension.packageJSON.extensionDependencies, ['leanprover.lean4'])
  await extension.activate()
  const lean = vscode.extensions.getExtension<TestLeanApi>('leanprover.lean4')!
  assert.ok(lean.isActive, 'Official Lean extension is active')
  const api = await lean.activate()
  const { clientProvider } = await api.lean4EnabledFeatures

  const expected = { Box: 'struct', Renderable: 'interface', identityBox: 'function', Type: 'class', nil: 'enumMember' }
  const assertHighlighting = async () => eventually(async () => {
    const kinds = await classifications(document)
    if (!kinds) return undefined
    for (const [name, kind] of Object.entries(expected)) {
      if (!kinds.get(name)?.has(kind)) return undefined
    }
    return true
  }, 'enhanced classifications through the official semantic token provider')
  await assertHighlighting()
  console.log('PASS VS Code activation, official extension dependency, and semantic tokens')

  // Exercise unsaved edits through the real client, with UTF-16 positions after emoji.
  await editor.edit(edit => edit.insert(new vscode.Position(document.lineCount - 1, 0),
    'def wrapped := let emoji := "😀"; (⟨emoji.length⟩ : Box Nat)\n'))
  await eventually(async () => {
    const kinds = await classifications(document)
    return kinds?.get('wrapped')?.has('function') && kinds.get('Box')?.has('struct') ? true : undefined
  }, 'updated highlighting after an unsaved edit')
  const clients = clientProvider.getClients()
  assert.equal(clients.length, 1, 'One official language server; no additional server')
  await clients[0]!.sendRequest('textDocument/waitForDiagnostics', { uri: document.uri.toString(), version: document.version })
  assert.deepEqual(vscode.languages.getDiagnostics(document.uri).filter(d => d.severity === vscode.DiagnosticSeverity.Error), [])
  await clients[0]!.restart()
  await assertHighlighting()
  console.log('PASS unsaved edits and official server restart')

  const hover = await eventually(async () => {
    const hovers = await vscode.commands.executeCommand<vscode.Hover[]>(
      'vscode.executeHoverProvider', document.uri, new vscode.Position(4, 5),
    )
    return hovers?.length ? hovers : undefined
  }, 'official hover provider remains functional')
  assert.ok(hover.length)
  assert.equal(await readFile(join(project, 'lakefile.toml'), 'utf8'), lakefile)
  assert.equal(await readFile(join(project, 'lean-toolchain'), 'utf8'), pin)
  assert.equal(JSON.stringify(vscode.workspace.getConfiguration('lean4').inspect('envPathExtensions')), settingsBefore)
  assert.equal(JSON.stringify(vscode.workspace.getConfiguration('lean4').inspect('serverArgs')), argsBefore)
  await assert.rejects(access(join(project, '.vscode')))
  assert.equal((await readdir(join(extension.extensionPath, 'server'))).includes('.lake'), false, 'Bundled sources remain read-only')
  assert.notEqual(process.env.PATH, pathBefore, 'Launcher is scoped to this extension host')
  console.log('PASS official hover, unchanged project/settings, and external build cache')

  // A failure in the interpreted builder must stay on stderr and fall back to a
  // usable stock server, without accidentally reusing a previous plugin library.
  const brokenSource = await mkdtemp(join(tmpdir(), "broken highlighting's "))
  let restorePath: (() => void) | undefined
  try {
    await cp(join(extension.extensionPath, 'server'), brokenSource, { recursive: true })
    await appendFile(join(brokenSource, 'SemanticHighlighting.lean'), '\ninvalid_highlighting_build_test\n')
    const bin = await installLaunchers(brokenSource, join(brokenSource, 'storage'), project)
    restorePath = addLauncherToPath(bin)
    await clients[0]!.restart()
    await clients[0]!.sendRequest('textDocument/waitForDiagnostics', { uri: document.uri.toString(), version: document.version })
    const stock = await classifications(document)
    assert.ok(stock, 'Fallback still supplies semantic tokens')
    assert.equal(stock.get('Box')?.has('struct') ?? false, false, 'Did not load a stale classifier')
    const fallbackHover = await vscode.commands.executeCommand<vscode.Hover[]>(
      'vscode.executeHoverProvider', document.uri, new vscode.Position(4, 5),
    )
    assert.ok(fallbackHover?.length, 'Fallback server still answers ordinary LSP requests')
    console.log('PASS Lean script build failure falls back without corrupting the LSP stream')
  } finally {
    restorePath?.()
    await clients[0]!.restart()
    await assertHighlighting()
    await rm(brokenSource, { recursive: true, force: true })
  }
}
