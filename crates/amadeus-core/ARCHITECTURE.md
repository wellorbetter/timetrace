# Amadeus Core MVP architecture

Amadeus is a persistent digital persona, not a TimeTrace feature.

## Memory boundary

- **Identity memory** is canonical pre-activation memory loaded from a versioned persona pack. Runtime code cannot append to it.
- **Lived memory** is post-activation experience owned by Amadeus, including computer episodes, conversations, relationship facts, preferences and reflections.
- **Working context** represents what is happening now and is not long-term memory until an episode closes and is consolidated.

## Runtime flow

```text
native computer observer
        ↓
PerceptionEvent
        ├── WorkingContext (immediate)
        ├── TriggerEngine (initiative)
        └── EpisodeBuilder
                ↓
        ComputerEpisode
                ↓
        EpisodeConsolidator
                ↓
        LivedMemoryStore
                ↓
        MemoryRetriever
                ↓
        ContextComposer
                ↓
        CognitionEngine
                ↓
        ModelRouter
```

## Skills and MCP

Skills describe capabilities and dependencies. MCP is one capability transport, not the agent itself. Remote MCP tools enter the registry conservatively as external-write risk until the host/user explicitly assigns a safer policy.

The MCP client targets protocol revision `2026-07-28` and places protocol/client metadata on each request. The transport is replaceable; the included modern stdio transport uses a fresh process per self-contained request for correctness before pooling/legacy negotiation is added.

## Evolution

Lived experience, persona state and skills can evolve through auditable candidates. Canonical identity is protected from silent runtime mutation.
