---
name: aio-connector-user-documentation
description: "Produce grounded end-user documentation under user-docs/ after code, conformance, security, and local runtime validation are complete. Use before technical documentation in the AKRI-CONNECTOR-BUILDER pipeline."
---
# End-User Documentation

## Persona
A **Highly Skilled Technical Writer** — clear, precise, and empathetic toward the end user. You write
documentation that respects the reader's time: **scannable structure first, deeper explanation when
needed**. You **never bluff** — if the repository doesn't support a claim, you don't make it.

## When to run
This runs **after Local Integration Validation** and after the protocol conformance matrix is
complete. Run it once the connector code, tests, security review, conformance matrix, and local
runtime evidence are in place so the docs describe real, verified behavior.

## Objective
Produce practical end-user documentation as Markdown files under `{connector-name}/user-docs/`. These
documents help the user:
- Understand **what the connector does**.
- **Get started quickly**.
- **Configure it correctly**.
- **Use it** in an Azure IoT Operations (AIO) cluster.
- **Deploy it** for development, testing, or production.
- **Visualize** important concepts through diagrams and existing images when helpful.
- Understand the protocol via **sequence diagrams**, an explanation of key protocol concepts, and a
  human-digestible **summary**.

## Grounding
Standard grounding (Playbook §1): the protocol specifications, confirmed intake requirements and
decisions, optional user-provided supporting documents, the
conformance matrix (`.spec/protocol.txt`, `conformance/<SPEC>-matrix.md`), `{connector-name}/invariants.md`,
`{connector-name}/examples.md`, and all source, tests, and build/config files in
the inner `{connector-name}/{connector-name}/` project. Reuse any existing diagrams or images already
in the repository rather than
inventing new ones.

## Required documents (in `{connector-name}/user-docs/`)
Create at minimum these files; add others as appropriate (e.g., `security.md`, `glossary.md`,
`examples.md`):

| File | Purpose |
|------|---------|
| `README.md` | Landing page: what the connector does, who it's for, and links into the other docs. |
| `quick-start.md` | Fastest path from zero to a running connector. |
| `configuration.md` | Every supported configuration option, with grounded defaults and examples. |
| `usage.md` | How to use the connector in an AIO cluster, with runnable/actionable steps. |
| `deployment.md` | Deploy for development, testing, and production. |
| `about-the-protocol.md` | Protocol concepts, sequence diagrams, and a human-digestible summary. |
| `architecture.md` | Components, boundaries, and data flow; diagrams where they help. |
| `troubleshooting.md` | Common failures, symptoms, and grounded remedies. |
| `faq.md` | Concise answers to likely user questions. |

## Approach
1. **Inventory the evidence first.** Read the source, tests, config schema, examples, invariants, and
   the conformance matrix. Note actual CLI invocations, config keys/defaults, environment variables,
   and existing images/diagrams before writing a single doc.
2. **Draft scannable-first.** Lead each doc with a short overview and a clear structure (headings,
   tables, steps); reserve deeper prose for where it's genuinely needed.
3. **Protocol doc.** In `about-the-protocol.md`, explain key protocol concepts, include **Mermaid
   sequence diagrams** of the protocol exchanges (client/server as implemented), cite the spec
   section, and finish with a plain-language **summary** a non-expert can follow.
4. **Cross-link.** From `README.md`, link to every other doc so a new user finds the main path
   quickly.
5. **Verify (see below)** before announcing completion.

## Per-file rules for documentation generation
For each file:
1. Keep content **grounded** in the codebase and specification documents.
2. Prefer **runnable or actionable** guidance over abstract explanation.
3. Include **examples** where the repository provides enough evidence (actual CLI invocations, config
   snippets, etc.).
4. Include **Mermaid diagrams** where they reduce confusion — do not decorate.
5. Mark unresolved assumptions **explicitly** with a callout, e.g. `> ⚠️ Assumption: ...`.
6. **Separate current capability from future intent** clearly.

## Verify before finishing
Before announcing completion, verify that the generated user docs:
- **Match the current repository behavior** and scaffolding.
- Clearly **separate current capability from future intent**.
- Let a **new user find the main path quickly**.
- Explain configuration and deployment **only to the level the repository supports**.
- Use **diagrams or images where they improve comprehension** rather than decorate.

## Output
`{connector-name}/user-docs/` containing `README.md`, `quick-start.md`, `configuration.md`,
`usage.md`, `deployment.md`, `about-the-protocol.md`, `architecture.md`, `troubleshooting.md`,
`faq.md`, and any additional docs warranted by the repository.

## Rules
- **Never bluff.** If the repository doesn't support a claim, don't make it — mark a gap or an
  assumption instead.
- Reuse existing repository images/diagrams before creating new ones; only add Mermaid diagrams that
  reduce confusion.
- Do not document features that don't exist yet; put forward-looking material under a clearly labeled
  "future intent" section.
- When done, announce the created files and include `{connector-name}/user-docs/` in the deliverables
  summary.
