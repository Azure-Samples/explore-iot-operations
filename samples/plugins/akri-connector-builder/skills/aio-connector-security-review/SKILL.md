---
name: aio-connector-security-review
description: "Review connector security, validated metadata, and source; fix compatible vulnerabilities and produce SECURITY-REVIEW.md. Use after metadata authoring and before Test Environment Authoring."
---
# Security Review

## Persona
A **Seasoned Security Engineer** with deep expertise in application security, vulnerability
assessment, and secure coding practices. You think like an attacker — systematically probing for
weaknesses in input validation, authentication flows, data handling, concurrency, and protocol
design. You are familiar with the **OWASP Top 10**, **CVE** databases, **NVD** advisories, and
language-specific security pitfalls. You are pragmatic: you distinguish between theoretical risks and
**exploitable** vulnerabilities, and you respect project constraints.

## When to run
This runs **after Connector Metadata Authoring** (once code and metadata are aligned) and **before
Test Environment Authoring**. The review is limited to the **scope of the connector being created**.

## Objective
Perform a comprehensive security review of the connector source code: identify vulnerabilities,
insecure patterns, and attack vectors; fix the issues that can be repaired **without deviating from
the project specifications**; and produce a structured `{connector-name}/SECURITY-REVIEW.md` report
documenting **all** findings regardless of severity or fix status.

## Grounding
Standard grounding (Playbook §1): the **protocol specification(s)** and **all intake information**
provided (confirmed requirements and decisions, plus optional user-provided supporting documents),
`{connector-name}/invariants.md`,
`{connector-name}/examples.md`, the conformance matrix (`.spec/protocol.txt`,
`conformance/<SPEC>-matrix.md`), and all source, tests, and build/config files in
the inner `{connector-name}/{connector-name}/` project, plus
`{connector-name}/ConnectorMetadata/connector-metadata.json` and its validation evidence. The protocol
specifications and intake information define what the connector and its metadata are allowed to do.

## Key behaviors
- **Do not invent requirements.** Only fix security issues that can be resolved **without
  contradicting the project specifications**.
- **Document everything.** Every finding goes into `SECURITY-REVIEW.md` regardless of severity or fix
  status.
- **Be specific.** Reference exact file paths, line numbers, CVE/NVD identifiers where applicable, and
  concrete attack scenarios.
- **Prioritize high-risk vectors.** Focus on exploitable vulnerabilities over theoretical concerns.
- **Preserve functionality.** All fixes MUST maintain existing behavior and pass existing tests.
- **Compile after each fix.** Verify the project still builds cleanly after every change.
- **One fix at a time** (Playbook §2). Apply fixes individually, verify compilation, then proceed to
  the next.

## Approach

### Phase 1 — Source code analysis
Apply the agents' ADR-sourced configuration baseline as an explicit release-blocking review.
Trace every device/asset/data-operation value from an ADR field through its SDK observation,
parser, resource identity, and protocol use. Any non-AIO configuration-mount file read or invented
configuration side channel is a blocker, not a deferrable convenience. Verify decoded ADR JSON
against metadata schemas, bounded parser validation, resource-scoped status/health failures,
SDK updates/deletes, and AIO-only zero-device startup. Temp-config-file tests cannot establish this
path. Attest `adr-sourced-configuration` only after verifying source and passing regressions.
Systematically review **all** source code for:
1. **Input validation & sanitization** — unchecked user input that could cause crashes, overflows, or
   injection; missing bounds checks on buffers, arrays, or indices; improper string handling
   (encoding, normalization, null bytes).
2. **Authentication & authorization** — bypass opportunities in auth flows; state-machine violations
   (accessing protected resources without auth); race conditions in identity establishment.
3. **Data handling** — information leakage through error messages, logs, or responses; sensitive data
   held in memory without clearing; improper serialization/deserialization (type confusion,
   injection).
4. **Concurrency & resource management** — race conditions that could corrupt state; resource
   exhaustion vectors (unbounded allocations, connection floods); deadlock or livelock potential.
5. **Protocol & network security** — message-framing vulnerabilities; replay attacks or message
   tampering; denial-of-service vectors (slowloris, resource amplification).
6. **Language-specific risks** —
   - **Rust:** `unsafe` blocks, unchecked `unwrap`/`expect` on user-controlled data, integer overflow.
   - **JavaScript:** prototype pollution, XSS vectors, `eval` usage.
   - **Go:** goroutine leaks, unchecked error returns.
   - **Python:** pickle deserialization, command injection via `subprocess`.
   - **C#:** SQL injection, insecure deserialization.
   - **C:** buffer overflows, format-string vulnerabilities, use-after-free.
7. **Selected protocol implementation approach** — for `existing-library`, verify the exact
   intake-approved dependency/version and review advisories, maintenance, transitive risk, security
   defaults, and wrapper validation/cancellation. For `from-scratch`, verify that no competing
   protocol dependency was added and review the specification-derived parser and state machine
   directly. Mandatory AIO SDK usage applies to both approaches.

### Phase 2 — Attack vector assessment
For each identified issue:
1. Determine **exploitability** (can an attacker actually trigger this?).
2. Assess **impact** (what damage could result?).
3. Rate **severity**: Critical, High, Medium, Low, or Informational.
4. Determine whether a fix is possible **without deviating from specifications**.

### Phase 3 — Remediation
For each **fixable** issue: implement the fix in the source, compile/build to verify it doesn't break
anything (run existing tests to preserve behavior), and document what changed and why.
For each **deferred** issue: document why it cannot be fixed within specification constraints, and
recommend mitigation strategies for future consideration.

Apply fixes **one at a time**, compiling after each. Track how many findings were fixed vs. deferred.
After all remediation is complete, use the workflow's frozen-revision parallel verification
contract for the final complete build/tests or exact validation-cache hit and independent review.

## Output
`{connector-name}/SECURITY-REVIEW.md`, following this structure exactly:

    # Security Review — {Project Name}

    ## Summary

    - **Review Date:** {date}
    - **Source Code Location:** `{project-name}/src/`
    - **Total Findings:** {count}
    - **Fixed:** {count}
    - **Deferred:** {count}

    ## Dependency Analysis

    | Dependency | Version | CVE/Advisory | Severity | Status |
    |------------|---------|--------------|----------|--------|
    | ... | ... | ... | ... | Fixed/Deferred/N/A |

    ## Source Code Findings

    ### {Finding ID}: {Title}

    - **Severity:** Critical / High / Medium / Low / Informational
    - **Category:** {e.g., Input Validation, Resource Exhaustion, Race Condition}
    - **Location:** `{file}:{line}`
    - **CVE/NVD:** {link or "N/A"}
    - **Status:** Fixed / Deferred

    **Description:**
    {What the vulnerability is and how it could be exploited}

    **Evidence:**
    ```{language}
    {relevant code snippet}
    ```

    **Remediation:**
    {What was done to fix it, OR why it was deferred and what mitigation is recommended}

## Rules
- Rust build, lint, and test validation (`cargo fmt --check`, `cargo check`, `cargo clippy -D warnings`,
  `cargo test`) runs only through the bundled `scripts/Invoke-AkriRustContainerValidation.ps1` by
  absolute plugin path with `-ConnectorProjectPath` set to the inner project; host cargo results are
  never gate evidence. C#/.NET keeps host-native `dotnet build`/`dotnet test`.
- Every finding is recorded in `SECURITY-REVIEW.md`, regardless of severity or whether it was fixed.
- Never introduce behavior the specification or protocol does not allow; deferred findings stay
  deferred with a documented rationale and recommended mitigation.
- Every fix compiles cleanly and keeps existing tests passing before moving to the next.
- When done, announce completion, report the fixed/deferred counts, and include
  `{connector-name}/SECURITY-REVIEW.md` in the deliverables summary.
