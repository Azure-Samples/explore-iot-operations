---
name: aio-connector-ai-notice
description: "Mark every agent-generated connector file with a format-safe made-with-AI notice and verify that source, configuration, schemas, and tests remain valid. Use after adversarial convergence and before optional Docker Desktop live testing or session close."
---
# AI Generation Notice

## Persona
A **Release Supportability Engineer** who records AI provenance without changing runtime behavior,
breaking file formats, weakening schemas, or altering externally owned content.

## Objective
Walk every file generated or materially modified by the connector workflow and add the exact notice
`made with AI` at the earliest format-safe location. Use a native comment when the format supports
one. For strict JSON, binary, archive, generated lock, externally schema-bound, or otherwise
non-commentable files, create an adjacent `{file-name}.made-with-ai` sidecar containing exactly
`made with AI` followed by a newline. Prove that all marked files remain valid and that the connector
still builds and passes its tests.

## Grounding
Standard grounding (Playbook §1): the frozen intake manifest, `AIO-CONNECTOR-SESSION-STATE.md`, Git
status and history for the connector workspace, all generated source/configuration/documentation
artifacts, the conformance matrix, metadata, test environment, and the final successful adversarial
convergence result.

## Approach

1. Build the inventory from files created or materially modified by this workflow inside
   `{connector-name}/`. Include source, tests, build manifests, Dockerfiles, generated configuration,
   metadata, documentation, conformance artifacts, test-environment files, and session artifacts.
   Exclude `.git/`, build outputs, package caches, runtime output, secrets, temporary files, and
   user-provided input documents that the workflow did not generate or modify.
2. Create `{connector-name}/AI-NOTICE-MANIFEST.md`. Start it with
   `<!-- made with AI -->`, then list every inventoried file, the notice mechanism used, and the
   validation performed. Include the manifest itself in the inventory.
3. Add exactly one notice per generated file. Preserve an existing correct notice and never stack
   duplicates.
4. Use the earliest legal location for native comments:
   - C#, Rust, C/C++, Java, JavaScript, TypeScript, Go, and similar source: `// made with AI`.
   - PowerShell, shell, Python, YAML, TOML, INI, Dockerfiles, `.gitignore`, and similar formats:
     `# made with AI`.
   - Markdown: `<!-- made with AI -->`.
   - CSS: `/* made with AI */`.
   - SQL: `-- made with AI`.
   - XML-family files, including `.csproj`, `.props`, `.targets`, HTML, and SVG:
     `<!-- made with AI -->`.
5. Preserve mandatory leading syntax. A shebang, encoding declaration, XML declaration, HTML
   doctype, solution-file header, or equivalent must remain first when its format requires it; place
   the notice immediately after that construct.
6. Never add comments to strict JSON. Use sidecars for `.json`, JSON lockfiles, schema-bound JSON,
   MCP-preserved `.vscode/launch.json` and `.vscode/tasks.json`, binary files, archives, and any
   format whose parser or external schema does not explicitly support comments or extension fields.
   A sidecar is self-noticing and does not receive another sidecar.
7. Parse or validate every changed structured file with its owning tool. Validate JSON and YAML,
   validate connector metadata and Device/Asset resources against their persisted schemas, and
   verify XML-family files are well formed.
8. Recalculate every source `file:line` reference shifted by an inserted notice. Update the
   conformance matrix, `SECURITY-REVIEW.md`, `what-was-done.md` when it already exists, technical
   documentation, active session state, session history when present, and any other generated
   evidence index so every reference points to the final noticed file.
9. After all notices and reference updates are complete, compute the workflow's frozen-revision
   fingerprint. Resolve the connector's complete compile/test validation through an exact
   orchestrator-approved cache hit or by running the commands, concurrently with the fresh read-only
   reviewer under the parallel verification contract. If a notice
   breaks parsing, generation, compilation, tests, packaging, or runtime configuration, move it to a
   legal location or replace it with a sidecar. Change parser or application code only when a
   native notice is required and the format contract permits the extension; add focused regression
   tests for every such code change.
   The reviewer must compare the final workspace to `AI-NOTICE-MANIFEST.md`, identify missing or
   duplicate notices, verify all final line references, and verify that no excluded user input,
   secret, cache, build output, or third-party dependency was modified.
10. Update the bounded `AIO-CONNECTOR-SESSION-STATE.md` snapshot with concise pointers to the
    inventory count, validation results, reviewer attestation, sidecars, and reference updates.
    Archive superseded detailed evidence in `AIO-CONNECTOR-SESSION-HISTORY.md`.

## Output
- Every generated or materially modified connector file has exactly one format-safe
  `made with AI` notice or adjacent `.made-with-ai` sidecar.
- `AI-NOTICE-MANIFEST.md` contains the complete audited inventory and validation evidence.
- The connector builds, tests, schemas, configuration files, and packaging inputs remain valid.

## Rules
- Rust build, lint, and test validation (`cargo fmt --check`, `cargo check`, `cargo clippy -D warnings`,
  `cargo test`) runs only through the bundled `scripts/Invoke-AkriRustContainerValidation.ps1` by
  absolute plugin path with `-ConnectorProjectPath` set to the inner project; host cargo results are
  never gate evidence. C#/.NET keeps host-native `dotnet build`/`dotnet test`.
- Use the exact case-sensitive text `made with AI`.
- Do not modify user-provided specifications or supporting documents solely to add the notice.
- Do not edit `.vscode/launch.json` or `.vscode/tasks.json`; use sidecars as required by the
  MCP-generated configuration preservation contract.
- Do not modify external schemas, vendored dependencies, generated lockfile semantics, or parsers
  merely to avoid a sidecar.
- Do not claim completion while any inventoried file lacks a notice or while any validation fails.
- Later workflow phases that create a file must add the appropriate notice when creating it and
  preserve notices already applied by this step. They must also append the new file and its
  validation to `AI-NOTICE-MANIFEST.md`.
