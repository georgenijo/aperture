#!/usr/bin/env python3
"""Local Film Lab server.

Serves the browser UI on 127.0.0.1 and supervises one persistent Swift
renderer (`film-lab-renderer serve`) over newline-delimited JSON. The protocol
carries server-owned session paths and validated settings, never image bytes.
Python standard library only.
"""

from __future__ import annotations

import argparse
import atexit
import collections
import hashlib
import hmac
import http.server
import itertools
import json
import math
import os
import platform
import queue
import re
import secrets
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import traceback
import urllib.parse
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

TOOL_DIR = Path(__file__).resolve().parent
REPO_DIR = TOOL_DIR.parent.parent
WEB_DIR = TOOL_DIR / "web"
CONTROLS_PATH = TOOL_DIR / "controls.json"
FIXTURES_DIR = REPO_DIR / "ApertureTests" / "Fixtures"
DEFAULT_RENDERER = TOOL_DIR / ".build" / "film-lab-renderer"
DEFAULT_PRESETS_DIR = Path.home() / "Library" / "Application Support" / "Aperture Film Lab" / "presets"

TOOL_NAME = "aperture-film-lab"
TOOL_VERSION = "1"
PROTOCOL_VERSION = 1

# Static files are served from this allowlist only.
STATIC_FILES = {
    "/": ("index.html", "text/html; charset=utf-8"),
    "/index.html": ("index.html", "text/html; charset=utf-8"),
    "/app.js": ("app.js", "text/javascript; charset=utf-8"),
    "/styles.css": ("styles.css", "text/css; charset=utf-8"),
}
SAMPLE_NAMES = ("day-portrait", "night-flash", "hdr-still-life")

# Limits.
MAX_UPLOAD_BYTES = 64 * 1024 * 1024
MAX_JSON_BYTES = 256 * 1024
MAX_JSON_DEPTH = 8
MAX_CANDIDATE_DEPTH = 16
MAX_PHOTOS = 12
MAX_NAME_LENGTH = 80
MAX_PENDING_EXPLICIT_JOBS = 2
MAX_RETAINED_JOBS = 6
MAX_RETAINED_PREVIEWS = 8
MAX_PENDING_TASKS = 16
MAX_CONCURRENT_UPLOADS = 2
MAX_CONNECTIONS = 32
PREVIEW_DIMENSIONS = (256, 4096)
DEFAULT_PREVIEW_DIMENSION = 1280
ORIGINAL_PREVIEW_DIMENSION = 1600
BATCH_PREVIEW_DIMENSION = 720

SEED_PATTERN = re.compile(r"^(0|[1-9][0-9]{0,19})$")
INSTANT_PATTERN = re.compile(
    r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(Z|[+-][0-9]{2}:[0-9]{2})$"
)
TIME_ZONE_PATTERN = re.compile(r"^[A-Za-z][A-Za-z0-9_+\-/]{0,63}$")
PRESET_ID_PATTERN = re.compile(r"^p-[0-9a-f]{16}$")
ID_PATTERN = re.compile(r"^[a-z]-[0-9a-f]{12}$")
UINT64_MAX = 2**64 - 1


class LabError(Exception):
    def __init__(self, status: int, code: str, message: str, **extra: Any) -> None:
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message
        self.extra = extra

    def payload(self) -> dict[str, Any]:
        return {"error": {"code": self.code, "message": self.message, **self.extra}}


def log(message: str) -> None:
    print(f"[film-lab] {message}", file=sys.stderr, flush=True)


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


# --------------------------------------------------------------------------
# Control schema (controls.json is the single authority)
# --------------------------------------------------------------------------


class ControlSchema:
    def __init__(self, path: Path) -> None:
        raw = path.read_bytes()
        self.raw = raw
        self.digest = "sha256:" + hashlib.sha256(raw).hexdigest()
        document = json.loads(raw)
        if document.get("schema") != "aperture.film-lab.controls":
            raise ValueError("controls.json has an unexpected schema")
        self.version: int = document["version"]
        self.controls: dict[str, dict[str, Any]] = {}
        for control in document["controls"]:
            if control["id"] in self.controls:
                raise ValueError(f"duplicate control {control['id']}")
            self.controls[control["id"]] = control
        context = document["context"]
        self.default_context = {key: context[key]["default"] for key in ("seed", "capturedAt", "timeZone", "photoQuality")}
        self.photo_qualities: list[str] = list(context["photoQuality"]["options"])

    def validate_controls(self, value: Any) -> dict[str, Any]:
        if not isinstance(value, dict):
            raise LabError(400, "bad-controls", "controls must be an object")
        if len(value) > len(self.controls):
            raise LabError(400, "bad-controls", "too many controls")
        clean: dict[str, Any] = {}
        for key, item in value.items():
            control = self.controls.get(key) if isinstance(key, str) else None
            if control is None:
                raise LabError(400, "unknown-control", f"Unknown control {str(key)[:40]!r}.")
            if control["kind"] == "number":
                if isinstance(item, bool) or not isinstance(item, (int, float)) or not math.isfinite(item):
                    raise LabError(400, "control-kind-mismatch", f"{key} must be a finite number.")
                if not control["min"] <= item <= control["max"]:
                    raise LabError(400, "control-out-of-range", f"{key} must be from {control['min']} to {control['max']}.")
                if item != control["neutral"]:
                    clean[key] = float(item)
            else:
                if not isinstance(item, str) or item not in control["options"]:
                    raise LabError(400, "control-out-of-range", f"{key} must be one of {', '.join(control['options'])}.")
                if item != control["neutral"]:
                    clean[key] = item
        return clean

    def validate_context(self, value: Any) -> dict[str, str]:
        keys = ("seed", "capturedAt", "timeZone", "photoQuality")
        if not isinstance(value, dict) or set(value) != set(keys):
            raise LabError(400, "bad-context", "context needs exactly seed, capturedAt, timeZone and photoQuality")
        if not all(isinstance(value[key], str) for key in keys):
            raise LabError(400, "bad-context", "context values must be strings (the seed is a decimal string)")
        seed = value["seed"]
        if not SEED_PATTERN.match(seed) or int(seed) > UINT64_MAX:
            raise LabError(400, "invalid-seed", "The seed must be a decimal integer from 0 to 18446744073709551615.")
        if not INSTANT_PATTERN.match(value["capturedAt"]):
            raise LabError(400, "invalid-captured-at", "The capture instant must be ISO 8601 with a zone, e.g. 2026-09-15T19:20:00Z.")
        if not TIME_ZONE_PATTERN.match(value["timeZone"]):
            raise LabError(400, "invalid-time-zone", "Invalid time zone identifier.")
        if value["photoQuality"] not in self.photo_qualities:
            raise LabError(400, "invalid-photo-quality", "Unknown photo quality.")
        return {key: value[key] for key in keys}


def json_depth(value: Any) -> int:
    """Nesting depth of a decoded JSON value, computed without recursion."""
    deepest = 0
    stack: list[tuple[Any, int]] = [(value, 1)]
    while stack:
        item, depth = stack.pop()
        deepest = max(deepest, depth)
        if isinstance(item, dict):
            stack.extend((child, depth + 1) for child in item.values())
        elif isinstance(item, list):
            stack.extend((child, depth + 1) for child in item)
    return deepest


def loads_bounded(text: str, max_depth: int) -> Any:
    """json.loads that rejects non-finite constants and deep nesting. A
    pathologically nested document can exhaust the parser's recursion limit,
    which is reported as the same invalid-JSON error."""
    try:
        value = json.loads(text, parse_constant=reject_constant)
    except (ValueError, RecursionError):
        raise LabError(400, "invalid-json", "The JSON is invalid or nested too deeply.") from None
    if json_depth(value) > max_depth:
        raise LabError(400, "invalid-json", "The JSON is nested too deeply.")
    return value


def reject_constant(name: str) -> Any:
    raise ValueError(f"non-finite number {name}")


def parse_json_body(data: bytes) -> Any:
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        raise LabError(400, "invalid-json", "The request body is not UTF-8 JSON.") from None
    return loads_bounded(text, MAX_JSON_DEPTH)


def validate_name(value: Any) -> str:
    if not isinstance(value, str):
        raise LabError(400, "invalid-name", "A look name is required.")
    name = value.strip()
    if not 1 <= len(name) <= MAX_NAME_LENGTH or any(ord(c) < 0x20 or 0x7F <= ord(c) < 0xA0 for c in name):
        raise LabError(400, "invalid-name", f"A look name must be 1–{MAX_NAME_LENGTH} printable characters.")
    return name


def sniff_image(head: bytes) -> str | None:
    if head.startswith(b"\xff\xd8\xff"):
        return "jpg"
    if head.startswith(b"\x89PNG\r\n\x1a\n"):
        return "png"
    if len(head) >= 12 and head[4:8] == b"ftyp" and head[8:12] in {
        b"heic", b"heix", b"hevc", b"hevx", b"heim", b"heis", b"mif1", b"msf1",
    }:
        return "heic"
    return None


# --------------------------------------------------------------------------
# Renderer worker supervision
# --------------------------------------------------------------------------


class WorkerFailure(Exception):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


class RendererWorker:
    """One persistent renderer process. Only the job thread calls `call`."""

    def __init__(self, binary: Path, session: Path, schema: ControlSchema, *, recycle_after: int,
                 timeout: float, max_pixels: int | None, test_hooks: bool) -> None:
        self.binary = binary
        self.session = session
        self.schema = schema
        self.recycle_after = recycle_after
        self.timeout = timeout
        self.max_pixels = max_pixels
        self.test_hooks = test_hooks
        self.process: subprocess.Popen[bytes] | None = None
        self.lines: queue.Queue[bytes | None] = queue.Queue()
        self.ids = itertools.count(1)
        self.renders_since_start = 0
        self.starts = 0
        self.hello: dict[str, Any] = {}
        self.lock = threading.Lock()

    def command(self) -> list[str]:
        command = [str(self.binary), "serve", "--root", str(self.session), "--controls", str(CONTROLS_PATH)]
        if self.max_pixels:
            command += ["--max-pixels", str(self.max_pixels)]
        if self.test_hooks:
            command.append("--test-hooks")
        return command

    def start(self) -> None:
        self.stop()
        self.lines = queue.Queue()
        process = subprocess.Popen(
            self.command(), stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            cwd=str(self.session), close_fds=True,
        )
        self.process = process
        self.starts += 1
        self.renders_since_start = 0
        lines = self.lines

        def pump_stdout() -> None:
            assert process.stdout is not None
            for line in process.stdout:
                lines.put(line)
            lines.put(None)

        def pump_stderr() -> None:
            assert process.stderr is not None
            for line in process.stderr:
                log("renderer: " + line.decode("utf-8", "replace").rstrip())

        threading.Thread(target=pump_stdout, daemon=True).start()
        threading.Thread(target=pump_stderr, daemon=True).start()
        hello = self._exchange({"op": "hello"}, timeout=30)
        if hello.get("protocol") != PROTOCOL_VERSION:
            raise RuntimeError("renderer protocol mismatch")
        if hello.get("controlSchemaDigest") != self.schema.digest:
            raise RuntimeError("renderer and server read different controls.json bytes")
        self.hello = hello
        log(f"renderer started (pid {hello.get('pid')}, start #{self.starts})")

    def stop(self) -> None:
        process, self.process = self.process, None
        if process is None:
            return
        try:
            if process.stdin:
                process.stdin.close()
            process.wait(timeout=3)
        except Exception:
            process.kill()
            try:
                process.wait(timeout=3)
            except Exception:
                pass

    @property
    def pid(self) -> int | None:
        return self.process.pid if self.process else None

    def _exchange(self, request: dict[str, Any], timeout: float) -> dict[str, Any]:
        process = self.process
        if process is None or process.poll() is not None or process.stdin is None:
            raise WorkerFailure("worker-unavailable", "The renderer is not running.")
        request_id = next(self.ids)
        line = json.dumps({**request, "id": request_id}, separators=(",", ":"), allow_nan=False)
        try:
            process.stdin.write(line.encode("utf-8") + b"\n")
            process.stdin.flush()
        except (BrokenPipeError, OSError):
            raise WorkerFailure("worker-crashed", "The renderer stopped unexpectedly.") from None
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise WorkerFailure("worker-timeout", "The renderer took too long and was restarted.")
            try:
                raw = self.lines.get(timeout=remaining)
            except queue.Empty:
                continue
            if raw is None:
                raise WorkerFailure("worker-crashed", "The renderer stopped unexpectedly and was restarted.")
            try:
                response = json.loads(raw)
            except ValueError:
                raise WorkerFailure("worker-protocol", "The renderer sent an unreadable response.") from None
            if response.get("id") != request_id:
                continue  # A late answer to a request that already timed out.
            if response.get("ok"):
                return response.get("result") or {}
            error = response.get("error") or {}
            raise LabError(422, str(error.get("code", "render-failed")), str(error.get("message", "Rendering failed.")))

    def call(self, request: dict[str, Any], *, timeout: float | None = None, counts_as_render: bool = False) -> dict[str, Any]:
        """Runs one request, restarting the worker after a crash or timeout and
        recycling it after a bounded number of renders."""
        with self.lock:
            if self.process is None or self.process.poll() is not None:
                self.start()
            elif counts_as_render and self.recycle_after and self.renders_since_start >= self.recycle_after:
                log(f"recycling renderer after {self.renders_since_start} renders")
                self.start()
            try:
                result = self._exchange(request, timeout or self.timeout)
            except WorkerFailure:
                # The next call starts a fresh process; this one reports the failure.
                self.stop()
                raise
            if counts_as_render:
                self.renders_since_start += 1
            return result


# --------------------------------------------------------------------------
# Job scheduling
# --------------------------------------------------------------------------


class Future:
    def __init__(self) -> None:
        self._event = threading.Event()
        self._value: Any = None
        self._error: BaseException | None = None

    def set(self, value: Any) -> None:
        self._value = value
        self._event.set()

    def fail(self, error: BaseException) -> None:
        self._error = error
        self._event.set()

    def done(self) -> bool:
        return self._event.is_set()

    def wait(self, timeout: float) -> Any:
        if not self._event.wait(timeout):
            raise LabError(504, "timeout", "The renderer did not answer in time.")
        if self._error is not None:
            raise self._error
        return self._value


@dataclass
class ExplicitJob:
    id: str
    kind: str  # "full" or "batch"
    settings_revision: int
    controls: dict[str, Any]
    context: dict[str, str]
    photo_ids: list[str]
    created_at: float = field(default_factory=time.time)
    status: str = "queued"
    results: list[dict[str, Any]] = field(default_factory=list)
    error: dict[str, Any] | None = None
    next_index: int = 0

    def summary(self) -> dict[str, Any]:
        return {
            "jobId": self.id, "kind": self.kind, "status": self.status,
            "settingsRevision": self.settings_revision, "total": len(self.photo_ids),
            "completed": len(self.results), "results": list(self.results), "error": self.error,
        }


class Scheduler:
    """One job thread. Quick tasks run first, then the newest preview (older
    pending previews are answered as superseded), then one step of the oldest
    explicit job, so a batch never starves interactive previews."""

    def __init__(self, lab: "FilmLab") -> None:
        self.lab = lab
        self.condition = threading.Condition()
        self.tasks: collections.deque[tuple[Callable[[], Any], Future]] = collections.deque()
        self.preview: tuple[dict[str, Any], Future] | None = None
        self.explicit: collections.deque[ExplicitJob] = collections.deque()
        self.jobs: collections.OrderedDict[str, ExplicitJob] = collections.OrderedDict()
        self.stopped = False
        self.busy = False
        self.thread = threading.Thread(target=self.run, name="film-lab-jobs", daemon=True)

    def start(self) -> None:
        self.thread.start()

    def stop(self) -> None:
        with self.condition:
            self.stopped = True
            self.condition.notify_all()
            pending = list(self.tasks)
            self.tasks.clear()
            preview, self.preview = self.preview, None
        for _, future in pending:
            future.fail(LabError(503, "shutting-down", "The server is shutting down."))
        if preview:
            preview[1].fail(LabError(503, "shutting-down", "The server is shutting down."))

    def submit_task(self, function: Callable[[], Any]) -> Future:
        future = Future()
        with self.condition:
            if len(self.tasks) >= MAX_PENDING_TASKS:
                raise LabError(503, "busy", "The renderer is busy; try again.")
            self.tasks.append((function, future))
            self.condition.notify_all()
        return future

    def submit_preview(self, request: dict[str, Any]) -> Future:
        future = Future()
        with self.condition:
            superseded = self.preview
            self.preview = (request, future)
            self.condition.notify_all()
        if superseded:
            superseded[1].set({"status": "superseded", "photoGeneration": superseded[0]["photoGeneration"],
                               "settingsGeneration": superseded[0]["settingsGeneration"]})
        return future

    def submit_explicit(self, job: ExplicitJob) -> None:
        with self.condition:
            pending = sum(1 for queued in self.explicit if queued.status in ("queued", "running"))
            if pending >= MAX_PENDING_EXPLICIT_JOBS:
                raise LabError(429, "queue-full", "Two explicit renders are already queued; wait for one to finish.")
            self.explicit.append(job)
            self.jobs[job.id] = job
            self.condition.notify_all()
        self.lab.trim_jobs()

    def job(self, job_id: str) -> ExplicitJob | None:
        with self.condition:
            return self.jobs.get(job_id)

    def depth(self) -> dict[str, int]:
        with self.condition:
            return {"tasks": len(self.tasks), "preview": 1 if self.preview else 0,
                    "explicit": sum(1 for job in self.explicit if job.status in ("queued", "running"))}

    def run(self) -> None:
        while True:
            with self.condition:
                while not self.stopped and not self.tasks and not self.preview and not self.explicit:
                    self.condition.wait()
                if self.stopped:
                    return
                if self.tasks:
                    work: tuple[str, Any] = ("task", self.tasks.popleft())
                elif self.preview:
                    work = ("preview", self.preview)
                    self.preview = None
                else:
                    work = ("explicit", self.explicit[0])
                self.busy = True
            try:
                if work[0] == "task":
                    function, future = work[1]
                    self._settle(future, function)
                elif work[0] == "preview":
                    request, future = work[1]
                    self._settle(future, lambda: self.lab.render_preview(request))
                else:
                    self._step(work[1])
            finally:
                with self.condition:
                    self.busy = False

    @staticmethod
    def _settle(future: Future, function: Callable[[], Any]) -> None:
        try:
            future.set(function())
        except BaseException as error:  # noqa: BLE001 - reported to the waiting request
            future.fail(error)

    def _step(self, job: ExplicitJob) -> None:
        job.status = "running"
        try:
            if job.next_index < len(job.photo_ids):
                photo_id = job.photo_ids[job.next_index]
                job.next_index += 1
                job.results.append(self.lab.render_explicit(job, photo_id))
            if job.next_index >= len(job.photo_ids):
                job.status = "done"
        except LabError as error:
            job.status = "failed"
            job.error = error.payload()["error"]
        except WorkerFailure as error:
            job.status = "failed"
            job.error = {"code": error.code, "message": error.message}
        except Exception:  # noqa: BLE001
            traceback.print_exc()
            job.status = "failed"
            job.error = {"code": "internal", "message": "The render failed unexpectedly."}
        if job.status in ("done", "failed"):
            with self.condition:
                if self.explicit and self.explicit[0] is job:
                    self.explicit.popleft()


# --------------------------------------------------------------------------
# Session state, media and presets
# --------------------------------------------------------------------------


@dataclass
class Photo:
    id: str
    name: str
    path: Path
    width: int
    height: int
    type: str
    profile: str | None
    orientation: int
    original_media: str | None = None
    sample: bool = False

    def summary(self) -> dict[str, Any]:
        return {"photoId": self.id, "name": self.name, "width": self.width, "height": self.height,
                "type": self.type, "profile": self.profile, "orientation": self.orientation,
                "original": self.original_media, "sample": self.sample}


class FilmLab:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.schema = ControlSchema(CONTROLS_PATH)
        self.token = args.token or secrets.token_urlsafe(32)
        self.session = Path(tempfile.mkdtemp(prefix="aperture-film-lab-")).resolve()
        os.chmod(self.session, 0o700)
        (self.session / "photos").mkdir(mode=0o700)
        (self.session / "media").mkdir(mode=0o700)
        self.presets_dir = Path(args.presets_dir).expanduser()
        self.presets_lock = threading.Lock()
        self.state_lock = threading.Lock()
        self.photos: collections.OrderedDict[str, Photo] = collections.OrderedDict()
        self.media: collections.OrderedDict[str, Path] = collections.OrderedDict()
        self.preview_media: collections.deque[str] = collections.deque()
        self.worker = RendererWorker(
            Path(args.renderer), self.session, self.schema, recycle_after=args.recycle_after,
            timeout=args.job_timeout, max_pixels=args.max_pixels, test_hooks=args.test_hooks,
        )
        self.scheduler = Scheduler(self)
        self.git_commit = self._git_commit()
        self.renderer_description = f"FilmProcessor.shared on macOS {platform.mac_ver()[0] or platform.release()} ({platform.machine()})"
        self.allowed_hosts: set[str] = set()
        self.allowed_origins: set[str] = set()
        self.cleaned = False
        self.upload_slots = threading.BoundedSemaphore(MAX_CONCURRENT_UPLOADS)

    # Lifecycle -----------------------------------------------------------

    def start(self, port: int, extra_hosts: list[str]) -> None:
        for host in ("127.0.0.1", "localhost"):
            self.allowed_hosts.add(f"{host}:{port}")
            self.allowed_origins.add(f"http://{host}:{port}")
        for host in extra_hosts:
            self.add_https_host(host)
        self.worker.start()
        self.scheduler.start()

    def add_https_host(self, host: str) -> None:
        """A tailnet name reached through `tailscale serve` (HTTPS)."""
        self.allowed_hosts.add(host)
        self.allowed_origins.add(f"https://{host}")
        if host.endswith(":443"):
            bare = host[: -len(":443")]
            self.allowed_hosts.add(bare)
            self.allowed_origins.add(f"https://{bare}")

    def cleanup(self) -> None:
        if self.cleaned:
            return
        self.cleaned = True
        self.scheduler.stop()
        self.worker.stop()
        shutil.rmtree(self.session, ignore_errors=True)
        log(f"removed session directory {self.session}")

    def _git_commit(self) -> str | None:
        try:
            result = subprocess.run(["git", "-C", str(REPO_DIR), "rev-parse", "HEAD"], capture_output=True, text=True, timeout=5)
        except (OSError, subprocess.SubprocessError):
            return None
        commit = result.stdout.strip()
        return commit if re.fullmatch(r"[0-9a-f]{40}", commit) else None

    # Media ---------------------------------------------------------------

    def new_media(self, prefix: str) -> tuple[str, Path]:
        name = f"{prefix}-{secrets.token_hex(6)}.jpg"
        return name, self.session / "media" / name

    def register_media(self, name: str, path: Path, *, preview: bool) -> None:
        with self.state_lock:
            self.media[name] = path
            if preview:
                self.preview_media.append(name)
                while len(self.preview_media) > MAX_RETAINED_PREVIEWS:
                    self._drop_media(self.preview_media.popleft())

    def _drop_media(self, name: str) -> None:
        path = self.media.pop(name, None)
        if path is not None:
            try:
                path.unlink()
            except FileNotFoundError:
                pass

    def media_path(self, name: str) -> Path | None:
        with self.state_lock:
            return self.media.get(name)

    def trim_jobs(self) -> None:
        with self.scheduler.condition:
            finished = [job for job in self.scheduler.jobs.values() if job.status in ("done", "failed")]
            excess = len(self.scheduler.jobs) - MAX_RETAINED_JOBS
            doomed = finished[: max(0, excess)]
            for job in doomed:
                self.scheduler.jobs.pop(job.id, None)
        with self.state_lock:
            for job in doomed:
                for result in job.results:
                    self._drop_media(result.get("media", ""))

    # Photos --------------------------------------------------------------

    def add_photo(self, data_path: Path, display_name: str, sample: bool = False) -> Photo:
        with self.state_lock:
            if len(self.photos) >= MAX_PHOTOS:
                data_path.unlink(missing_ok=True)
                raise LabError(409, "too-many-photos", f"The reference set holds at most {MAX_PHOTOS} photos; remove one first.")
        photo_id = f"i-{secrets.token_hex(6)}"
        # If the request gives up waiting, the queued task may still run later.
        # Whichever side sees the other first (under state_lock) discards the
        # original preview, so an abandoned upload never leaves owned media.
        abandoned = False
        registered: list[str] = []

        def inspect_and_preview() -> Photo:
            with self.state_lock:
                if abandoned:
                    raise LabError(504, "timeout", "The upload was abandoned.")
            info = self.worker.call({"op": "inspect", "source": str(data_path)})
            media_name, media_path = self.new_media(f"{photo_id}-original")
            try:
                self.worker.call({
                    "op": "original", "source": str(data_path), "output": str(media_path),
                    "size": {"kind": "preview", "maxDimension": ORIGINAL_PREVIEW_DIMENSION},
                }, counts_as_render=True)
            except BaseException:
                media_path.unlink(missing_ok=True)
                raise
            with self.state_lock:
                if abandoned:
                    media_path.unlink(missing_ok=True)
                    raise LabError(504, "timeout", "The upload was abandoned.")
                self.media[media_name] = media_path
                registered.append(media_name)
            return Photo(photo_id, display_name, data_path, int(info["width"]), int(info["height"]),
                         str(info["type"]), info.get("profileName"), int(info.get("orientation", 1)),
                         media_name, sample)

        try:
            photo = self.scheduler.submit_task(inspect_and_preview).wait(self.args.job_timeout + 10)
        except (LabError, WorkerFailure):
            with self.state_lock:
                abandoned = True
                for name in registered:
                    self._drop_media(name)
            data_path.unlink(missing_ok=True)
            raise
        with self.state_lock:
            if len(self.photos) >= MAX_PHOTOS:
                data_path.unlink(missing_ok=True)
                self._drop_media(photo.original_media or "")
                raise LabError(409, "too-many-photos", f"The reference set holds at most {MAX_PHOTOS} photos.")
            self.photos[photo.id] = photo
        return photo

    def remove_photo(self, photo_id: str) -> None:
        with self.state_lock:
            photo = self.photos.pop(photo_id, None)
            if photo is None:
                raise LabError(404, "unknown-photo", "That photo is no longer in the reference set.")
            self._drop_media(photo.original_media or "")
        photo.path.unlink(missing_ok=True)

    def photo(self, photo_id: Any) -> Photo:
        if not isinstance(photo_id, str) or not ID_PATTERN.match(photo_id):
            raise LabError(400, "unknown-photo", "Unknown photo.")
        with self.state_lock:
            photo = self.photos.get(photo_id)
        if photo is None:
            raise LabError(404, "unknown-photo", "That photo is no longer in the reference set.")
        return photo

    # Rendering -----------------------------------------------------------

    def render_preview(self, request: dict[str, Any]) -> dict[str, Any]:
        photo = self.photo(request["photoId"])
        media_name, media_path = self.new_media("preview")
        result = self.worker.call({
            "op": "render", "source": str(photo.path), "output": str(media_path),
            "controls": request["controls"], "context": request["context"],
            "size": {"kind": "preview", "maxDimension": request["maxDimension"]},
        }, counts_as_render=True)
        self.register_media(media_name, media_path, preview=True)
        return {"status": "done", "photoId": photo.id, "photoGeneration": request["photoGeneration"],
                "settingsGeneration": request["settingsGeneration"], "media": media_name,
                "workerPid": self.worker.pid, **result}

    def render_explicit(self, job: ExplicitJob, photo_id: str) -> dict[str, Any]:
        try:
            photo = self.photo(photo_id)
        except LabError as error:
            return {"photoId": photo_id, "error": error.payload()["error"]}
        media_name, media_path = self.new_media(f"{job.kind}")
        size = {"kind": "full"} if job.kind == "full" else {"kind": "preview", "maxDimension": BATCH_PREVIEW_DIMENSION}
        result = self.worker.call({
            "op": "render", "source": str(photo.path), "output": str(media_path),
            "controls": job.controls, "context": job.context, "size": size,
        }, counts_as_render=True)
        self.register_media(media_name, media_path, preview=False)
        return {"photoId": photo.id, "name": photo.name, "media": media_name, **result}

    def provenance(self) -> dict[str, Any]:
        provenance: dict[str, Any] = {"tool": TOOL_NAME, "toolVersion": TOOL_VERSION, "createdAt": utc_now(),
                                      "renderer": self.renderer_description}
        if self.git_commit:
            provenance["gitCommit"] = self.git_commit
        return provenance

    def worker_task(self, request: dict[str, Any]) -> dict[str, Any]:
        return self.scheduler.submit_task(lambda: self.worker.call(request)).wait(self.args.job_timeout + 10)

    def candidate(self, name: str, controls: dict[str, Any], context: dict[str, str]) -> dict[str, Any]:
        return self.worker_task({"op": "candidate", "name": name, "controls": controls, "context": context,
                                 "provenance": self.provenance()})

    # Presets -------------------------------------------------------------

    def ensure_presets_dir(self) -> Path:
        self.presets_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        return self.presets_dir

    def list_presets(self) -> list[dict[str, Any]]:
        if not self.presets_dir.is_dir():
            return []
        presets = []
        for path in sorted(self.presets_dir.glob("p-*.json")):
            if not PRESET_ID_PATTERN.match(path.stem) or path.is_symlink():
                continue
            try:
                if path.stat().st_size > MAX_JSON_BYTES:
                    continue
                document = json.loads(path.read_text("utf-8"))
                name = document["name"]
                created = (document.get("provenance") or {}).get("createdAt")
            except (OSError, ValueError, KeyError, TypeError, RecursionError):
                presets.append({"presetId": path.stem, "name": None, "valid": False})
                continue
            presets.append({"presetId": path.stem, "name": name if isinstance(name, str) else None,
                             "createdAt": created, "valid": isinstance(name, str)})
        presets.sort(key=lambda preset: (preset["name"] or "").casefold())
        return presets

    def preset_path(self, preset_id: Any) -> Path:
        if not isinstance(preset_id, str) or not PRESET_ID_PATTERN.match(preset_id):
            raise LabError(400, "unknown-preset", "Unknown look id.")
        return self.presets_dir / f"{preset_id}.json"

    def save_preset(self, name: str, controls: dict[str, Any], context: dict[str, str], replace_id: str | None) -> dict[str, Any]:
        made = self.candidate(name, controls, context)
        canonical_name = made["name"]
        text: str = made["text"]
        with self.presets_lock:
            directory = self.ensure_presets_dir()
            clash = next((p for p in self.list_presets() if (p["name"] or "").casefold() == canonical_name.casefold()), None)
            if replace_id is not None:
                target = self.preset_path(replace_id)
                if not target.is_file() or target.is_symlink():
                    raise LabError(404, "unknown-preset", "The look to replace no longer exists.")
                if clash and clash["presetId"] != replace_id:
                    raise LabError(409, "name-exists", f"Another look is already named {canonical_name!r}.", presetId=clash["presetId"])
                self._write_atomically(directory, target, text, exclusive=False)
                return {"presetId": replace_id, "name": canonical_name, "replaced": True}
            if clash:
                raise LabError(409, "name-exists", f"A look named {canonical_name!r} already exists; replace it explicitly or choose another name.", presetId=clash["presetId"])
            for _ in range(8):
                preset_id = f"p-{secrets.token_hex(8)}"
                target = directory / f"{preset_id}.json"
                try:
                    self._write_atomically(directory, target, text, exclusive=True)
                except FileExistsError:
                    continue
                return {"presetId": preset_id, "name": canonical_name, "replaced": False}
        raise LabError(500, "preset-id", "Could not allocate a look id.")

    @staticmethod
    def _write_atomically(directory: Path, target: Path, text: str, *, exclusive: bool) -> None:
        descriptor, temporary = tempfile.mkstemp(prefix=".tmp-", suffix=".json", dir=directory)
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                handle.write(text)
                handle.flush()
                os.fsync(handle.fileno())
            os.chmod(temporary, 0o600)
            if exclusive:
                os.link(temporary, target)  # Fails if the target exists: never overwrites.
                os.unlink(temporary)
            else:
                os.replace(temporary, target)
        except BaseException:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass
            raise

    def load_preset(self, preset_id: str) -> dict[str, Any]:
        path = self.preset_path(preset_id)
        if not path.is_file() or path.is_symlink():
            raise LabError(404, "unknown-preset", "That look no longer exists.")
        if path.stat().st_size > MAX_JSON_BYTES:
            raise LabError(422, "invalid-candidate", "The saved look is too large.")
        text = path.read_text("utf-8")
        result = self.worker_task({"op": "import", "text": text})
        return {"presetId": preset_id, **result}

    def delete_preset(self, preset_id: str) -> None:
        path = self.preset_path(preset_id)
        with self.presets_lock:
            if not path.is_file() or path.is_symlink():
                raise LabError(404, "unknown-preset", "That look no longer exists.")
            path.unlink()


# --------------------------------------------------------------------------
# HTTP
# --------------------------------------------------------------------------


SECURITY_HEADERS = {
    "Content-Security-Policy": (
        "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' blob:; "
        "connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
    ),
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer",
    "X-Frame-Options": "DENY",
    "Cross-Origin-Resource-Policy": "same-origin",
    "Cross-Origin-Opener-Policy": "same-origin",
    "Cache-Control": "no-store",
}


def make_handler(lab: FilmLab) -> type[http.server.BaseHTTPRequestHandler]:
    class Handler(http.server.BaseHTTPRequestHandler):
        server_version = "FilmLab"
        sys_version = ""
        protocol_version = "HTTP/1.1"
        timeout = 60

        def log_message(self, format: str, *args: Any) -> None:  # noqa: A002
            if lab.args.verbose:
                log(format % args)

        # Responses ---------------------------------------------------------

        def send_body(self, status: int, body: bytes, content_type: str, extra: dict[str, str] | None = None) -> None:
            self.send_response(status)
            for key, value in SECURITY_HEADERS.items():
                self.send_header(key, value)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            for key, value in (extra or {}).items():
                self.send_header(key, value)
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)

        def send_json(self, status: int, payload: Any) -> None:
            body = json.dumps(payload, separators=(",", ":"), allow_nan=False).encode("utf-8")
            self.send_body(status, body, "application/json; charset=utf-8")

        def send_error_payload(self, error: LabError) -> None:
            self.send_json(error.status, error.payload())

        # Gatekeeping -------------------------------------------------------

        def check_host_and_origin(self, *, mutating: bool) -> None:
            host = self.headers.get("Host", "")
            if host not in lab.allowed_hosts:
                raise LabError(421, "bad-host", "Unexpected Host header.")
            origin = self.headers.get("Origin")
            if origin is not None and origin not in lab.allowed_origins:
                raise LabError(403, "bad-origin", "Cross-origin requests are not allowed.")
            if mutating and origin is None:
                raise LabError(403, "bad-origin", "An Origin header is required.")
            if self.headers.get("Sec-Fetch-Site") == "cross-site":
                raise LabError(403, "bad-origin", "Cross-site requests are not allowed.")

        def check_token(self) -> None:
            supplied = self.headers.get("X-Film-Lab-Token", "")
            if not hmac.compare_digest(supplied.encode("utf-8"), lab.token.encode("utf-8")):
                raise LabError(401, "bad-token", "Missing or invalid session token; reopen the URL printed by run.sh.")

        def discard_body(self, limit: int) -> None:
            """Read and drop a refused request's body in small chunks, so the
            client still gets the answer without the server retaining it."""
            length_header = self.headers.get("Content-Length")
            if self.headers.get("Transfer-Encoding") or length_header is None or not length_header.isdigit() \
                    or int(length_header) > limit:
                self.close_connection = True
                return
            remaining = int(length_header)
            try:
                while remaining > 0:
                    chunk = self.rfile.read(min(remaining, 64 * 1024))
                    if not chunk:
                        break
                    remaining -= len(chunk)
            except OSError:
                pass
            if remaining:
                self.close_connection = True

        def read_body(self, limit: int) -> bytes:
            if self.headers.get("Transfer-Encoding"):
                raise LabError(411, "length-required", "Chunked uploads are not supported.")
            length_header = self.headers.get("Content-Length")
            if length_header is None or not length_header.isdigit():
                raise LabError(411, "length-required", "Content-Length is required.")
            length = int(length_header)
            if length > limit:
                self.close_connection = True
                raise LabError(413, "too-large", f"The request is larger than {limit // 1024} KB.")
            data = self.rfile.read(length)
            if len(data) != length:
                raise LabError(400, "truncated", "The request body was truncated.")
            return data

        def read_json(self) -> Any:
            content_type = self.headers.get("Content-Type", "")
            if not content_type.startswith("application/json"):
                raise LabError(415, "unsupported-media-type", "Send application/json.")
            return parse_json_body(self.read_body(MAX_JSON_BYTES))

        # Dispatch ----------------------------------------------------------

        def do_GET(self) -> None:  # noqa: N802
            self.dispatch("GET")

        def do_HEAD(self) -> None:  # noqa: N802
            self.dispatch("HEAD")

        def do_POST(self) -> None:  # noqa: N802
            self.dispatch("POST")

        def do_DELETE(self) -> None:  # noqa: N802
            self.dispatch("DELETE")

        def do_PUT(self) -> None:  # noqa: N802
            self.dispatch("PUT")

        def do_OPTIONS(self) -> None:  # noqa: N802
            # No CORS: preflights are refused outright.
            self.dispatch("OPTIONS")

        def dispatch(self, method: str) -> None:
            try:
                path = urllib.parse.urlsplit(self.path).path
                if method not in ("GET", "HEAD", "POST", "DELETE"):
                    raise LabError(405, "method-not-allowed", "Method not allowed.")
                self.check_host_and_origin(mutating=method in ("POST", "DELETE"))
                if path in STATIC_FILES and method in ("GET", "HEAD"):
                    self.serve_static(path)
                    return
                if path.startswith("/api/") or path.startswith("/media/"):
                    self.check_token()
                    self.route(method, path)
                    return
                raise LabError(404, "not-found", "Not found.")
            except LabError as error:
                # An unread request body must never be parsed as the next request.
                self.close_connection = True
                self.send_error_payload(error)
            except WorkerFailure as error:
                self.close_connection = True
                self.send_json(503, {"error": {"code": error.code, "message": error.message}})
            except (BrokenPipeError, ConnectionResetError):
                pass
            except Exception:  # noqa: BLE001
                traceback.print_exc()
                self.close_connection = True
                self.send_json(500, {"error": {"code": "internal", "message": "Internal error."}})

        def serve_static(self, path: str) -> None:
            file_name, content_type = STATIC_FILES[path]
            body = (WEB_DIR / file_name).read_bytes()
            self.send_body(200, body, content_type)

        def route(self, method: str, path: str) -> None:
            parts = path.strip("/").split("/")
            if parts[0] == "media" and len(parts) == 2 and method in ("GET", "HEAD"):
                self.serve_media(parts[1])
                return
            key = (method, "/".join(parts[1:3]) if len(parts) > 2 else parts[1] if len(parts) > 1 else "")
            routes: dict[tuple[str, str], Callable[[list[str]], None]] = {
                ("GET", "session"): self.get_session,
                ("POST", "photos"): self.post_photo,
                ("POST", "samples"): self.post_samples,
                ("POST", "resolve"): self.post_resolve,
                ("POST", "preview"): self.post_preview,
                ("POST", "jobs"): self.post_job,
                ("POST", "export"): self.post_export,
                ("POST", "import"): self.post_import,
                ("GET", "presets"): self.get_presets,
                ("POST", "presets"): self.post_preset,
            }
            if key in routes and len(parts) == 2:
                routes[key](parts)
                return
            if lab.args.test_hooks and len(parts) == 3 and parts[1] == "_test":
                self.test_hook(method, parts[2])
                return
            if len(parts) == 3 and parts[1] == "photos" and method == "DELETE":
                lab.remove_photo(lab.photo(parts[2]).id)
                self.send_json(200, {"removed": parts[2]})
                return
            if len(parts) == 3 and parts[1] == "jobs" and method == "GET":
                job = lab.scheduler.job(parts[2]) if ID_PATTERN.match(parts[2]) else None
                if job is None:
                    raise LabError(404, "unknown-job", "Unknown or expired job.")
                self.send_json(200, job.summary())
                return
            if len(parts) == 3 and parts[1] == "presets" and method == "GET":
                self.send_json(200, lab.load_preset(parts[2]))
                return
            if len(parts) == 3 and parts[1] == "presets" and method == "DELETE":
                body = self.read_json()
                if not isinstance(body, dict) or body.get("confirm") is not True:
                    raise LabError(400, "confirm-required", "Deleting a look requires confirmation.")
                lab.delete_preset(parts[2])
                self.send_json(200, {"deleted": parts[2]})
                return
            raise LabError(404, "not-found", "Not found.")

        # Handlers ----------------------------------------------------------

        def test_hook(self, method: str, name: str) -> None:
            """Only with --test-hooks: lets the suite crash or stall the renderer
            through the real job thread and observe the queues."""
            if method == "GET" and name == "state":
                worker = lab.worker
                with lab.state_lock:
                    media = sorted(lab.media)
                self.send_json(200, {"pid": worker.pid, "starts": worker.starts,
                                     "rendersSinceStart": worker.renders_since_start,
                                     "depth": lab.scheduler.depth(), "busy": lab.scheduler.busy,
                                     "media": media, "session": str(lab.session)})
            elif method == "POST" and name in ("crash", "sleep"):
                body = self.read_json()
                request: dict[str, Any] = {"op": name}
                if name == "sleep":
                    request["milliseconds"] = int(body.get("milliseconds", 0)) if isinstance(body, dict) else 0
                future = lab.scheduler.submit_task(lambda: lab.worker.call(request))
                if isinstance(body, dict) and body.get("wait") is False:
                    self.send_json(202, {"queued": True})
                    return
                try:
                    self.send_json(200, future.wait(lab.args.job_timeout + 10))
                except WorkerFailure as error:
                    self.send_json(200, {"failure": error.code})
            else:
                raise LabError(404, "not-found", "Not found.")

        def serve_media(self, name: str) -> None:
            media = lab.media_path(name) if re.fullmatch(r"[a-z0-9-]{1,80}\.jpg", name) else None
            if media is None or not media.is_file():
                raise LabError(404, "unknown-media", "That render has expired; render it again.")
            body = media.read_bytes()
            query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
            extra = {}
            if query.get("download") == ["1"]:
                extra["Content-Disposition"] = f'attachment; filename="{name}"'
            self.send_body(200, body, "image/jpeg", extra)

        def get_session(self, _: list[str]) -> None:
            with lab.state_lock:
                photos = [photo.summary() for photo in lab.photos.values()]
            self.send_json(200, {
                "controls": json.loads(lab.schema.raw), "controlSchemaDigest": lab.schema.digest,
                "baseRecipe": {"id": lab.worker.hello.get("baseRecipeId"), "version": lab.worker.hello.get("baseRecipeVersion"),
                               "fingerprint": lab.worker.hello.get("baseRecipeFingerprint")},
                "photos": photos, "samples": list(SAMPLE_NAMES), "presetsDir": str(lab.presets_dir),
                "limits": {"maxPhotos": MAX_PHOTOS, "maxUploadBytes": MAX_UPLOAD_BYTES,
                           "maxPixels": lab.args.max_pixels or 60_000_000,
                           "previewDimensions": list(PREVIEW_DIMENSIONS),
                           "defaultPreviewDimension": DEFAULT_PREVIEW_DIMENSION},
                "renderer": lab.renderer_description,
            })

        def post_photo(self, _: list[str]) -> None:
            # Refuse before reading the body, so neither a full reference set
            # nor concurrent uploads can hold more than a bounded amount of memory.
            with lab.state_lock:
                full = len(lab.photos) >= MAX_PHOTOS
            if full:
                self.discard_body(MAX_UPLOAD_BYTES)
                raise LabError(409, "too-many-photos", f"The reference set holds at most {MAX_PHOTOS} photos; remove one first.")
            if not lab.upload_slots.acquire(blocking=False):
                self.discard_body(MAX_UPLOAD_BYTES)
                raise LabError(429, "busy", "Another upload is in progress; try again.")
            try:
                data = self.read_body(MAX_UPLOAD_BYTES)
                extension = sniff_image(data[:16])
                if extension is None:
                    raise LabError(415, "unsupported-image", "Only JPEG, PNG and HEIC photographs are supported.")
                raw_name = urllib.parse.unquote(self.headers.get("X-Film-Lab-Filename", "photo"))
                display = "".join(c for c in raw_name if c.isprintable())[:MAX_NAME_LENGTH] or "photo"
                path = lab.session / "photos" / f"u-{secrets.token_hex(8)}.{extension}"
                with open(path, "xb") as handle:
                    handle.write(data)
                os.chmod(path, 0o600)
                del data
            finally:
                lab.upload_slots.release()
            photo = lab.add_photo(path, display)
            self.send_json(201, photo.summary())

        def post_samples(self, _: list[str]) -> None:
            body = self.read_json()
            names = body.get("names") if isinstance(body, dict) else None
            if not isinstance(names, list) or not names or any(name not in SAMPLE_NAMES for name in names):
                raise LabError(400, "unknown-sample", f"Samples are {', '.join(SAMPLE_NAMES)}.")
            added = []
            for name in dict.fromkeys(names):
                path = lab.session / "photos" / f"s-{secrets.token_hex(8)}.png"
                shutil.copyfile(FIXTURES_DIR / f"{name}.png", path)
                added.append(lab.add_photo(path, f"{name} (sample)", sample=True).summary())
            self.send_json(201, {"photos": added})

        def settings(self, body: Any) -> tuple[dict[str, Any], dict[str, str]]:
            if not isinstance(body, dict):
                raise LabError(400, "bad-request", "Expected a JSON object.")
            return lab.schema.validate_controls(body.get("controls", {})), lab.schema.validate_context(body.get("context"))

        def post_resolve(self, _: list[str]) -> None:
            controls, context = self.settings(self.read_json())
            self.send_json(200, lab.worker_task({"op": "resolve", "controls": controls, "context": context}))

        def post_preview(self, _: list[str]) -> None:
            body = self.read_json()
            controls, context = self.settings(body)
            generations = [body.get("photoGeneration"), body.get("settingsGeneration")]
            if not all(isinstance(g, int) and not isinstance(g, bool) and 0 <= g < 2**53 for g in generations):
                raise LabError(400, "bad-request", "photoGeneration and settingsGeneration must be non-negative integers.")
            dimension = body.get("maxDimension", DEFAULT_PREVIEW_DIMENSION)
            if isinstance(dimension, bool) or not isinstance(dimension, int) or not PREVIEW_DIMENSIONS[0] <= dimension <= PREVIEW_DIMENSIONS[1]:
                raise LabError(400, "bad-request", "Unsupported preview size.")
            photo = lab.photo(body.get("photoId"))
            future = lab.scheduler.submit_preview({
                "photoId": photo.id, "controls": controls, "context": context, "maxDimension": dimension,
                "photoGeneration": generations[0], "settingsGeneration": generations[1],
            })
            self.send_json(200, future.wait(lab.args.job_timeout * 2 + 10))

        def post_job(self, _: list[str]) -> None:
            body = self.read_json()
            controls, context = self.settings(body)
            kind = body.get("kind")
            revision = body.get("settingsGeneration")
            if kind not in ("full", "batch"):
                raise LabError(400, "bad-request", "kind must be full or batch.")
            if isinstance(revision, bool) or not isinstance(revision, int) or revision < 0:
                raise LabError(400, "bad-request", "settingsGeneration is required.")
            if kind == "full":
                photo_ids = [lab.photo(body.get("photoId")).id]
            else:
                with lab.state_lock:
                    photo_ids = list(lab.photos)
                if not photo_ids:
                    raise LabError(400, "no-photos", "Add photos to the reference set first.")
            job = ExplicitJob(f"j-{secrets.token_hex(6)}", kind, revision, controls, context, photo_ids)
            lab.scheduler.submit_explicit(job)
            self.send_json(202, job.summary())

        def post_export(self, _: list[str]) -> None:
            body = self.read_json()
            controls, context = self.settings(body)
            made = lab.candidate(validate_name(body.get("name")), controls, context)
            file_name = re.sub(r"[^A-Za-z0-9._-]+", "-", made["name"]).strip("-.")[:60] or "look"
            self.send_body(200, made["text"].encode("utf-8"), "application/json; charset=utf-8",
                           {"Content-Disposition": f'attachment; filename="{file_name}.film-lab.json"'})

        def post_import(self, _: list[str]) -> None:
            # The candidate text is passed through untouched: Swift parses and
            # validates it, so a UInt64 seed is never rounded by a JSON number
            # parser on the way.
            content_type = self.headers.get("Content-Type", "")
            if not (content_type.startswith("text/plain") or content_type.startswith("application/json")):
                raise LabError(415, "unsupported-media-type", "Send the candidate file as text.")
            data = self.read_body(MAX_JSON_BYTES)
            try:
                text = data.decode("utf-8")
            except UnicodeDecodeError:
                raise LabError(400, "invalid-json", "The file is not UTF-8 text.") from None
            loads_bounded(text, MAX_CANDIDATE_DEPTH)  # Syntax and depth only; the text itself goes on.
            self.send_json(200, lab.worker_task({"op": "import", "text": text}))

        def get_presets(self, _: list[str]) -> None:
            self.send_json(200, {"presets": lab.list_presets(), "directory": str(lab.presets_dir)})

        def post_preset(self, _: list[str]) -> None:
            body = self.read_json()
            controls, context = self.settings(body)
            replace_id = body.get("replacePresetId")
            if replace_id is not None:
                lab.preset_path(replace_id)
            result = lab.save_preset(validate_name(body.get("name")), controls, context, replace_id)
            self.send_json(201 if not result["replaced"] else 200, result)

    return Handler


class LabHTTPServer(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 16

    def __init__(self, *args: Any, **kwargs: Any) -> None:
        super().__init__(*args, **kwargs)
        self.connection_slots = threading.BoundedSemaphore(MAX_CONNECTIONS)

    def process_request(self, request: Any, client_address: Any) -> None:
        # Bound handler threads (and the request bodies they hold); excess
        # connections are closed rather than queued.
        if not self.connection_slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            self.connection_slots.release()
            raise

    def process_request_thread(self, request: Any, client_address: Any) -> None:
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.connection_slots.release()


# --------------------------------------------------------------------------
# Tailnet (opt-in): `tailscale serve` proxies HTTPS on the tailnet only to
# the loopback listener. Never Funnel.
# --------------------------------------------------------------------------


class Tailnet:
    def __init__(self, port: int) -> None:
        self.port = port
        self.active = False
        self.host = ""

    def start(self) -> str:
        status = json.loads(subprocess.run(["tailscale", "status", "--json"], capture_output=True, text=True, check=True, timeout=20).stdout)
        dns_name = (status.get("Self") or {}).get("DNSName", "").rstrip(".")
        if not dns_name:
            raise RuntimeError("tailscale reports no DNS name for this node")
        serve = json.loads(subprocess.run(["tailscale", "serve", "status", "--json"], capture_output=True, text=True, check=True, timeout=20).stdout or "{}")
        if str(self.port) in (serve.get("TCP") or {}):
            raise RuntimeError(f"tailscale serve already uses port {self.port}; choose another --port")
        subprocess.run(["tailscale", "serve", "--bg", f"--https={self.port}", f"http://127.0.0.1:{self.port}"],
                       capture_output=True, text=True, check=True, timeout=30)
        self.active = True
        self.host = f"{dns_name}:{self.port}"
        return self.host

    def stop(self) -> None:
        if not self.active:
            return
        self.active = False
        subprocess.run(["tailscale", "serve", f"--https={self.port}", "off"], capture_output=True, text=True, timeout=30)
        log(f"stopped tailscale serve on port {self.port}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Local Film Lab for Aperture's 1998 recipe")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--renderer", default=str(DEFAULT_RENDERER))
    parser.add_argument("--presets-dir", default=os.environ.get("FILM_LAB_PRESETS_DIR", str(DEFAULT_PRESETS_DIR)))
    parser.add_argument("--recycle-after", type=int, default=250, help="restart the renderer after this many renders (0 = never)")
    parser.add_argument("--job-timeout", type=float, default=120.0)
    parser.add_argument("--max-pixels", type=int, default=None)
    parser.add_argument("--tailnet", action="store_true", help="also expose over this tailnet via tailscale serve (HTTPS, tailnet only)")
    parser.add_argument("--test-hooks", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--token", default=None, help=argparse.SUPPRESS)
    parser.add_argument("--ready-file", default=None, help=argparse.SUPPRESS)
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args(argv)
    if not 1024 <= args.port <= 65535:
        parser.error("--port must be 1024–65535")
    if not Path(args.renderer).is_file():
        parser.error(f"renderer not built: {args.renderer} (run tools/film-lab/build.sh)")

    lab = FilmLab(args)
    tailnet = Tailnet(args.port) if args.tailnet else None
    server: LabHTTPServer | None = None

    def cleanup() -> None:
        if tailnet:
            tailnet.stop()
        lab.cleanup()

    atexit.register(cleanup)

    def on_signal(signum: int, _frame: Any) -> None:
        log(f"received signal {signum}; shutting down")
        if server is not None:
            threading.Thread(target=server.shutdown, daemon=True).start()
        else:
            cleanup()
            sys.exit(0)

    signal.signal(signal.SIGINT, on_signal)
    signal.signal(signal.SIGTERM, on_signal)

    server = LabHTTPServer(("127.0.0.1", args.port), make_handler(lab))
    lab.start(args.port, [])
    urls = {"local": f"http://127.0.0.1:{args.port}/#token={lab.token}"}
    if tailnet:
        try:
            host = tailnet.start()
            lab.add_https_host(host)
            urls["tailnet"] = f"https://{host}/#token={lab.token}"
        except (OSError, subprocess.SubprocessError, RuntimeError, ValueError) as error:
            log(f"tailnet exposure unavailable: {error}")
    log(f"session directory {lab.session} (removed on exit)")
    log(f"presets directory {lab.presets_dir}")
    for label, url in urls.items():
        print(f"Film Lab ({label}): {url}", flush=True)
    if args.ready_file:
        # Owner-only: the file carries the session capability.
        descriptor = os.open(args.ready_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump({**urls, "token": lab.token, "session": str(lab.session), "pid": os.getpid()}, handle)
    try:
        server.serve_forever(poll_interval=0.25)
    finally:
        server.server_close()
        cleanup()
    return 0


if __name__ == "__main__":
    sys.exit(main())
