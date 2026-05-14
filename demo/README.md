# DMH-AI Demo Scenarios

This directory holds **deployment-side runbooks** — concrete,
operator-runnable scripts that exercise the DMH-AI primitives
against specific SME scenarios. It is deliberately separated from
the main codebase (`code/`):

- `code/` ships the **primitives** — generic, vendor-neutral
  building blocks (ingest pipelines, dispatcher, connectors,
  retrieval tools). The primitives are tested for correctness in
  isolation; they carry no DACH/SaaS-specific bias.
- `demo/` ships **scenarios** — opinionated compositions of those
  primitives for a particular customer story, market, or region.
  Operators read these as recipes: "I want my SME to do X — copy
  this folder, fill in my data, run the steps."

When a scenario reveals a missing primitive (something the recipe
needs but the primitive layer doesn't expose), file it as a task
against `code/` and build the primitive properly there. Do NOT
work around it in the demo folder.

## Structure

Demos are grouped by the **layer-0 primitive** they exercise.
Each primitive gets its own sub-folder:

```
demo/
├── README.md                  ← this file (folder convention)
├── layer-0.2/                 ← Document ingestion primitive
│   ├── README.md              ← scenario index + cross-cutting prereqs
│   ├── kb_handbook.md
│   ├── kb_docs_site.md
│   └── kb_sop_folder.md
├── layer-0.3/                 ← Typed connector library
│   └── (added once Caller real invocation lands — #371)
└── (more sub-folders per primitive as they reach demo-ready)
```

A scenario sits inside its layer's folder; cross-layer scenarios
get a `layer-X.Y_X.Z/` sub-folder (e.g. an inbox-triage demo that
composes 0.3 connectors + 0.4 approvals + 0.5 outbound). The
naming convention is `<primitive_slug>` for single-layer scenarios
and `<primitive_a>_<primitive_b>` for joined ones — never an
external SaaS name in the path (those go in the scenario's
narrative, not the directory layout).

## Reading a runbook

Each scenario file has the same shape:

1. **Who** — which SME persona this lands for (admin / employee / support / ops).
2. **Why** — the business pain it eases.
3. **Pre-requisites** — what's needed before the operator starts.
4. **Steps** — exact commands / clicks / prompts. Copy-paste-able.
5. **Verifying** — what the operator should see when it works.
6. **Cleanup** — undo / remove the demo data.
7. **Primitives exercised** — back-reference to layer-0 primitives
   so a reader following code → demo can find their way.
8. **Known gaps** — operator-experience friction the primitive
   doesn't paper over (e.g., container-absolute paths). Honest;
   not a workaround.

If a step references a primitive that doesn't behave as documented,
the primitive is the bug, not the runbook.
