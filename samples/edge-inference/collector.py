"""Persist inspection stages, preserve evidence, and publish through a durable outbox."""

import hashlib
import json
import logging
import os
import sqlite3
import stat
import time
from contextlib import closing
from pathlib import Path, PurePosixPath

from inspection import (
    MAX_IMAGE_BYTES,
    MAX_MESSAGE_BYTES,
    STAGES,
    JsonObject,
    audit_inference,
    check_postprocessing,
    encode,
    identifier,
    preserve_image,
    review_detections,
    select_snapshot,
    timestamp,
    utc,
    validate_detections,
    validate_scenarios,
)

LOG = logging.getLogger(__name__)


class CapacityError(RuntimeError):
    """The observer cannot persist another inspection without exceeding its limit."""


def read_records(
    state: Path,
    inspection_id: str | None = None,
    limit: int = 20,
    pending: bool = False,
) -> list[JsonObject]:
    database = (state / "inspections.db").resolve().as_uri() + "?mode=ro"
    with closing(sqlite3.connect(database, uri=True)) as db:
        db.row_factory = sqlite3.Row
        if inspection_id is not None:
            rows = db.execute(
                "SELECT observation FROM inspections WHERE id=? AND observation IS NOT NULL",
                (identifier(inspection_id),),
            ).fetchall()
            if not rows:
                raise ValueError(f"No completed observation for {inspection_id}")
        elif pending:
            rows = db.execute(
                """SELECT id,scenario,deadline,observation FROM inspections
                   WHERE observation IS NULL OR published=0 ORDER BY first_seen LIMIT ?""",
                (limit,),
            ).fetchall()
            return [
                {
                    "inspectionId": row["id"],
                    "scenario": row["scenario"],
                    "deadline": utc(row["deadline"]),
                    "state": "awaiting-stages"
                    if row["observation"] is None
                    else "awaiting-publication",
                }
                for row in rows
            ]
        else:
            rows = db.execute(
                """SELECT observation FROM inspections WHERE observation IS NOT NULL
                   ORDER BY completed DESC LIMIT ?""",
                (limit,),
            ).fetchall()
    return [json.loads(row["observation"]) for row in rows]


def read_evidence(state: Path, inspection_id: str) -> bytes:
    """Export only the retained, checksum-matching JPEG for a completed inspection."""
    inspection_id = identifier(inspection_id)
    observation = read_records(state, inspection_id)[0]
    evidence = observation.get("evidence")
    filename = f"{inspection_id}.jpg"
    if not isinstance(evidence, dict) or evidence.get("file") != filename:
        raise ValueError(f"No retained evidence for {inspection_id}")
    root_fd = os.open(state, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        fd = os.open(filename, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=root_fd)
        with os.fdopen(fd, "rb") as source:
            if not stat.S_ISREG(os.fstat(source.fileno()).st_mode):
                raise ValueError("Retained evidence is not a regular file")
            data = source.read(MAX_IMAGE_BYTES + 1)
    finally:
        os.close(root_fd)
    if not 0 < len(data) <= MAX_IMAGE_BYTES:
        raise ValueError("Retained evidence exceeds the permitted image size")
    if len(data) != evidence.get("bytes") or hashlib.sha256(data).hexdigest() != evidence.get(
        "sha256"
    ):
        raise ValueError("Retained evidence does not match the observation's checksum and size")
    return data


class Collector:
    """A single-writer inspection store; terminal observations are immutable."""

    def __init__(
        self,
        scenarios: list[JsonObject],
        state: Path,
        media: Path,
        responses: Path,
        timeout: int = 180,
        max_records: int = 10000,
    ):
        validate_scenarios(scenarios)
        self.scenarios = {item["name"]: item for item in scenarios}
        self.state, self.media = Path(state), Path(media)
        self.responses = Path(responses)
        self.state.mkdir(parents=True, exist_ok=True)
        self.timeout, self.max_records = timeout, max_records
        self.db = sqlite3.connect(self.state / "inspections.db")
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA synchronous=FULL")
        self.db.execute("""
            CREATE TABLE IF NOT EXISTS inspections (
                id TEXT PRIMARY KEY, scenario TEXT NOT NULL, first_seen REAL NOT NULL,
                deadline REAL NOT NULL, trigger TEXT, capture TEXT, inference TEXT, result TEXT,
                error TEXT, observation TEXT, completed REAL, published INTEGER NOT NULL DEFAULT 0
            )
        """)
        self.db.commit()
        try:
            self._check_configuration(scenarios)
        except (sqlite3.Error, ValueError):
            self.db.close()
            raise

    def _check_configuration(self, scenarios: list[JsonObject]) -> None:
        signature = hashlib.sha256(encode(scenarios).encode()).hexdigest()
        with self.db:
            self.db.execute(
                """CREATE TABLE IF NOT EXISTS observer_configuration (
                    id INTEGER PRIMARY KEY CHECK (id=1), signature TEXT NOT NULL
                )"""
            )
            previous = self.db.execute(
                "SELECT signature FROM observer_configuration WHERE id=1"
            ).fetchone()
            unfinished = self.db.execute(
                "SELECT count(*) FROM inspections WHERE observation IS NULL OR published=0"
            ).fetchone()[0]
            if unfinished and (previous is None or previous["signature"] != signature):
                raise ValueError(
                    "Configuration changed with unfinished or unpublished inspections; "
                    "restore the previous configuration and observer version, drain, then update"
                )
            self.db.execute(
                """INSERT INTO observer_configuration (id,signature) VALUES (1,?)
                   ON CONFLICT(id) DO UPDATE SET signature=excluded.signature""",
                (signature,),
            )

    def close(self) -> None:
        self.db.close()

    def _get_or_create(self, inspection_id: str, scenario_name: str, now: float) -> sqlite3.Row:
        row = self.db.execute("SELECT * FROM inspections WHERE id=?", (inspection_id,)).fetchone()
        if row is None:
            count = self.db.execute("SELECT count(*) FROM inspections").fetchone()[0]
            if count >= self.max_records:
                raise CapacityError(
                    "Inspection capacity reached; archive records or increase capacity"
                )
            self.db.execute(
                "INSERT INTO inspections (id,scenario,first_seen,deadline) VALUES (?,?,?,?)",
                (inspection_id, scenario_name, now, now + self.timeout),
            )
            row = self.db.execute(
                "SELECT * FROM inspections WHERE id=?", (inspection_id,)
            ).fetchone()
        if row["scenario"] != scenario_name:
            raise ValueError("trigger-id was reused across scenarios")
        return row

    def _set_trigger_deadline(
        self,
        inspection_id: str,
        scenario_name: str,
        value: object,
        now: float,
    ) -> None:
        try:
            scenario = self.scenarios[scenario_name]
            if not isinstance(value, dict) or value.get("inspectionId") != inspection_id:
                raise ValueError("Trigger body and trigger-id disagree")
            if value.get("assetId") != scenario["assetName"]:
                raise ValueError("Trigger asset does not match the configured camera")
            if not isinstance(value.get("context", {}), dict):
                raise ValueError("Trigger context must be a JSON object")
            timestamp(value.get("eventTime"))
            started = timestamp(value.get("triggeredAt"))
            if started > now + 10:
                raise ValueError("Trigger is in the future; synchronize clocks")
            self.db.execute(
                "UPDATE inspections SET deadline=? WHERE id=?",
                (started + self.timeout, inspection_id),
            )
        except ValueError as failure:
            self.db.execute(
                "UPDATE inspections SET error=? WHERE id=?",
                (str(failure), inspection_id),
            )

    def ingest(
        self,
        scenario_name: str,
        stage: str,
        inspection_id: str,
        payload: bytes,
        now: float | None = None,
        validation_error: str | None = None,
    ) -> None:
        now = time.time() if now is None else now
        identifier(inspection_id)
        if stage not in STAGES or scenario_name not in self.scenarios:
            raise ValueError("Unknown scenario or message stage")
        error = validation_error
        try:
            if len(payload) > MAX_MESSAGE_BYTES:
                raise ValueError("Message exceeds 1 MiB")
            value = json.loads(payload)
            serialized = encode(value)
        except (ValueError, UnicodeDecodeError) as failure:
            serialized = encode({"invalidPayload": True})
            error = f"Invalid {stage} JSON: {failure}"
        with self.db:
            row = self._get_or_create(inspection_id, scenario_name, now)
            if row[stage] is not None:
                if row[stage] == serialized:
                    return
                LOG.error("Conflicting duplicate %s for inspection %s", stage, inspection_id)
                if row["observation"] is None:
                    self.db.execute(
                        "UPDATE inspections SET error=? WHERE id=?",
                        (f"Conflicting duplicate {stage}", inspection_id),
                    )
            elif row["observation"] is not None:
                LOG.warning("Ignoring late %s for completed inspection %s", stage, inspection_id)
                return
            else:
                # The SQL column is restricted to STAGES, not arbitrary message input.
                self.db.execute(
                    f"UPDATE inspections SET {stage}=? WHERE id=?", (serialized, inspection_id)
                )
            if error:
                self.db.execute("UPDATE inspections SET error=? WHERE id=?", (error, inspection_id))
            if stage == "trigger" and not error:
                self._set_trigger_deadline(inspection_id, scenario_name, value, now)
        self._advance(inspection_id, now)

    def _advance(self, inspection_id: str, now: float) -> None:
        row = self.db.execute("SELECT * FROM inspections WHERE id=?", (inspection_id,)).fetchone()
        if row["observation"] is not None:
            return
        scenario = self.scenarios[row["scenario"]]
        problem = row["error"]
        capture = json.loads(row["capture"]) if row["capture"] else None
        detections, selected, warnings = None, None, []
        expected, inferred_path, inference_details = None, None, None
        try:
            if capture is not None:
                selected, warnings = select_snapshot(capture, scenario)
            if row["inference"] is not None:
                expected, inferred_path, inference_details = audit_inference(
                    json.loads(row["inference"]),
                    scenario,
                    self.responses,
                )
            if row["result"] is not None:
                detections = validate_detections(json.loads(row["result"]))
            if selected is not None and inferred_path is not None:
                if inferred_path != "/".join(PurePosixPath(selected["TargetPath"]).parts[-5:]):
                    raise ValueError(
                        "Captured evidence and the image actually inferred do not match"
                    )
            if detections is not None and expected is not None:
                check_postprocessing(detections, expected)
        except (OSError, ValueError, TypeError, OverflowError) as failure:
            problem = str(failure)
        expired = row["deadline"] <= now
        if not row["trigger"] and not expired:
            return
        if not problem and (
            not row["trigger"] or selected is None or expected is None or detections is None
        ):
            if not expired:
                return
            missing = [stage for stage in sorted(STAGES) if row[stage] is None]
            problem = f"Inspection timed out; missing stages: {', '.join(missing)}"
        if expired and not problem:
            problem = "Inspection exceeded its deadline"
        trigger = json.loads(row["trigger"]) if row["trigger"] else {}
        if not isinstance(trigger, dict):
            trigger = {}
        observation = {
            "schemaVersion": 1,
            "inspectionId": inspection_id,
            "scenario": row["scenario"],
            "assetId": scenario["assetName"],
            "eventTime": trigger.get("eventTime"),
            "triggeredAt": trigger.get("triggeredAt"),
            "completedAt": utc(now),
            "context": trigger.get("context", {}),
            "model": scenario["modelName"],
            "modelProvenance": scenario.get("modelProvenance"),
            "policy": scenario["policy"],
            "confidenceThreshold": scenario["confidenceThreshold"],
            "coordinateSpace": {
                "width": scenario["imageSize"][0],
                "height": scenario["imageSize"][1],
            },
            "detections": detections,
            "inference": inference_details,
            "captureWarnings": warnings,
            "automaticActuation": False,
        }
        if selected is not None:
            try:
                evidence = preserve_image(
                    self.media,
                    selected["TargetPath"],
                    self.state / f"{inspection_id}.jpg",
                )
                observation["evidence"] = {
                    **evidence,
                    "capturePath": selected["TargetPath"],
                    "offsetFromEventTimeMilliseconds": selected["OffsetFromEventTimeMilliseconds"],
                }
            except (OSError, ValueError) as failure:
                problem = f"Could not preserve capture evidence: {failure}"
        if not problem:
            try:
                matches = review_detections(scenario, detections)
                observation["reviewDetections"] = matches
                observation["status"] = "REVIEW" if matches or warnings else "NO_FINDING"
                observation["reason"] = (
                    "Operator review required"
                    if matches or warnings
                    else "No configured finding above threshold; not a quality or safety certification"
                )
            except ValueError as failure:
                problem = str(failure)
        if problem:
            observation.update(status="ERROR", reason=problem)
        with self.db:
            self.db.execute(
                "UPDATE inspections SET observation=?,completed=? WHERE id=?",
                (encode(observation), now, inspection_id),
            )
        LOG.info("Inspection %s: %s", inspection_id, observation["status"])

    def tick(self, now: float | None = None) -> None:
        now = time.time() if now is None else now
        for row in self.db.execute(
            "SELECT id FROM inspections WHERE observation IS NULL"
        ).fetchall():
            self._advance(row["id"], now)

    def pending_publications(self) -> list[sqlite3.Row]:
        return self.db.execute(
            """SELECT id,scenario,observation FROM inspections
               WHERE observation IS NOT NULL AND published=0 LIMIT 20"""
        ).fetchall()

    def mark_published(self, inspection_id: str) -> None:
        with self.db:
            self.db.execute("UPDATE inspections SET published=1 WHERE id=?", (inspection_id,))

    def prune(self, retention_days: int, now: float | None = None) -> None:
        cutoff = (time.time() if now is None else now) - retention_days * 86400
        rows = self.db.execute(
            "SELECT id FROM inspections WHERE published=1 AND completed<? LIMIT 100",
            (cutoff,),
        ).fetchall()
        for row in rows:
            (self.state / f"{identifier(row['id'])}.jpg").unlink(missing_ok=True)
            with self.db:
                self.db.execute("DELETE FROM inspections WHERE id=?", (row["id"],))
        if rows:
            LOG.info("Expired %d published inspections and their evidence", len(rows))
