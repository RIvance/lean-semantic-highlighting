/-! Regression cases for classification, token ranges, and Unicode. -/

def dotNotation (x : Nat) := x.succ
def dottedConstructor (x : Nat) : List Nat := .cons (x |>.succ) .nil
theorem withLocalLet (x : Nat) : True :=
  let y := x.succ
  .intro

universe u
def TypeAlias := Type
  0
def SortAlias := Sort (u + 1)
abbrev NatAlias := Nat
def InferredList (α : Type) := List α
def ExplicitList (α : Type) : Type := InferredList α
def singletonNat (x : NatAlias) : ExplicitList NatAlias := [x]

structure RecursiveStruct where
  xs : List RecursiveStruct
class RecursiveClass (α : Type) where
  xs : List (RecursiveClass α)

theorem withHypotheses (p q : Prop) (h1 : p ∧ q) (h2 : p → q)
    (h3 : ∀ x : Nat, x = x) : q ∧ 0 = 0 :=
  ⟨h2 h1.1, h3 0⟩
theorem withPolymorphicHypothesis (h : ∀ p : Prop, p → p) (f : ∀ α : Type, α → α) :
    f Nat 0 = f Nat 0 :=
  h _ rfl

inductive Data where
  | item
inductive Pred : Nat → Prop where
  | zero : Pred 0
axiom termAxiom : Nat
opaque termOpaque : Nat := 0
def field (s : RecursiveStruct) := s.xs
def utf16 (α : Type) (x : α) := let «😀» := x; «😀»
def unfinished : Nat := sorry
example : Sort (max u 1 + 1) := Sort (max u 1)
