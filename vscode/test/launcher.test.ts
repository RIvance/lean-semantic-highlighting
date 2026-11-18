import assert from 'node:assert/strict'
import { execFile, spawn } from 'node:child_process'
import { copyFile, cp, link, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { homedir, tmpdir } from 'node:os'
import { delimiter, join, resolve } from 'node:path'
import { test } from 'node:test'
import { promisify } from 'node:util'
import { addLauncherToPath, installLaunchers } from '../src/launcher'

const exec = promisify(execFile)

test('PATH registration and cleanup preserve subsequent changes', () => {
  const env: NodeJS.ProcessEnv = { PATH: ['/usr/bin', '/bin'].join(delimiter), EXISTING: 'before' }
  const restore = addLauncherToPath('/launcher', env)
  addLauncherToPath('/launcher', env)
  assert.equal(env.PATH, ['/launcher', '/usr/bin', '/bin'].join(delimiter))
  env.PATH = `/other${delimiter}${env.PATH}`
  restore()
  assert.equal(env.PATH, ['/other', '/usr/bin', '/bin'].join(delimiter))

})

test('Windows PATH aliases, separators, and case-insensitive directory names', () => {
  const env: NodeJS.ProcessEnv = { Path: 'C:\\Windows;C:\\tools' }
  const restore = addLauncherToPath('C:\\Launcher', env, 'win32')
  assert.deepEqual(env, { PATH: 'C:\\Launcher;C:\\Windows;C:\\tools' })
  addLauncherToPath('c:/launcher/', env, 'win32')
  assert.equal(env.PATH, 'c:/launcher/;C:\\Windows;C:\\tools')
  restore()
  assert.equal(env.PATH, 'C:\\Windows;C:\\tools')
})

test('Lean sources compile locally and preserve arguments, streams, exits, and server EOF', { timeout: 120_000 }, async () => {
  const root = await mkdtemp(join(tmpdir(), "lean highlighting's 測試 "))
  try {
    const suffix = process.platform === 'win32' ? '.exe' : ''
    const project = resolve(__dirname, '../../..')
    const elanBin = join(process.env.ELAN_HOME || join(homedir(), '.elan'), 'bin')
    const realLean = join(elanBin, `lean${suffix}`)
    const source = join(root, 'extension & % !', 'server')
    await cp(resolve(__dirname, '../../server'), source, { recursive: true })
    const storage = join(root, 'storage')
    const installs = await Promise.all([
      installLaunchers(source, storage, project), installLaunchers(source, storage, project),
    ])
    const bin = installs[0]!
    assert.equal(installs[1], bin, 'Concurrent installs share a completed directory')
    const originalBytes = await readFile(join(bin, `lean${suffix}`))
    assert.equal(await installLaunchers(source, storage, project), bin)
    assert.deepEqual(await readFile(join(bin, `lean${suffix}`)), originalBytes)

    // Build a Lean fixture with the same toolchain, then point this test's entry
    // points at it. The installed extension needs no fixtures or native binaries.
    const prefix = (await exec(realLean, ['--print-prefix'], { cwd: project })).stdout.trim()
    const fixtureSource = join(root, 'Proxy.lean')
    await copyFile(resolve(__dirname, '../../test/fixtures/Proxy.lean'), fixtureSource)
    await exec(join(prefix, 'bin', `lean${suffix}`), ['-c', join(root, 'Proxy.c'), fixtureSource], { cwd: root })
    const proxies = join(root, 'elan home', 'bin')
    await mkdir(proxies, { recursive: true })
    await exec(join(prefix, 'bin', `leanc${suffix}`), ['-O2', '-o', join(proxies, `lean${suffix}`), join(root, 'Proxy.c')], { cwd: root })
    await link(join(proxies, `lean${suffix}`), join(proxies, `lake${suffix}`))
    await writeFile(join(bin, 'elan-bin'), proxies)

    // No shell, Node executable, or system tools can be found through this PATH.
    const env = { ...process.env, PATH: '' }
    const unusual = ['space here', "a 'quoted' argument", '"double quotes"', '', '$() `literal` & % !', '測試😀', 'C:\\ends with slash\\']
    unusual.push('\\' + '"', '\\\\' + '"')
    for (const command of ['lean', 'lake']) {
      const wrapper = join(bin, `${command}${suffix}`)
      for (const args of [[], ['--version'], ['+leanprover/lean4:v4.24.0', 'build', ...unusual]]) {
        const result = await exec(wrapper, args, { env })
        assert.deepEqual(JSON.parse(result.stdout), args)
      }
      for (const override of [[], ['+leanprover/lean4:v4.24.0']]) {
        const args = [...(command === 'lake' ? ['serve', '--'] : ['--server']), ...unusual]
        const result = await exec(wrapper, [...override, ...args], { env })
        assert.deepEqual(JSON.parse(result.stdout), [...override, '--run', join(source, 'tools', 'ServerLauncher.lean'),
          command, source, join(storage, 'cache'), ...args])
      }
      const request = exec(wrapper, command === 'lake' ? ['serve'] : ['--server'], { env: { ...env, TEST_ECHO: '1' } })
      const input = 'Content-Length: 16\r\n\r\n{"text":"😀"}'
      request.child.stdin!.end(input)
      const echoed = await request
      assert.equal(echoed.stdout, input)
      assert.equal(echoed.stderr.replaceAll('\r\n', '\n'), 'proxy stderr\n')
      await assert.rejects(exec(wrapper, ['--version'], { env: { ...env, TEST_EXIT: '37' } }), { code: 37 })
      await assert.rejects(exec(wrapper, command === 'lake' ? ['serve'] : ['--server'], { env: { ...env, TEST_EXIT: '37' } }), { code: 37 })
    }

    const child = spawn(join(bin, `lean${suffix}`), ['--server'], { env: { ...env, TEST_WAIT: '1' }, stdio: ['pipe', 'pipe', 'pipe'] })
    const exited = new Promise<void>((resolve, reject) => {
      child.on('error', reject)
      child.on('close', () => resolve())
    })
    try {
      const pid = await new Promise<number>((resolve, reject) => {
        child.on('error', reject)
        child.stdout.once('data', data => resolve(Number(String(data).trim())))
      })
      assert.ok(Number.isInteger(pid) && pid > 0)
      child.stdin.end()
      await exited
      assert.throws(() => process.kill(pid, 0), 'Closing the editor input must stop the server and launcher')
    } finally { child.kill() }
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})
