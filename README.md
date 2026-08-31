# Morax-utils

**A small, quiet set of Lua utilities for [nanos world](https://nanos-world.com/).**

Morax-utils borrows the shape of a few well-known Roblox utilities `Trove`, `Promise`, `Comm`, `BridgeNet`, `Component` and rebuilds them from the ground up against nanos world's own APIs (`Timer`, `Events`, `Entity`, `Character`).

📖 **Full documentation: [Morax Docs]([https://my-docs](https://morax-utils-docs.vercel.app))**

---

## Modules

| Module | What it does |
| --- | --- |
| **Cleaner** | Lifecycle & memory management tracks connections, timers, promises and any Destroy-able object, then tears them all down in one call. The nanos world sibling of Trove. |
| **Promise** | Async control flow a full Promise/A+-style implementation for Lua: chaining, cancellation, combinators, retries and timeouts, built for a single-threaded engine. |
| **Net** | Client / server communication namespaced remotes with Fire-and-forget and Invoke/response calls, middleware, batching and metrics, inspired by Comm and BridgeNet. |
| **Component** | Entity binding & lifecycle binds custom logic classes to tagged entities with an automatic Construct/Start/Stop lifecycle, extensions, ticking and networked properties. |

Every module is independent. Use `Cleaner` without `Net` or `Promise` on its own, they only lean on each other where it genuinely simplifies your code like `Net:Invoke()` returning a `Promise` or `Component` using `Cleaner` internally for its own bookkeeping.

## Installation

See the [installation guide](https://morax-utils-docs.vercel.app/docs/installation) on the docs site for the full setup, including Server/Client/Shared realm placement.

## Contributing

If you want to report me an error or suggest me a new module, come on the **nanos world** discord server and find me!

## License

[MIT](LICENSE)

---

<div align="center">
  <a href="https://nanos-world.com/">
    <img src="https://github.com/nanos-world.png" width="180" alt="nanos world logo" />
  </a>
  <p>
    Built for <a href="https://nanos-world.com/">nanos world</a>, the next-generation open-world multiplayer sandbox.<br />
    <a href="https://nanos-world.com/">Website</a> · <a href="https://docs.nanos-world.com/docs">Official docs</a> · <a href="https://github.com/nanos-world">GitHub</a> · <a href="https://store.steampowered.com/app/1841660/nanos_world/">Steam</a>
  </p>
</div>
