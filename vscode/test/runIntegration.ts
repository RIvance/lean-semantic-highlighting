import { cp, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { exec, execFile } from 'node:child_process'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { promisify } from 'node:util'
import { downloadAndUnzipVSCode, resolveCliPathFromVSCodeExecutablePath, runTests } from '@vscode/test-electron'

async function main(): Promise<void> {
  const extensionDevelopmentPath = resolve(__dirname, '../..')
  const root = await mkdtemp(join(tmpdir(), "lean-vscode-test's "))
  try {
    const project = join(root, 'project')
    const extensions = join(root, 'extensions')
    const userData = join(root, 'user-data')
    await mkdir(project)
    await mkdir(extensions)
    await mkdir(join(userData, 'User'), { recursive: true })
    const pin = await readFile(join(extensionDevelopmentPath, '../lean-toolchain'), 'utf8')
    await writeFile(join(project, 'lean-toolchain'), pin)
    await writeFile(join(project, 'lakefile.toml'), 'name = "highlighting-test"\n')
    await writeFile(join(project, 'Demo.lean'), [
      'structure Box (α : Type) where',
      '  value : α',
      'class Renderable (α : Type) where',
      '  render : α → String',
      'def identityBox (x : Box Nat) : Box Nat := x',
      'def greeting := "😀"',
      'def empty : List Nat := .nil',
      '',
    ].join('\n'))
    await writeFile(join(userData, 'User/settings.json'), JSON.stringify({
      'lean4.infoview.autoOpen': false,
      'lean4.showSetupWarnings': false,
      'window.restoreWindows': 'none',
      'security.workspace.trust.enabled': false,
    }))
    // Copy only the official extension into the isolated test profile. No changes
    // to the user's installed extensions, settings, or open VS Code windows.
    const installedLean = process.env.LEAN4_EXTENSION_PATH
    if (installedLean) await cp(installedLean, join(extensions, 'leanprover.lean4'), { recursive: true })
    const vscodeExecutablePath = process.env.VSCODE_EXECUTABLE_PATH ?? await downloadAndUnzipVSCode()
    if (!installedLean) {
      const cli = resolveCliPathFromVSCodeExecutablePath(vscodeExecutablePath)
      const installArgs = ['--install-extension', 'leanprover.lean4']
      if (process.platform === 'win32') {
        // code.cmd locates its build's CLI. Pass paths through the environment so cmd preserves them.
        await promisify(exec)([
          '"%VSCODE_TEST_CLI%"', '--extensions-dir "%VSCODE_TEST_EXTENSIONS%"',
          '--user-data-dir "%VSCODE_TEST_USER_DATA%"', ...installArgs,
        ].join(' '), {
          env: {
            ...process.env,
            VSCODE_TEST_CLI: cli,
            VSCODE_TEST_EXTENSIONS: extensions,
            VSCODE_TEST_USER_DATA: userData,
          },
          timeout: 120_000,
        })
      } else {
        await promisify(execFile)(cli, ['--extensions-dir', extensions, '--user-data-dir', userData, ...installArgs],
          { timeout: 120_000 })
      }
    }
    await runTests({
      vscodeExecutablePath,
      extensionDevelopmentPath,
      extensionTestsPath: join(__dirname, 'integration.js'),
      extensionTestsEnv: { SEMANTIC_HIGHLIGHTING_TEST_PROJECT: project },
      launchArgs: [
        project,
        '--user-data-dir', userData,
        '--extensions-dir', extensions,
        '--disable-workspace-trust',
        '--skip-welcome',
        '--skip-release-notes',
        '--disable-gpu',
      ],
    })
  } finally {
    await rm(root, { recursive: true, force: true })
  }
}

void main().catch(error => { console.error(error); process.exitCode = 1 })
