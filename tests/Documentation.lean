import Lean.Elab.DocString
set_option doc.verso true
set_option doc.verso.suggestions false

/--
*Bold* and _emphasis_, {lit}`literal`, $`x + y`, [a link][url], and a note[^n].

[url]: https://example.com
[^n]: Footnote.

```lean -error +show
def fromDoc := 1
```

{given (type := "Nat") -typeIsMeta +show}`k` and {lean}`k.succ`
-/
def documented (x : Nat) := x.succ

set_option doc.verso false
/-- Markdown with *bold*, `code`, and [a link](https://example.com). -/
def markdown := 0
