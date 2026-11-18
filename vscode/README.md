# Lean Semantic Highlighting

This extension works with the official Lean 4 extension to color identifiers according to their meaning. For example, in `tree.value` Lean recognizes `tree` as a local variable and `value` as a structure field. Your theme can give them different colors.

## Installation

Use VS Code on Windows, macOS, or Linux with elan and your project's Lean toolchain installed. For SSH, WSL, or a dev container, install the extension and Lean in the remote environment.

1. Download the `vscode-extension` artifact from a successful GitHub Actions run and unzip it.
2. In VS Code, run **Extensions: Install from VSIX…** and select the extracted `.vsix` file. VS Code also installs the official Lean 4 extension if needed.
3. Open a Lean file in a trusted workspace. The first time you use a Lean toolchain, the extension builds the highlighting plugin for that version. Later sessions reuse the build.

If you previously enabled this plugin through Lake or VS Code settings, remove its Lake `plugins` entry, its `--plugin` argument in `lean4.serverArgs`, or its launcher directory in `lean4.envPathExtensions` before using the extension.

## Colors

Semantic highlighting is enabled by default for Lean files. To give structures, typeclasses, and constructors distinct colors, add these rules to your VS Code settings.

```json
{
  "editor.semanticTokenColorCustomizations": {
    "rules": {
      "struct:lean4": "#6ACD9B",
      "interface:lean4": "#68C5D0",
      "enumMember:lean4": "#F7ADAD"
    }
  }
}
```

The `:lean4` suffix limits a rule to Lean files. Use these token names to customize other categories.

| Entity | Token |
| --- | --- |
| `Type`, `Sort`, `Prop` | `class` |
| Local type parameters | `typeParameter` |
| Typeclasses | `interface` |
| Structures | `struct` |
| Propositions and proposition families | `enum` |
| Datatypes, aliases, and type families | `type` |
| Constructors | `enumMember` |
| Projection fields and functions | `property` |
| Term definitions, theorems, axioms, recursors | `function` |
| Local term binders | `parameter` |
| Local term uses and proof hypotheses | `variable` |

## Troubleshooting

If different identifiers still look alike, check that `editor.semanticHighlighting.enabled` is enabled for Lean. Some themes use the same color for several token types. Try the rules above to make the difference visible.

If setup fails, open **View > Output** and select **Lean Semantic Highlighting**. The **Lean 4** output channel shows errors from building the plugin with your project's toolchain.

## License

[MIT](LICENSE)
