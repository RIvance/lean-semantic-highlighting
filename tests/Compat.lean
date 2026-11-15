import SemanticHighlighting.Compat

open Lean Lean.Lsp SemanticHighlighting.Compat

-- Dead branches deliberately contain unknown declarations: ordinary `if` cannot do this.
#if_decl Nat then
  example : Nat := 0
else
  example : Nat := unavailableInThisToolchain

#if_decl SemanticHighlighting.Compat.nonexistentFeature then
  example : Nat := unavailableInThisToolchain
else
  example : Nat := 0

namespace CompatTests

def token (start stop : Nat) (kind : SemanticTokenType) (priority := 5) : AbsoluteToken :=
  { pos := ⟨0, start⟩, tailPos := ⟨0, stop⟩, type := kind, priority }

def check (name : String) (input expected : Array AbsoluteToken) : IO Unit := do
  let actual := resolveOverlaps input
  let summarize := fun (tokens : Array AbsoluteToken) =>
    tokens.map fun t => (t.pos, t.tailPos, t.type.toNat, t.priority)
  unless summarize actual == summarize expected do
    throw <| IO.userError s!"{name}: unexpected resolved spans {repr (summarize actual)}"
  unless (encode actual).data.size == expected.size * 5 do
    throw <| IO.userError s!"{name}: invalid encoded token count"

end CompatTests

open CompatTests in
def main : IO Unit := do
    check "empty" #[] #[]
    check "semantic constructor overrides syntax fallback"
      #[token 2 6 .enumMember, token 2 6 .property 4]
      #[token 2 6 .enumMember]
    check "duplicate positions select the last classification"
      #[token 2 6 .type, token 2 6 .function]
      #[token 2 6 .function]
    check "nested spans resume the enclosing token"
      #[token 0 12 .string 3, token 3 7 .variable]
      #[token 0 3 .string 3, token 3 7 .variable, token 7 12 .string 3]
    check "crossing spans preserve both uncovered ends"
      #[token 0 8 .string 3, token 4 12 .variable]
      #[token 0 4 .string 3, token 4 12 .variable]
    check "equal priority selects the shorter span at the same start"
      #[token 0 4 .variable, token 0 8 .string]
      #[token 0 4 .variable, token 4 8 .string]
    check "equal priority selects the later start"
      #[token 0 8 .string, token 3 6 .variable]
      #[token 0 3 .string, token 3 6 .variable, token 6 8 .string]
    IO.println "PASS conditional compilation and token overlap adapters"
