import Init.System.IO

open System

/-! Compiled locally by `Setup.lean` as `lean` and `lake`. The official editor
extension starts these names directly, so this small entry point selects elan's
interpreter for the server script. No prebuilt executable is distributed. -/

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


def main (args : List String) : IO UInt32 := do
  let executable ← IO.appPath
  let some bin := executable.parent | throw <| IO.userError "Cannot locate launcher configuration"
  let command := if executable.fileName == some "lake" || executable.fileName == some "lake.exe"
    then "lake" else "lean"
  let suffix := if Platform.isWindows then ".exe" else ""
  let elanBin := FilePath.mk (← IO.FS.readFile (bin / "elan-bin"))
  let (override, rest) := match args with
    | first :: tail => if first.startsWith "+" then (#[first], tail) else (#[], args)
    | [] => (#[], [])
  let server := rest.head? == some (if command == "lake" then "serve" else "--server")
  unless server do
    let child ← IO.Process.spawn { cmd := (elanBin / (command ++ suffix)).toString, args := processArgs args.toArray }
    return ← child.wait

  let source ← IO.FS.readFile (bin / "source")
  let cache ← IO.FS.readFile (bin / "cache")
  let child ← IO.Process.spawn {
    cmd := (elanBin / ("lean" ++ suffix)).toString,
    args := processArgs (override ++ #["--run", (FilePath.mk source / "tools/ServerLauncher.lean").toString,
      command, source, cache] ++ rest.toArray) }
  -- Inherit the editor's streams directly. Lean handles LSP shutdown and EOF;
  -- no shell or additional stream/protocol implementation sits between them.
  child.wait
