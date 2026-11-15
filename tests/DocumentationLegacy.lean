/-- Markdown with *bold*, `code`, and [a link](https://example.com). -/
def documented (x : Nat) := x.succ

/-!
A module comment with `inline code`.

```
def code := 1
```
-/
def afterComment := Nat
