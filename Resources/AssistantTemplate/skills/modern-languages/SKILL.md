---
name: modern-languages
description: Implement or review modern Java, Kotlin, Go, Swift, or Rust using the repository's current toolchain and language-native composition patterns.
---

# Modern Languages

Detect the language, compiler/runtime version, build system, local instructions, and established
style first. Load only the matching section of [language guidance](references/languages.md). The
repository contract wins over these defaults.

Across languages, prefer explicit data and results, immutable values, small composable operations,
structured cancellation, and one owner for side effects. Keep public boundaries documented and
tested. Avoid framework layers, conversion rituals, mutable service graphs, reflection, unsafe
escapes, and concurrency without a measured reason.

Use the newest stable or LTS language level supported by the project and its deployment environment;
never raise that baseline silently. Verify current language capabilities against the official links
in the reference before adopting a recently introduced feature.
