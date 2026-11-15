-- Inferred type aliases are highlighted as types, even when written with `def`.

universe u

/--
A *homogeneous sequence*; {lean}`List Nat` is an example.
Use {lit}`[]` for an empty sequence.
-/
def Items (α : Type u) := List α
abbrev Predicate (α : Type u) := α → Prop

-- Recursive structures and typeclasses have distinct categories.

structure Tree (α : Type u) where
  value : α
  children : List (Tree α)

/-- Turn values into _readable text_, such as {lean}`"ready"`. -/
class Renderable (α : Type u) where
  render : α → String

-- Constructors keep their identity, even with dot notation.

inductive Signal where
  | stop
  | go

def signals : Items Signal := .cons .go (.cons .stop .nil)

-- Functions, binders, local uses, and projection fields.

def leaf (α : Type u) (x : α) : Tree α := ⟨x, []⟩

def summary [Renderable α] (tree : Tree α) : String :=
  Renderable.render tree.value

-- Proposition families are distinct from types and term definitions.

/-- A *nonempty* sequence, as in {lean}`[1, 2] ≠ ([] : List Nat)`. -/
def NonemptyItems (xs : Items α) : Prop := xs ≠ []

theorem prepend_nonempty (x : α) (xs : Items α) : NonemptyItems (.cons x xs) := by
  intro h
  cases h

-- Proof hypotheses stay variables, including quantified propositions.

theorem transport (p q : Prop) (hp : p) (step : p → q) : q := step hp
theorem specialize (h : ∀ p : Prop, p → p) : True := h True True.intro

-- Unicode notation and subscripted names remain easy to follow.

/-- Swap the entries of a *pair*, written with the product notation {lit}`×`. -/
def swapPair (p₁ : α × β) : β × α := (p₁.2, p₁.1)

theorem larger_nonzero (n₀ : Nat) : ∃ n₁, n₀ ≤ n₁ ∧ n₁ ≠ 0 :=
  ⟨n₀ + 1, Nat.le_succ n₀, Nat.succ_ne_zero n₀⟩

-- Sort keywords are highlighted separately from their universe levels.

def SortAlias := Sort (u + 1)
