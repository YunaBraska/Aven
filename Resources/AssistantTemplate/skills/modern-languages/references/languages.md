# Language guidance

## Java

Prefer the latest project-supported LTS, `final` values, records for transparent immutable data,
sealed types for useful exhaustive domains, pure functions, and explicit result types. Compose
reusable steps as functions or fluent railway-oriented flows rather than service layers whose only
job is forwarding. Use streams when they clarify a finite data transformation; use ordinary loops
when control flow is clearer. Prefer virtual threads for large numbers of blocking tasks, with
structured ownership and bounded external resources. Do not use parallel streams or reflection as
convenience. Public APIs need useful Javadocs. Sources: [Dev.java](https://dev.java/) and
[OpenJDK JEP Index](https://openjdk.org/jeps/).

## Kotlin

Use null-safe types, data and sealed classes, expression-oriented transformations, extension
functions with clear ownership, and coroutines with structured cancellation. Avoid `!!`, hidden
global scopes, clever operator overloads, and Java-shaped boilerplate. Keep blocking work off
coroutine dispatchers that expect non-blocking execution. Sources:
[Kotlin coding conventions](https://kotlinlang.org/docs/coding-conventions.html) and
[Kotlin coroutines guide](https://kotlinlang.org/docs/coroutines-guide.html).

## Go

Use `gofmt`, small concrete types, explicit error wrapping, and interfaces at consumer boundaries.
Pass `context.Context` across cancellable I/O, close resources, bound pagination and concurrency,
and ensure every goroutine has an exit path. Prefer straightforward control flow over framework
abstraction. Sources: [Go documentation](https://go.dev/doc/) and
[Effective Go](https://go.dev/doc/effective_go).

## Swift

Prefer value types, enums for explicit state, protocol use at actual boundaries, and native error
types. Use actors or isolation for shared mutable state; make `Sendable` and cancellation behavior
real rather than ceremonial. Respect platform lifecycle and use Swift Package Manager or the
project's Xcode setup. Sources: [Swift documentation](https://www.swift.org/documentation/) and
[Swift API design guidelines](https://www.swift.org/documentation/api-design-guidelines/).

## Rust

Let ownership express lifetime and concurrency. Use `Result`/`Option`, typed errors at boundaries,
iterators when clearer than mutation, and small traits where consumers require abstraction. Avoid
`unwrap`/`expect` on external input and minimize `unsafe`; every unsafe block needs a documented
invariant and focused tests. Run `rustfmt` and `clippy`. Sources:
[The Rust Programming Language](https://doc.rust-lang.org/book/) and
[Rust API Guidelines](https://rust-lang.github.io/api-guidelines/).
