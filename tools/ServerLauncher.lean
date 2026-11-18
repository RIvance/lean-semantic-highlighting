import Lean

open Lean System

/-! Server script interpreted by the project's selected Lean toolchain.
Preparation and server launches use Lean's process API without a shell. -/

/-- Lean 4.24–4.35's Windows process API quotes arguments but does not double
backslashes next to a quote or at the end. Complete that encoding before spawn.
Keep this helper in both standalone scripts so neither needs prebuilt imports. -/
private def windowsArgument (arg : String) : String := Id.run do
  let mut result := ""
  let mut slashes := 0
  for c in arg.toList do
    if c == '\\' then
      slashes := slashes + 1
    else
      let count := if c == '"' then 2 * slashes else slashes
      result := (result ++ String.intercalate "" (List.replicate count "\\")).push c
      slashes := 0
  return result ++ String.intercalate "" (List.replicate (2 * slashes) "\\")

private def processArgs (args : Array String) : Array String :=
  if Platform.isWindows then args.map windowsArgument else args


private def preparePlugin (lean : FilePath) (source cache : String) : IO FilePath := do
  -- Use the interpreter's exact executable, so a toolchain change during a build
  -- cannot produce a library for a different server. Capture all builder output:
  -- compiler diagnostics must never enter the LSP stream on stdout.
  let result ← IO.Process.output {
    cmd := lean.toString,
    args := processArgs #["--run", (FilePath.mk source / "tools/Setup.lean").toString,
      "prepare-json", source, cache] }
  IO.eprint result.stderr
  unless result.exitCode == 0 do
    throw <| IO.userError s!"Plugin preparation failed:\n{result.stdout}"
  let library : String ← IO.ofExcept <| Json.parse result.stdout >>= fromJson?
  let path := FilePath.mk library
  unless ← path.pathExists do
    throw <| IO.userError s!"Built plugin does not exist: {path}"
  return path

def main (args : List String) : IO UInt32 := do
  let command :: source :: cache :: args := args
    | throw <| IO.userError "Usage: ServerLauncher.lean (lean|lake) SOURCE CACHE SERVER_ARGS..."
  unless command == "lean" || command == "lake" do
    throw <| IO.userError s!"Unknown launcher command: {command}"
  let lean ← IO.FS.realPath (← IO.appPath)
  let some bin := lean.parent | throw <| IO.userError "Cannot locate the active Lean toolchain"
  let executable := if command == "lean" then lean
    else bin / (if Platform.isWindows then "lake.exe" else "lake")
  let original := args.toArray
  let serverArgs ← try
    let library ← preparePlugin lean source cache
    let tail := args.drop 1
    if command == "lake" then
      let tail := if tail.head? == some "--" then tail.drop 1 else tail
      pure <| #["serve", "--", s!"--plugin={library}"] ++ tail.toArray
    else
      pure <| #["--server", s!"--plugin={library}"] ++ tail.toArray
  catch error =>
    IO.eprintln s!"Semantic highlighting unavailable; starting the ordinary Lean server.\n{error}"
    pure original
  let server ← IO.Process.spawn { cmd := executable.toString, args := processArgs serverArgs }
  server.wait
