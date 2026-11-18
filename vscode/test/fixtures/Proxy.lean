import Lean.Data.Json

private partial def echoInput : IO Unit := do
  let bytes ← (← IO.getStdin).read 65536
  unless bytes.isEmpty do
    (← IO.getStdout).write bytes
    (← IO.getStdout).flush
    echoInput

def main (args : List String) : IO UInt32 := do
  if let some code ← IO.getEnv "TEST_EXIT" then return code.toNat!.toUInt32
  if (← IO.getEnv "TEST_ECHO").isSome then
    IO.eprintln "proxy stderr"
    echoInput
  else if (← IO.getEnv "TEST_WAIT").isSome then
    IO.println (← IO.Process.getPID)
    (← IO.getStdout).flush
    -- A language server must observe EOF when the editor closes its input.
    discard <| (← IO.getStdin).readToEnd
  else
    IO.println (Lean.toJson args).compress
  return 0
