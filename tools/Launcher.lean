import Lean

open Lean System

namespace Launcher

def shellQuote (s : String) : String :=
  "'" ++ s.replace "'" "'\"'\"'" ++ "'"

/-- Only server launches need preparation; other commands go straight to elan. -/
def wrapper (root elanBin : FilePath) (command : String) : String := Id.run do
  let proxy := shellQuote (elanBin / command).toString
  let lean := shellQuote (elanBin / "lean").toString
  let script := shellQuote (root / "tools/Launcher.lean").toString
  let prepare := s!"--run {script} prepare {shellQuote root.toString}"
  let failure := " || { printf '%s\\n' \"$semantic_highlighting_library\" >&2; " ++
    "printf '%s\\n' 'Semantic highlighting unavailable; starting the ordinary Lean server.' >&2; " ++
    "semantic_highlighting_forward \"$@\"; }"
  let entry := if command == "lake" then "serve" else "--server"
  let server := if command == "lake" then "serve --" else "--server"
  return String.intercalate "\n" [
    "#!/bin/sh",
    "semantic_highlighting_toolchain=",
    "case \"${1-}\" in",
    "  +*) semantic_highlighting_toolchain=$1; shift ;;",
    "esac",
    "semantic_highlighting_forward() {",
    "  if [ -n \"$semantic_highlighting_toolchain\" ]; then",
    s!"    exec {proxy} \"$semantic_highlighting_toolchain\" \"$@\"",
    "  fi",
    s!"  exec {proxy} \"$@\"",
    "}",
    "if [ \"${1-}\" != " ++ shellQuote entry ++ " ]; then",
    "  semantic_highlighting_forward \"$@\"",
    "fi",
    "if [ -n \"$semantic_highlighting_toolchain\" ]; then",
    s!"  semantic_highlighting_library=$({lean} \"$semantic_highlighting_toolchain\" {prepare})" ++ failure,
    "else",
    s!"  semantic_highlighting_library=$({lean} {prepare})" ++ failure,
    "fi",
    "shift",
    if command == "lake" then "if [ \"${1-}\" = -- ]; then shift; fi" else ":",
    "if [ -n \"$semantic_highlighting_toolchain\" ]; then",
    s!"  exec {proxy} \"$semantic_highlighting_toolchain\" {server} \"--plugin=$semantic_highlighting_library\" \"$@\"",
    "fi",
    s!"exec {proxy} {server} \"--plugin=$semantic_highlighting_library\" \"$@\"",
    ""]

def install (root : FilePath) : IO Unit := do
  if Platform.isWindows then
    throw <| IO.userError "The automatic launcher currently requires Linux or macOS. Use `lake run vscode-settings --direct` on Windows."
  let elanHome ← match ← IO.getEnv "ELAN_HOME" with
    | some path => pure (FilePath.mk path)
    | none => do
      let some home ← IO.getEnv "HOME"
        | throw <| IO.userError "Cannot find elan: set ELAN_HOME"
      pure (FilePath.mk home / ".elan")
  let elanBin := elanHome / "bin"
  let bin := root / ".lake/launcher/bin"
  IO.FS.createDirAll bin
  for command in #["lean", "lake"] do
    unless ← (elanBin / command).pathExists do
      throw <| IO.userError s!"Elan proxy not found: {elanBin / command}"
    let path := bin / command
    IO.FS.writeFile path (wrapper root elanBin command)
    let result ← IO.Process.output { cmd := "chmod", args := #["+x", path.toString] }
    unless result.exitCode == 0 do throw <| IO.userError result.stderr
  IO.println <| Json.pretty <| Json.mkObj [
    ("lean4.envPathExtensions", toJson #[bin.toString]),
    ("editor.semanticHighlighting.enabled", toJson true)]

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

/-- Prepare an isolated build using the same Lean executable that is interpreting this file. -/
def prepare (root : FilePath) : IO FilePath := do
  let lean ← IO.FS.realPath (← IO.appPath)
  let some bin := lean.parent | throw <| IO.userError "Cannot find the active Lean toolchain"
  let lake := bin / "lake"
  let version ← checked lean #["--version"] root
  let commit ← checked lean #["--githash"] root
  let mut files := #[]
  for path in #["lakefile.lean", "SemanticHighlighting.lean", "SemanticHighlighting", "LICENSE"] do
    files := files ++ (← sourceFiles root path)
  let mut fingerprint := hash (lean.toString, version, commit)
  for (path, contents) in files do
    fingerprint := hash (fingerprint, path.toString, contents)
  let key := s!"{Lean.versionString}-{fingerprint}"
  let cacheRoot := root / ".lake/launcher/cache"
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

end Launcher

def main (args : List String) : IO UInt32 := do
  try
    match args with
    | ["install", root] => Launcher.install (← IO.FS.realPath root)
    | ["prepare", root] => IO.println (← Launcher.prepare (← IO.FS.realPath root))
    | _ => throw <| IO.userError "Usage: Launcher.lean (install|prepare) PLUGIN_ROOT"
    return 0
  catch error =>
    IO.eprintln s!"Semantic highlighting: {error}"
    return 1
