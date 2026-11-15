import Lake
open Lake DSL

package consumer where
  plugins := #[`@«semantic-highlighting»/SemanticHighlighting:shared]

require «semantic-highlighting» from "../.."

@[default_target]
lean_lib Demo
