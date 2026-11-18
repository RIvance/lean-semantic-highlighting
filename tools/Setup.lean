import Lean

open Lean System

namespace Setup

partial def sourceFiles (root : FilePath) (path : FilePath) : IO (Array (FilePath × ByteArray)) := do
  if ← (root / path).isDir then
    let entries ← (root / path).readDir
    let entries := entries.toList.mergeSort (fun a b => a.fileName <= b.fileName)
    let mut files := #[]
    for entry in entries do
      unless entry.fileName == ".lake" do
        files := files ++ (← sourceFiles root (path / entry.fileName))
    return files
  return #[(path, ← IO.FS.readBinFile (root / path))]

/-- A build must not inherit another project's Lake paths or compiler overrides. -/
def buildEnv : Array (String × Option String) :=
  #["LEAN_PATH", "LEAN_SRC_PATH", "LEAN_SYSROOT", "LAKE_HOME", "LEAN", "LAKE",
    "LEAN_AR", "LEAN_CC", "LEAN_GITHASH", "LAKE_OVERRIDE_LEAN", "LAKE_CACHE_DIR",
    "LD_LIBRARY_PATH", "DYLD_LIBRARY_PATH"].map (·, none)

def checked (command : FilePath) (args : Array String) (cwd : FilePath) : IO String := do
  let result ← IO.Process.output { cmd := command.toString, args, cwd := some cwd, env := buildEnv }
  unless result.exitCode == 0 do
    throw <| IO.userError s!"{command} {args} failed:\n{result.stdout}{result.stderr}"
  return result.stdout

/-- Build editor entry points from Lean source using the installed toolchain.
The immutable installation is shared by the CLI and VS Code extension. -/
def install (root storage elanBin : FilePath) : IO FilePath := do
  let lean ← IO.FS.realPath (← IO.appPath)
  let some toolchainBin := lean.parent | throw <| IO.userError "Cannot find the active Lean toolchain"
  let suffix := if Platform.isWindows then ".exe" else ""
  for command in #["lean", "lake"] do
    unless ← (elanBin / (command ++ suffix)).pathExists do
      throw <| IO.userError s!"Elan proxy not found: {elanBin / (command ++ suffix)}"
  let version ← checked lean #["--version"] root
  let commit ← checked lean #["--githash"] root
  let source ← IO.FS.readBinFile (root / "tools/EntryPoint.lean")
  let installer ← IO.FS.readBinFile (root / "tools/Setup.lean")
  let key := toString <| hash (lean.toString, version, commit, source, installer,
    root.toString, storage.toString, elanBin.toString)
  let parent := storage / "launchers"
  let bin := parent / key
  IO.FS.createDirAll parent
  let lock ← IO.FS.Handle.mk (parent / s!"{key}.lock") .append
  lock.lock
  try
    if ← (bin / "ready").pathExists then
      if (← (bin / ("lean" ++ suffix)).pathExists) && (← (bin / ("lake" ++ suffix)).pathExists) then
        return bin
    IO.eprintln "Semantic highlighting: compiling the Lean launcher"
    let staging := parent / s!"{key}.tmp"
    if ← staging.pathExists then IO.FS.removeDirAll staging
    IO.FS.createDirAll staging
    try
      let generated := staging / "EntryPoint.c"
      discard <| checked lean #["-c", generated.toString, (root / "tools/EntryPoint.lean").toString] root
      let executable := staging / ("lean" ++ suffix)
      discard <| checked (toolchainBin / ("leanc" ++ suffix))
        #["-O2", "-o", executable.toString, generated.toString] root
      IO.FS.removeFile generated
      let lake := staging / ("lake" ++ suffix)
      IO.FS.writeBinFile lake (← IO.FS.readBinFile executable)
      unless Platform.isWindows do
        IO.setAccessRights lake {
          user := { read := true, write := true, execution := true },
          group := { read := true, execution := true },
          other := { read := true, execution := true } }
      -- Separate text files retain paths verbatim, including spaces and newlines,
      -- without pulling a JSON parser into the small compiled entry point.
      IO.FS.writeFile (staging / "elan-bin") elanBin.toString
      IO.FS.writeFile (staging / "source") root.toString
      IO.FS.writeFile (staging / "cache") (storage / "cache").toString
      IO.FS.writeFile (staging / "ready") ""
      if ← bin.pathExists then IO.FS.removeDirAll bin
      IO.FS.rename staging bin
      return bin
    finally
      if ← staging.pathExists then IO.FS.removeDirAll staging
  finally
    lock.unlock

def installSettings (root : FilePath) : IO Unit := do
  let elanHome ← match ← IO.getEnv "ELAN_HOME" with
    | some path => pure (FilePath.mk path)
    | none => do
      let home ← IO.getEnv (if Platform.isWindows then "USERPROFILE" else "HOME")
      let some home := home | throw <| IO.userError "Cannot find elan: set ELAN_HOME"
      pure (FilePath.mk home / ".elan")
  let bin ← install root (root / ".lake/launcher") (elanHome / "bin")
  IO.println <| Json.pretty <| Json.mkObj [
    ("lean4.envPathExtensions", toJson #[bin.toString]),
    ("editor.semanticHighlighting.enabled", toJson true)]

/-- Prepare an isolated build using the same Lean executable that is interpreting this file. -/
def prepare (root : FilePath) (cacheRoot? : Option FilePath := none) : IO FilePath := do
  let lean ← IO.FS.realPath (← IO.appPath)
  let some bin := lean.parent | throw <| IO.userError "Cannot find the active Lean toolchain"
  let lake := bin / (if Platform.isWindows then "lake.exe" else "lake")
  let version ← checked lean #["--version"] root
  let commit ← checked lean #["--githash"] root
  let mut files := #[]
  for path in #["lakefile.lean", "SemanticHighlighting.lean", "SemanticHighlighting", "LICENSE"] do
    files := files ++ (← sourceFiles root path)
  let mut fingerprint := hash (lean.toString, version, commit)
  for (path, contents) in files do
    fingerprint := hash (fingerprint, path.toString, contents)
  let key := s!"{Lean.versionString}-{fingerprint}"
  -- An editor extension may have a read-only installation directory. Keep its builds
  -- in editor-managed storage while retaining the CLI launcher's existing default.
  let cacheRoot := cacheRoot?.getD (root / ".lake/launcher/cache")
  IO.FS.createDirAll cacheRoot
  let lock ← IO.FS.Handle.mk (cacheRoot / s!"{key}.lock") .append
  lock.lock
  try
    let cache := cacheRoot / key
    let ready := cache / "plugin.json"
    if ← ready.pathExists then
      if let .ok metadata := Json.parse (← IO.FS.readFile ready) then
        if let .ok path := metadata.getObjValAs? String "library" then
          if ← (FilePath.mk path).pathExists then return path
    IO.eprintln s!"Semantic highlighting: building for Lean {Lean.versionString}"
    IO.FS.createDirAll cache
    for (path, contents) in files do
      let target := cache / path
      if let some parent := target.parent then IO.FS.createDirAll parent
      IO.FS.writeBinFile target contents
    -- Lake is invoked directly from the active toolchain; the project and source pins stay untouched.
    discard <| checked lake #["build", "SemanticHighlighting:shared"] cache
    let output ← checked lake #["run", "plugin-path", "--json"] cache
    let library : String ← IO.ofExcept <| Json.parse output >>= fromJson?
    unless ← (FilePath.mk library).pathExists do
      throw <| IO.userError s!"Built plugin not found: {library}"
    IO.FS.writeFile ready <| Json.compress <| Json.mkObj [
      ("library", toJson library), ("lean", toJson lean.toString),
      ("version", toJson Lean.versionString), ("commit", toJson commit)]
    return library
  finally
    lock.unlock

end Setup

def main (args : List String) : IO UInt32 := do
  try
    match args with
    | ["install", root] => Setup.installSettings (← IO.FS.realPath root)
    | ["install-json", root, storage, elanBin] =>
      IO.println <| (toJson (← Setup.install (← IO.FS.realPath root) storage elanBin).toString).compress
    | ["prepare-json", root, cache] =>
      IO.println <| (toJson (← Setup.prepare (← IO.FS.realPath root) (some cache)).toString).compress
    | ["prepare", root] => IO.println (← Setup.prepare (← IO.FS.realPath root))
    | ["prepare", root, cache] =>
      IO.println (← Setup.prepare (← IO.FS.realPath root) (some cache))
    | _ => throw <| IO.userError "Usage: Setup.lean install PLUGIN_ROOT | install-json PLUGIN_ROOT STORAGE ELAN_BIN | prepare PLUGIN_ROOT [CACHE_ROOT] | prepare-json PLUGIN_ROOT CACHE_ROOT"
    return 0
  catch error =>
    IO.eprintln s!"Semantic highlighting: {error}"
    return 1
