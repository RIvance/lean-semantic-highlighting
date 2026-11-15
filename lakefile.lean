import Lake
open Lake DSL

package «semantic-highlighting» where
  license := "MIT"

@[default_target]
lean_lib SemanticHighlighting where
  defaultFacets := #[LeanLib.sharedFacet]

@[test_driver]
script test do
  let build ← IO.Process.spawn { cmd := "lake", args := #["build"] }
  let code ← build.wait
  if code != 0 then return code
  for file in #["tests/Compat.lean", "tests/Main.lean"] do
    let tests ← IO.Process.spawn {
      cmd := "lake", args := #["env", "lean", "--run", file] }
    let code ← tests.wait
    if code != 0 then return code
  return 0

/-- Print the native plugin path for this toolchain and platform. -/
script «plugin-path» (args) do
  unless args.isEmpty || args == ["--json"] do
    throw <| IO.userError "Usage: lake run plugin-path [--json]"
  let some lib ← findLeanLib? `SemanticHighlighting
    | throw <| IO.userError "SemanticHighlighting library not found"
  let path ← IO.FS.realPath lib.sharedLibFile
  IO.println <| if args.isEmpty then path.toString else (Lean.toJson path.toString).compress
  return 0

/-- Generate automatic VS Code setup, or a fixed native library path with `--direct`. -/
script «vscode-settings» (args) do
  if args.isEmpty then
    let root ← IO.FS.realPath (← getRootPackage).dir
    let proc ← IO.Process.spawn {
      cmd := (← getLean).toString,
      args := #["--run", (root / "tools/Launcher.lean").toString, "install", root.toString] }
    return ← proc.wait
  unless args == ["--direct"] do
    throw <| IO.userError "Usage: lake run vscode-settings [--direct]"
  let build ← IO.Process.output {
    cmd := "lake", args := #["build", "SemanticHighlighting:shared"] }
  if build.exitCode != 0 then
    IO.eprint (build.stdout ++ build.stderr)
    return build.exitCode
  let some lib ← findLeanLib? `SemanticHighlighting
    | throw <| IO.userError "SemanticHighlighting library not found"
  let path ← IO.FS.realPath lib.sharedLibFile
  IO.eprintln s!"VS Code settings for Lean {Lean.versionString}. Use only with this toolchain."
  IO.println <| Lean.Json.pretty <| Lean.Json.mkObj [
    ("lean4.serverArgs", Lean.toJson #[s!"--plugin={path}"]),
    ("editor.semanticHighlighting.enabled", Lean.toJson true)]
  return 0

/-- Test clean copies with the installed stable toolchains, or an explicit release list. -/
script «test-matrix» (args) do
  let proc ← IO.Process.spawn {
    cmd := "lake", args := #["env", "lean", "--run", "tests/Matrix.lean"] ++ args.toArray }
  proc.wait
