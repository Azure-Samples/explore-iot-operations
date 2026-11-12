# Model candidates and bounded recommendations

These two opt-in **custom** Map roles extend the existing public pattern module.
They use public SDK 1.1.3 and separate Map/Filter components for AIO 1.6.
The eight existing patterns and published `1.0.0-rc.4` are unchanged.
`1.0.0-rc.5` below is a **candidate version, not a publication claim**.

| Graph | Input | Operation | Output |
|---|---|---|---|
| `fit-linear-model` | Matched feature vectors and measured targets | Bounded lookback least-squares fit with intercept | Unapproved coefficients, metrics, and training provenance |
| `bounded-recommendation` | Fresh error, observed current value, and pinned external model version | Signed proportional step, step limit, and absolute bounds | Recommendation only; no equipment command |

Reuse `align-by-time` and `correlate-by-id` for correlation. An upstream adapter
must explicitly select ordered features and the target from matched records.
Enrichment and equation evaluation remain built-in operations; these graphs
neither replace them nor require an unreleased window operator.

## Input and output

Complete synthetic request/result sequences are in
[`fixtures/fit-linear-model.json`](fixtures/fit-linear-model.json) and
[`fixtures/bounded-recommendation.json`](fixtures/bounded-recommendation.json).
Each contains exact field sets; fitted floating-point values have `1e-8`
absolute test tolerance. Replay the same Rust core locally:

```bash
make test check build
cargo run --locked --example replay -- fixtures/fit-linear-model.json
cargo run --locked --example replay -- fixtures/bounded-recommendation.json
```

Training input:

```json
{"kind":"sample","assetId":"sensor-a","sampleId":"s-1","epoch":1,"sequence":1,"modelVersion":7,"sampledAt":"2026-11-10T12:00:00Z","features":[2,4],"target":3}
```

All fields are required; unknown fields, including `approved`, are rejected.
Feature order must remain identical throughout an epoch. `modelVersion` is
the externally supplied training basis, not approval evidence. A candidate has
`kind: modelCandidate`, `approved: false`, ordered `coefficients`, `intercept`,
`rmse`, `rSquared`, standardized-design `conditionNumber`, sample IDs/count,
first/last event times, processing fit time, and `(assetId, epoch, lastSequence)`
identity. Constant targets have `rSquared: null`.

The required `fit` configuration sets `epoch > 0`, `featureCount` (1–8),
`minSamples` (at least features + 1), `maxSamples` (up to 1024),
`lookbackMs` (1–86400000), and `maxCondition` (1–1e8).
Samples older than the lookback or in the future are rejected. After an accepted
arrival, only unexpired records and the newest `maxSamples` participate.
Columns are centered/scaled and targets normalized; a bounded-iteration SVD solves the design directly,
not normal equations. Rank-deficient, constant-feature, or ill-conditioned
designs retain accepted training data but withhold candidates.
Condition numbers at or above the configured limit are rejected. Input numbers
must be finite with magnitude at most `1e100`; non-finite arithmetic or
unrepresentable coefficient scaling/residual metrics fail closed.
Metrics describe this training set, not independent validation or model quality.

Decision input:

```json
{"kind":"decision","assetId":"sensor-a","decisionId":"d-1","epoch":1,"sequence":1,"modelVersion":7,"sampledAt":"2026-11-10T12:00:00Z","currentValue":5,"error":2}
```

The required `recommendation` configuration pins an externally approved
`modelVersion` and `epoch`, plus signed `gain`, `minValue`, `maxValue`,
positive `maxStep`, and `maxAgeMs` (1–86400000). Inputs must have an in-range
current value, matching version/epoch, and fresh, nonfuture event time.
The deployment example allows 5000 ms, including transport/processing latency;
the core fixtures separately test strict 1000 ms freshness boundaries.
The operation is
`clamp(currentValue + clamp(gain * error, -maxStep, maxStep), minValue, maxValue)`.
Outputs include input identity, error/current value, `recommendedValue`, actual
`delta`, `limited`, processing time, `approved: false`, and `actuation: false`.
The observed current value is supplied anew for each decision, never accumulated.
Step bounds are per decision, **not** slew-rate, stability, or safety guarantees.
If floating-point rounding would make the actual delta exceed `maxStep`,
the input is rejected without consuming its identity or sequence.

## State and trust

Both roles cap assets at 128 (graph examples use eight), never evict assets,
and require strictly increasing per-asset sequence numbers and nondecreasing
event times. Training also pins each asset's basis version. Retained training IDs
detect retries/conflicts; recommendations retain only the last decision payload.
Older sequence numbers remain rejected after payload eviction, but reusing an
evicted ID with a higher sequence is outside the conflict-detection contract.
Rejected or duplicate records do not refresh state.
Pending and diagnostic outputs are suppressed by the separate Filter; diagnostics
go to runtime logs/counters. Nothing fits or recommends on an idle timer.

State is volatile. Restarting with the same epoch loses replay watermarks and
training history. For a reset/model or feature-schema change, stop publishers,
drain old inputs, redeploy with a **new externally allocated epoch**, and send
only that epoch. External durable recovery and deduplication are required across
restarts; no exactly-once or automatic recovery guarantee is made.
Never wire candidate output directly to an approved-model topic or actuator.
Approval, independent evaluation, authenticated publishers, broker ACLs, and
equipment interlocks are external responsibilities. Literal `inputTopics`
binding prevents cross-topic kind confusion, not spoofing by authorized writers.

## Build and installation

Use the existing `scripts/prepare-release.py`, locked WASI build, and
`scripts/publish.sh` workflow to stage/publish a **new immutable version** of all
ten graphs and both modules. Do not overwrite any published `rc.4` tags.
The source Helm chart keeps the original eight defaults and makes additions
opt-in. After publishing and verifying the new artifacts:

```bash
helm upgrade --install model-demo ./chart --namespace azure-iot-operations \
  --set endpointRef=factory-mqtt --set artifactVersion=1.0.0-rc.5 \
  --set patterns.fit-linear-model=true --set patterns.bounded-recommendation=true
```

For standalone deployment, use `manifests/registry.yaml` plus
`manifests/fit-linear-model.yaml` and `manifests/bounded-recommendation.yaml`.
They assume an existing single-instance `default` profile and `factory-mqtt`
endpoint in `azure-iot-operations`; change their complete JSON settings for your
epoch, schema, version and units. Do not apply candidate references before their
artifacts exist. Helm topics default to `dataflow-patterns/<release>/…`;
standalone topics use `factory/…`. Keep outputs isolated from inputs.

With both graphs deployed on a fresh isolated prefix and source, transform and
destination health `Available`, run `scripts/verify-learning.py`
(`MQTT_HOST`, `MQTT_PORT`, `TOPIC_PREFIX`;
optional username/password and TLS CA follow the existing runtime runner).
It exercises numerical outputs, suppression and nonactuating recommendations.
