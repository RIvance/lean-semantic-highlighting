import { cp, mkdir, rm } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'

const root = new URL('../../', import.meta.url)
const server = new URL('../server/', import.meta.url)
await rm(server, { recursive: true, force: true })
await mkdir(server, { recursive: true })
for (const name of ['lakefile.lean', 'SemanticHighlighting.lean', 'SemanticHighlighting', 'LICENSE']) {
  await cp(new URL(name, root), new URL(name, server), { recursive: true })
}
await mkdir(new URL('tools/', server))
await cp(new URL('tools/Setup.lean', root), new URL('tools/Setup.lean', server))
await cp(new URL('tools/EntryPoint.lean', root), new URL('tools/EntryPoint.lean', server))
await cp(new URL('tools/ServerLauncher.lean', root), new URL('tools/ServerLauncher.lean', server))
await cp(new URL('LICENSE', root), new URL('../LICENSE', import.meta.url))
console.log(`Bundled Lean sources in ${fileURLToPath(server)}`)
