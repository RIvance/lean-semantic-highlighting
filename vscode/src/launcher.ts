import { execFile } from 'node:child_process'
import { constants } from 'node:fs'
import { access } from 'node:fs/promises'
import { homedir } from 'node:os'
import { join, win32 } from 'node:path'
import { promisify } from 'node:util'

const exec = promisify(execFile)

/** Compile the bundled Lean entry point locally; the VSIX contains only sources. */
export async function installLaunchers(source: string, storage: string, cwd: string = homedir()): Promise<string> {
  const suffix = process.platform === 'win32' ? '.exe' : ''
  const elanBin = join(process.env.ELAN_HOME || join(homedir(), '.elan'), 'bin')
  const lean = join(elanBin, `lean${suffix}`)
  await Promise.all(['lean', 'lake'].map(command => access(join(elanBin, `${command}${suffix}`), constants.X_OK)))
  const env = { ...process.env }
  // Setup must resolve the workspace's toolchain without inheriting another
  // Lake project's search paths or compiler overrides from the editor's parent.
  for (const key of ['LEAN_PATH', 'LEAN_SRC_PATH', 'LEAN_SYSROOT', 'LAKE_HOME', 'LEAN', 'LAKE',
    'LEAN_AR', 'LEAN_CC', 'LEAN_GITHASH', 'LAKE_OVERRIDE_LEAN', 'LAKE_CACHE_DIR',
    'LD_LIBRARY_PATH', 'DYLD_LIBRARY_PATH']) delete env[key]
  const result = await exec(lean, ['--run', join(source, 'tools', 'Setup.lean'),
    'install-json', source, storage, elanBin], { cwd, env, windowsHide: true, maxBuffer: 8 * 1024 * 1024 })
  const bin: unknown = JSON.parse(result.stdout)
  if (typeof bin !== 'string') throw new Error('Lean setup did not return a launcher directory.')
  return bin
}

/** Windows environment keys and paths are case-insensitive. Consolidate PATH
 * aliases before spawning children, which otherwise can receive a stale Path. */
export function addLauncherToPath(bin: string, env: NodeJS.ProcessEnv = process.env,
  platform: NodeJS.Platform = process.platform): () => void {
  const windows = platform === 'win32'
  const separator = windows ? ';' : ':'
  const key = () => windows ? Object.keys(env).find(name => name.toUpperCase() === 'PATH') : undefined
  const entries = () => (env.PATH ?? env[key() ?? 'PATH'])?.split(separator) ?? []
  const normalize = (path: string) => windows ? win32.normalize(path).replace(/[\\/]+$/, '').toLowerCase() : path
  const withoutLauncher = () => entries().filter(entry => normalize(entry) !== normalize(bin))
  const set = (paths: string[]) => {
    if (windows) {
      for (const name of Object.keys(env)) if (name.toUpperCase() === 'PATH') delete env[name]
    }
    if (paths.length) env.PATH = paths.join(separator)
    else delete env.PATH
  }
  set([bin, ...withoutLauncher()])
  return () => set(withoutLauncher())
}
