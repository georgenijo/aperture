"""End-to-end tests for the Film Lab server with the real renderer.

Run from the repository root after tools/film-lab/build.sh:
    python3 -m unittest discover -s tools/film-lab/tests -v
"""

from __future__ import annotations

import http.client
import json
import os
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from typing import Any

TOOL_DIR = Path(__file__).resolve().parents[1]
SERVER = TOOL_DIR / "server.py"
RENDERER = TOOL_DIR / ".build" / "film-lab-renderer"
FIXTURES = TOOL_DIR.parents[1] / "ApertureTests" / "Fixtures"
SAMPLES = ["day-portrait", "night-flash", "hdr-still-life"]
BIG_SEED = "18446744073709551615"  # UInt64.max: not representable as a JS/float64 number.
RECYCLE_AFTER = 4
JOB_TIMEOUT = 8


def free_port() -> int:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def jpeg_size(data: bytes) -> tuple[int, int]:
    """Width and height from the first SOF marker of a baseline/progressive JPEG."""
    assert data[:2] == b"\xff\xd8", "not a JPEG"
    index = 2
    while index < len(data):
        if data[index] != 0xFF:
            raise AssertionError("bad JPEG marker")
        marker = data[index + 1]
        length = int.from_bytes(data[index + 2:index + 4], "big")
        if marker in (0xC0, 0xC1, 0xC2):
            height = int.from_bytes(data[index + 5:index + 7], "big")
            width = int.from_bytes(data[index + 7:index + 9], "big")
            return width, height
        index += 2 + length
    raise AssertionError("no SOF marker")


def exif_tags(data: bytes) -> set[int]:
    """Every tag in the JPEG's Exif block (IFD0 and the Exif/GPS sub-IFDs,
    pointers excluded), so a test can prove no camera metadata survived."""
    index = 2
    while index + 4 <= len(data) and data[index] == 0xFF:
        marker = data[index + 1]
        length = int.from_bytes(data[index + 2:index + 4], "big")
        segment = data[index + 4:index + 2 + length]
        if marker == 0xE1 and segment.startswith(b"Exif\x00\x00"):
            tiff = segment[6:]
            order = "big" if tiff[:2] == b"MM" else "little"

            def u16(offset: int) -> int:
                return int.from_bytes(tiff[offset:offset + 2], order)

            def u32(offset: int) -> int:
                return int.from_bytes(tiff[offset:offset + 4], order)

            tags: set[int] = set()
            pending = [u32(4)]
            seen: set[int] = set()
            while pending:
                ifd = pending.pop()
                if ifd in seen or ifd + 2 > len(tiff):
                    continue
                seen.add(ifd)
                for entry in range(u16(ifd)):
                    base = ifd + 2 + entry * 12
                    tag = u16(base)
                    if tag in (0x8769, 0x8825, 0xA005):  # Exif, GPS, interop pointers
                        pending.append(u32(base + 8))
                        if tag == 0x8825:
                            tags.add(tag)
                    else:
                        tags.add(tag)
            return tags
        if marker in (0xDA, 0xD9):
            break
        index += 2 + length
    return set()


class Response:
    def __init__(self, status: int, headers: dict[str, str], body: bytes) -> None:
        self.status = status
        self.headers = headers
        self.body = body

    def json(self) -> Any:
        return json.loads(self.body)

    @property
    def code(self) -> str | None:
        try:
            return self.json()["error"]["code"]
        except (ValueError, KeyError, TypeError):
            return None


class LabServer:
    def __init__(self, *extra: str) -> None:
        self.port = free_port()
        self.temp = Path(tempfile.mkdtemp(prefix="film-lab-test-"))
        self.presets = self.temp / "presets"
        ready = self.temp / "ready.json"
        self.process = subprocess.Popen(
            [sys.executable, str(SERVER), "--port", str(self.port), "--presets-dir", str(self.presets),
             "--recycle-after", str(RECYCLE_AFTER), "--job-timeout", str(JOB_TIMEOUT), "--test-hooks",
             "--ready-file", str(ready), *extra],
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True,
        )
        self.stderr: list[str] = []
        threading.Thread(target=self._drain, daemon=True).start()
        deadline = time.monotonic() + 60
        while not ready.exists() or not ready.stat().st_size:
            if self.process.poll() is not None or time.monotonic() > deadline:
                raise RuntimeError("server did not start:\n" + "".join(self.stderr))
            time.sleep(0.05)
        time.sleep(0.05)
        info = json.loads(ready.read_text())
        self.ready_mode = stat.S_IMODE(ready.stat().st_mode)
        self.token: str = info["token"]
        self.session = Path(info["session"])
        self.origin = f"http://127.0.0.1:{self.port}"

    def _drain(self) -> None:
        assert self.process.stderr is not None
        for line in self.process.stderr:
            self.stderr.append(line)

    def request(self, method: str, path: str, body: Any = None, *, token: bool = True,
                origin: str | None | bool = True, host: str | None = None,
                headers: dict[str, str] | None = None, raw: bytes | None = None,
                content_type: str | None = None, timeout: float = 60) -> Response:
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=timeout)
        all_headers: dict[str, str] = {"Host": f"127.0.0.1:{self.port}" if host is None else host}
        if token:
            all_headers["X-Film-Lab-Token"] = self.token
        if origin is True:
            all_headers["Origin"] = self.origin
        elif isinstance(origin, str):
            all_headers["Origin"] = origin
        payload: bytes | None = raw
        if body is not None:
            payload = json.dumps(body).encode()
            all_headers["Content-Type"] = "application/json"
        if content_type:
            all_headers["Content-Type"] = content_type
        all_headers.update(headers or {})
        connection.putrequest(method, path, skip_host=True, skip_accept_encoding=True)
        for key, value in all_headers.items():
            connection.putheader(key, value)
        if payload is not None and "Content-Length" not in all_headers:
            connection.putheader("Content-Length", str(len(payload)))
        connection.endheaders(payload)
        response = connection.getresponse()
        result = Response(response.status, {k.lower(): v for k, v in response.getheaders()}, response.read())
        connection.close()
        return result

    def stop(self) -> int:
        if self.process.poll() is None:
            self.process.send_signal(signal.SIGTERM)
        try:
            return self.process.wait(timeout=20)
        except subprocess.TimeoutExpired:
            self.process.kill()
            return self.process.wait()
        finally:
            if self.process.stderr:
                self.process.stderr.close()


def context(seed: str = "20260915") -> dict[str, str]:
    return {"seed": seed, "capturedAt": "2026-09-15T19:20:00Z", "timeZone": "America/New_York",
            "photoQuality": "balanced"}


@unittest.skipUnless(RENDERER.is_file(), "run tools/film-lab/build.sh first")
class FilmLabServerTests(unittest.TestCase):
    lab: LabServer
    photos: list[dict[str, Any]]

    @classmethod
    def setUpClass(cls) -> None:
        cls.lab = LabServer()
        response = cls.lab.request("POST", "/api/samples", {"names": SAMPLES})
        assert response.status == 201, response.body
        cls.photos = response.json()["photos"]

    @classmethod
    def tearDownClass(cls) -> None:
        cls.lab.stop()

    # Helpers -------------------------------------------------------------
    def preview(self, controls: dict[str, Any] | None = None, *, photo: int = 0, generation: int = 1,
                seed: str = "20260915", size: int = 512) -> Response:
        return self.lab.request("POST", "/api/preview", {
            "photoId": self.photos[photo]["photoId"], "controls": controls or {}, "context": context(seed),
            "photoGeneration": 1, "settingsGeneration": generation, "maxDimension": size})

    def media(self, name: str) -> bytes:
        response = self.lab.request("GET", f"/media/{name}", origin=None)
        self.assertEqual(response.status, 200, response.body)
        return response.body

    def state(self) -> dict[str, Any]:
        return self.lab.request("GET", "/api/_test/state", origin=None).json()

    def run_job(self, body: dict[str, Any]) -> dict[str, Any]:
        response = self.lab.request("POST", "/api/jobs", body)
        self.assertEqual(response.status, 202, response.body)
        job_id = response.json()["jobId"]
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            job = self.lab.request("GET", f"/api/jobs/{job_id}", origin=None).json()
            if job["status"] in ("done", "failed"):
                return job
            time.sleep(0.1)
        self.fail("job did not finish")

    def wait_idle(self) -> None:
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            state = self.state()
            if not state["busy"] and not any(state["depth"].values()):
                return
            time.sleep(0.05)
        self.fail("scheduler did not become idle")

    # Static files and gatekeeping ---------------------------------------------
    def test_static_allowlist_and_headers(self) -> None:
        response = self.lab.request("GET", "/", token=False, origin=None)
        self.assertEqual(response.status, 200)
        self.assertIn(b"Aperture Film Lab", response.body)
        csp = response.headers["content-security-policy"]
        self.assertIn("default-src 'none'", csp)
        self.assertIn("script-src 'self'", csp)
        self.assertEqual(response.headers["x-content-type-options"], "nosniff")
        self.assertNotIn("access-control-allow-origin", response.headers)
        for path in ("/server.py", "/controls.json", "/web/app.js", "/../server.py", "/%2e%2e/server.py",
                     "/.build/film-lab-renderer", "/tests/test_server.py"):
            self.assertEqual(self.lab.request("GET", path, token=False, origin=None).status, 404, path)
        self.assertEqual(self.lab.request("GET", "/app.js", token=False, origin=None).status, 200)

    def test_host_header_is_validated(self) -> None:
        for host in ("evil.example", f"evil.example:{self.lab.port}", f"127.0.0.1:{self.lab.port + 1}", ""):
            response = self.lab.request("GET", "/api/session", host=host, origin=None)
            self.assertEqual(response.status, 421, host)
            self.assertEqual(self.lab.request("GET", "/", host=host, token=False, origin=None).status, 421)
        self.assertEqual(self.lab.request("GET", "/api/session", host=f"localhost:{self.lab.port}", origin=None).status, 200)

    def test_origin_is_validated(self) -> None:
        body = {"controls": {}, "context": context()}
        self.assertEqual(self.lab.request("POST", "/api/resolve", body).status, 200)
        self.assertEqual(self.lab.request("POST", "/api/resolve", body, origin=False).code, "bad-origin")
        for origin in ("http://evil.example", "null", f"http://127.0.0.1:{self.lab.port + 1}", f"https://127.0.0.1:{self.lab.port}"):
            response = self.lab.request("POST", "/api/resolve", body, origin=origin)
            self.assertEqual(response.status, 403, origin)
        response = self.lab.request("GET", "/api/session", origin="http://evil.example")
        self.assertEqual(response.status, 403)
        response = self.lab.request("GET", "/api/session", origin=None, headers={"Sec-Fetch-Site": "cross-site"})
        self.assertEqual(response.status, 403)
        self.assertEqual(self.lab.request("OPTIONS", "/api/session", origin="http://evil.example").status, 405)
        self.assertEqual(self.lab.request("PUT", "/api/presets", body).status, 405)

    def test_capability_token_is_required(self) -> None:
        original = self.photos[0]["original"]
        for path in ("/api/session", f"/media/{original}", "/api/presets"):
            self.assertEqual(self.lab.request("GET", path, token=False, origin=None).status, 401, path)
            wrong = self.lab.request("GET", path, token=False, origin=None,
                                     headers={"X-Film-Lab-Token": self.lab.token[:-1] + "x"})
            self.assertEqual(wrong.status, 401, path)
        self.assertEqual(self.lab.request("GET", f"/media/{original}?token={self.lab.token}", token=False, origin=None).status, 401)
        self.assertEqual(self.lab.ready_mode, 0o600)

    def test_paths_and_ids_are_server_owned(self) -> None:
        for path in ("/media/..%2F..%2Fetc%2Fpasswd", "/media/../server.py", "/media/%2e%2e", "/media/x.png",
                     "/media/" + "a" * 100 + ".jpg", "/media/nonexistent-000000000000.jpg"):
            self.assertIn(self.lab.request("GET", path, origin=None).status, (400, 404), path)
        self.assertEqual(self.lab.request("GET", "/api/presets/..%2F..%2Fx", origin=None).status, 400)
        self.assertEqual(self.lab.request("GET", "/api/jobs/../../x", origin=None).status, 404)
        response = self.lab.request("POST", "/api/preview", {
            "photoId": "../photos/x", "controls": {}, "context": context(), "photoGeneration": 1,
            "settingsGeneration": 1, "maxDimension": 512})
        self.assertEqual(response.code, "unknown-photo")
        # Clients never name renderer paths: unknown fields are ignored, not used.
        response = self.lab.request("POST", "/api/preview", {
            "photoId": self.photos[0]["photoId"], "controls": {}, "context": context(), "photoGeneration": 1,
            "settingsGeneration": 1, "maxDimension": 512, "source": "/etc/passwd", "output": "/tmp/x.jpg"})
        self.assertEqual(response.status, 200, response.body)
        self.assertTrue(response.json()["media"].startswith("preview-"))

    # Limits and validation ------------------------------------------------
    def test_size_limits(self) -> None:
        huge = self.lab.request("POST", "/api/photos", headers={"Content-Length": str(65 * 1024 * 1024)},
                                content_type="image/jpeg", raw=b"")
        self.assertEqual(huge.status, 413)
        big_json = {"controls": {}, "context": context(), "pad": "x" * (300 * 1024)}
        self.assertEqual(self.lab.request("POST", "/api/resolve", big_json).status, 413)
        chunked = self.lab.request("POST", "/api/resolve", headers={"Transfer-Encoding": "chunked"},
                                   content_type="application/json", raw=b"0\r\n\r\n")
        self.assertEqual(chunked.status, 411)
        nested = {"controls": {}, "context": context(), "x": [[[[[[[[[[1]]]]]]]]]]}
        self.assertEqual(self.lab.request("POST", "/api/resolve", nested).code, "invalid-json")
        deep = b"[" * 200_000 + b"]" * 200_000
        self.assertEqual(self.lab.request("POST", "/api/resolve", raw=deep[:250_000], content_type="application/json").code, "invalid-json")
        self.assertEqual(self.lab.request("POST", "/api/import", raw=b"[" * 100_000, content_type="text/plain").code, "invalid-json")
        self.assertEqual(self.lab.request("POST", "/api/resolve", raw=b'{"controls":{"brightness":NaN}}',
                                          content_type="application/json").code, "invalid-json")
        self.assertEqual(self.lab.request("POST", "/api/resolve", raw=b"{}", content_type="text/plain").status, 415)
        for dimension in (100, 5000, "1280", True):
            response = self.lab.request("POST", "/api/preview", {
                "photoId": self.photos[0]["photoId"], "controls": {}, "context": context(),
                "photoGeneration": 1, "settingsGeneration": 1, "maxDimension": dimension})
            self.assertEqual(response.status, 400, dimension)

    def test_controls_and_context_validation(self) -> None:
        def resolve(controls: Any, ctx: Any = None) -> Response:
            return self.lab.request("POST", "/api/resolve", {"controls": controls, "context": ctx or context()})

        self.assertEqual(resolve({"nope": 1}).code, "unknown-control")
        self.assertEqual(resolve({"brightness": 1.5}).code, "control-out-of-range")
        self.assertEqual(resolve({"brightness": "0.5"}).code, "control-kind-mismatch")
        self.assertEqual(resolve({"brightness": True}).code, "control-kind-mismatch")
        self.assertEqual(resolve({"lightLeak": "sometimes"}).code, "control-out-of-range")
        self.assertEqual(resolve([]).code, "bad-controls")
        self.assertEqual(resolve({}, {**context(), "seed": 5}).code, "bad-context")
        self.assertEqual(resolve({}, {**context(), "seed": "18446744073709551616"}).code, "invalid-seed")
        self.assertEqual(resolve({}, {**context(), "seed": "-1"}).code, "invalid-seed")
        self.assertEqual(resolve({}, {**context(), "capturedAt": "yesterday"}).code, "invalid-captured-at")
        self.assertEqual(resolve({}, {**context(), "timeZone": "Mars/Olympus"}).status, 422)
        self.assertEqual(resolve({}, {**context(), "photoQuality": "best"}).code, "invalid-photo-quality")
        extra = dict(context())
        extra["extra"] = "x"
        self.assertEqual(resolve({}, extra).code, "bad-context")
        # Neutral values canonicalise away: an explicit neutral equals unset.
        schema = json.loads((TOOL_DIR / "controls.json").read_text())
        halation_neutral = next(c["neutral"] for c in schema["controls"] if c["id"] == "halation")
        neutral = resolve({"brightness": 0, "halation": halation_neutral, "lightLeak": "baseline"}).json()
        baseline = resolve({}).json()
        self.assertEqual(neutral["appliedFingerprint"], baseline["appliedFingerprint"])
        self.assertTrue(neutral["isBaseline"])
        big = resolve({}, context(BIG_SEED)).json()
        self.assertEqual(big["context"]["seed"], BIG_SEED)
        self.assertIn(f'"seed" : {BIG_SEED}', big["appliedText"])

    def test_invalid_images_are_rejected(self) -> None:
        text = self.lab.request("POST", "/api/photos", raw=b"hello, not an image", content_type="image/jpeg")
        self.assertEqual(text.code, "unsupported-image")
        gif = self.lab.request("POST", "/api/photos", raw=b"GIF89a" + b"\0" * 64, content_type="image/gif")
        self.assertEqual(gif.code, "unsupported-image")
        truncated = (FIXTURES / "day-portrait.png").read_bytes()[:2048]
        response = self.lab.request("POST", "/api/photos", raw=truncated, content_type="image/png")
        self.assertEqual(response.status, 422, response.body)
        fake_jpeg = b"\xff\xd8\xff\xe0" + os.urandom(4096)
        self.assertEqual(self.lab.request("POST", "/api/photos", raw=fake_jpeg, content_type="image/jpeg").status, 422)
        self.assertEqual(len(list((self.lab.session / "photos").iterdir())), len(self.photos) + len(self.extra_photos()))

    def extra_photos(self) -> list[str]:
        session = self.lab.request("GET", "/api/session", origin=None).json()
        known = {photo["photoId"] for photo in self.photos}
        return [photo["photoId"] for photo in session["photos"] if photo["photoId"] not in known]

    def test_upload_and_remove_photo(self) -> None:
        data = (FIXTURES / "night-flash.png").read_bytes()
        response = self.lab.request("POST", "/api/photos", raw=data, content_type="image/png",
                                    headers={"X-Film-Lab-Filename": "my%20photo%0A.png"})
        self.assertEqual(response.status, 201, response.body)
        photo = response.json()
        self.assertEqual(photo["name"], "my photo.png")
        self.assertEqual((photo["width"], photo["height"]), (1024, 768))
        original = self.media(photo["original"])
        self.assertEqual(jpeg_size(original), (1024, 768))
        self.assertEqual(self.lab.request("DELETE", f"/api/photos/{photo['photoId']}").status, 200)
        self.assertEqual(self.lab.request("GET", f"/media/{photo['original']}", origin=None).status, 404)
        self.assertEqual(self.lab.request("DELETE", f"/api/photos/{photo['photoId']}").status, 404)

    # Rendering ------------------------------------------------------------
    def test_preview_echoes_generations_and_is_deterministic(self) -> None:
        first = self.lab.request("POST", "/api/preview", {
            "photoId": self.photos[1]["photoId"], "controls": {"warmth": 0.4}, "context": context(),
            "photoGeneration": 7, "settingsGeneration": 42, "maxDimension": 640}).json()
        self.assertEqual((first["status"], first["photoGeneration"], first["settingsGeneration"]), ("done", 7, 42))
        self.assertEqual(max(first["width"], first["height"]), 640)
        second = self.preview({"warmth": 0.4}, photo=1, size=640).json()
        self.assertEqual(self.media(first["media"]), self.media(second["media"]))
        self.assertFalse(first["isBaseline"])

    def test_newest_preview_wins_and_older_ones_are_superseded(self) -> None:
        self.wait_idle()
        self.assertEqual(self.lab.request("POST", "/api/_test/sleep", {"milliseconds": 1500, "wait": False}).status, 202)
        results: dict[int, Response] = {}

        def send(generation: int) -> None:
            results[generation] = self.preview({"brightness": generation / 10}, generation=generation)

        threads = []
        for generation in (1, 2, 3, 4):
            thread = threading.Thread(target=send, args=(generation,))
            thread.start()
            threads.append(thread)
            time.sleep(0.15)
        for thread in threads:
            thread.join(60)
        statuses = {generation: response.json()["status"] for generation, response in results.items()}
        self.assertEqual(statuses, {1: "superseded", 2: "superseded", 3: "superseded", 4: "done"})
        self.assertEqual(results[2].json()["settingsGeneration"], 2)
        self.assertEqual(results[4].json()["settingsGeneration"], 4)

    def test_queue_bounds(self) -> None:
        self.wait_idle()
        self.lab.request("POST", "/api/_test/sleep", {"milliseconds": 2500, "wait": False})
        time.sleep(0.2)
        body = {"kind": "full", "photoId": self.photos[0]["photoId"], "controls": {}, "context": context(),
                "settingsGeneration": 1}
        accepted = [self.lab.request("POST", "/api/jobs", body) for _ in range(2)]
        self.assertEqual([r.status for r in accepted], [202, 202])
        rejected = self.lab.request("POST", "/api/jobs", body)
        self.assertEqual((rejected.status, rejected.code), (429, "queue-full"))
        statuses = [self.lab.request("POST", "/api/_test/sleep", {"milliseconds": 0, "wait": False}).status
                    for _ in range(17)]
        self.assertEqual(statuses[:16], [202] * 16)
        self.assertEqual(statuses[16], 503)
        self.wait_idle()

    def test_full_resolution_job_freezes_settings(self) -> None:
        self.wait_idle()
        warm = {"warmth": 0.6, "grainAmount": 0.5}
        expected = self.lab.request("POST", "/api/resolve", {"controls": warm, "context": context()}).json()
        self.lab.request("POST", "/api/_test/sleep", {"milliseconds": 800, "wait": False})
        response = self.lab.request("POST", "/api/jobs", {
            "kind": "full", "photoId": self.photos[2]["photoId"], "controls": warm, "context": context(),
            "settingsGeneration": 99})
        self.assertEqual(response.status, 202)
        job_id = response.json()["jobId"]
        # Interleaved previews with other settings must not leak into the job.
        for generation in range(3):
            self.preview({"warmth": -0.8, "grainAmount": 0.0}, generation=100 + generation)
        deadline = time.monotonic() + 120
        while (job := self.lab.request("GET", f"/api/jobs/{job_id}", origin=None).json())["status"] not in ("done", "failed"):
            self.assertLess(time.monotonic(), deadline)
            time.sleep(0.1)
        self.assertEqual(job["status"], "done", job)
        self.assertEqual(job["settingsRevision"], 99)
        result = job["results"][0]
        self.assertEqual(result["appliedFingerprint"], expected["appliedFingerprint"])
        self.assertEqual((result["width"], result["height"]), (self.photos[2]["width"], self.photos[2]["height"]))
        data = self.media(result["media"])
        self.assertEqual(jpeg_size(data), (result["width"], result["height"]))
        self.assertEqual(exif_tags(data), {0xA001, 0xA002, 0xA003},
                         "only ImageIO's colour space and pixel size; no camera EXIF or GPS")
        self.assertEqual(result["quality"], expected["compressionQuality"])
        download = self.lab.request("GET", f"/media/{result['media']}?download=1", origin=None)
        self.assertIn("attachment", download.headers.get("content-disposition", ""))

    def test_batch_renders_every_reference_photo(self) -> None:
        job = self.run_job({"kind": "batch", "controls": {"vignette": 0.8}, "context": context(),
                            "settingsGeneration": 5})
        self.assertEqual(job["status"], "done", job)
        extra = set(self.extra_photos())
        results = [r for r in job["results"] if r["photoId"] not in extra]
        self.assertEqual([r["photoId"] for r in results], [p["photoId"] for p in self.photos])
        for result in results:
            self.assertEqual(max(result["width"], result["height"]), 720)
            self.assertEqual(jpeg_size(self.media(result["media"])), (result["width"], result["height"]))

    def test_preview_retention_is_bounded(self) -> None:
        names = [self.preview({"contrast": step / 20}, generation=step).json()["media"] for step in range(12)]
        media = set(self.state()["media"])
        previews = [name for name in media if name.startswith("preview-")]
        self.assertLessEqual(len(previews), 8)
        self.assertIn(names[-1], media)
        self.assertNotIn(names[0], media)
        self.assertEqual(len(list((self.lab.session / "media").glob("preview-*"))), len(previews))

    # Worker supervision -----------------------------------------------------
    def test_worker_crash_restarts(self) -> None:
        self.wait_idle()
        before = self.state()
        crash = self.lab.request("POST", "/api/_test/crash", {}).json()
        self.assertEqual(crash, {"failure": "worker-crashed"})
        response = self.preview({"chroma": 0.3})
        self.assertEqual(response.status, 200, response.body)
        after = self.state()
        self.assertGreater(after["starts"], before["starts"])
        self.assertNotEqual(after["pid"], before["pid"])

    def test_worker_timeout_restarts(self) -> None:
        self.wait_idle()
        before = self.state()
        stalled = self.lab.request("POST", "/api/_test/sleep", {"milliseconds": (JOB_TIMEOUT + 4) * 1000},
                                   timeout=JOB_TIMEOUT + 30).json()
        self.assertEqual(stalled, {"failure": "worker-timeout"})
        self.assertEqual(self.preview().status, 200)
        self.assertGreater(self.state()["starts"], before["starts"])

    def test_recycling_preserves_output(self) -> None:
        self.wait_idle()
        controls = {"halation": 0.8, "grainSize": 2}
        starts = self.state()["starts"]
        outputs = []
        for generation in range(RECYCLE_AFTER * 2 + 1):
            response = self.preview(controls, photo=0, generation=generation, size=768).json()
            outputs.append(self.media(response["media"]))
        self.assertGreaterEqual(self.state()["starts"] - starts, 2)
        self.assertEqual(len(set(outputs)), 1, "renders across worker recycles must be identical")

    # Looks ----------------------------------------------------------------
    def test_preset_lifecycle_and_no_silent_overwrite(self) -> None:
        name = f"Warm test {time.monotonic_ns()}"
        controls = {"warmth": 0.25, "lightLeak": "on", "dateStamp": "off"}
        saved = self.lab.request("POST", "/api/presets", {"name": name, "controls": controls, "context": context(BIG_SEED)})
        self.assertEqual(saved.status, 201, saved.body)
        preset_id = saved.json()["presetId"]
        path = self.lab.presets / f"{preset_id}.json"
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        text = path.read_text()
        self.assertIn(BIG_SEED, text)
        self.assertNotIn("base64", text)
        self.assertLess(len(text), 64 * 1024, "presets hold no image data")
        self.assertTrue(all(p.suffix == ".json" for p in self.lab.presets.iterdir()))

        clash = self.lab.request("POST", "/api/presets", {"name": name.upper(), "controls": {}, "context": context()})
        self.assertEqual((clash.status, clash.code, clash.json()["error"]["presetId"]), (409, "name-exists", preset_id))
        self.assertEqual(path.read_text(), text, "a clash must not touch the stored look")

        replaced = self.lab.request("POST", "/api/presets", {"name": name, "controls": {"warmth": 0.5},
                                                             "context": context(BIG_SEED), "replacePresetId": preset_id})
        self.assertEqual(replaced.status, 200, replaced.body)
        self.assertTrue(replaced.json()["replaced"])

        listed = self.lab.request("GET", "/api/presets", origin=None).json()
        self.assertIn(preset_id, [p["presetId"] for p in listed["presets"]])
        loaded = self.lab.request("GET", f"/api/presets/{preset_id}", origin=None).json()
        self.assertEqual(loaded["controls"], {"warmth": 0.5})
        self.assertEqual(loaded["context"]["seed"], BIG_SEED)
        self.assertTrue(loaded["verifiedSnapshot"])

        self.assertEqual(self.lab.request("DELETE", f"/api/presets/{preset_id}", {}).code, "confirm-required")
        self.assertTrue(path.exists())
        self.assertEqual(self.lab.request("DELETE", f"/api/presets/{preset_id}", {"confirm": True}).status, 200)
        self.assertFalse(path.exists())
        self.assertEqual(self.lab.request("GET", f"/api/presets/{preset_id}", origin=None).status, 404)
        self.assertEqual(list(self.lab.presets.glob(".tmp-*")), [])

    def test_presets_survive_a_server_restart(self) -> None:
        other = LabServer()
        try:
            saved = other.request("POST", "/api/presets", {"name": "Persisted", "controls": {"contrast": 0.3},
                                                          "context": context()})
            self.assertEqual(saved.status, 201, saved.body)
            preset_id = saved.json()["presetId"]
        finally:
            other.stop()
        again = LabServer("--presets-dir", str(other.presets))
        try:
            loaded = again.request("GET", f"/api/presets/{preset_id}", origin=None)
            self.assertEqual(loaded.status, 200, loaded.body)
            self.assertEqual(loaded.json()["controls"], {"contrast": 0.3})
        finally:
            again.stop()

    def test_unreadable_preset_files_are_listed_but_not_loaded(self) -> None:
        self.lab.presets.mkdir(parents=True, exist_ok=True)
        broken = self.lab.presets / "p-00000000000000ff.json"
        broken.write_text("[" * 50_000)
        try:
            listed = self.lab.request("GET", "/api/presets", origin=None).json()["presets"]
            self.assertIn({"presetId": broken.stem, "name": None, "valid": False}, listed)
            self.assertEqual(self.lab.request("GET", f"/api/presets/{broken.stem}", origin=None).status, 422)
        finally:
            broken.unlink()

    def test_export_import_round_trip_keeps_big_seed(self) -> None:
        controls = {"brightness": 0.2, "lightLeak": "on", "lightLeakStrength": 0.6}
        exported = self.lab.request("POST", "/api/export", {"name": "Round trip", "controls": controls,
                                                            "context": context(BIG_SEED)})
        self.assertEqual(exported.status, 200, exported.body)
        self.assertIn('filename="Round-trip.film-lab.json"', exported.headers["content-disposition"])
        text = exported.body.decode()
        self.assertIn(f'"{BIG_SEED}"', text)  # context seed as a decimal string
        self.assertIn(f": {BIG_SEED}", text)  # applied recipe seed as an exact integer
        imported = self.lab.request("POST", "/api/import", raw=exported.body, content_type="text/plain")
        self.assertEqual(imported.status, 200, imported.body)
        result = imported.json()
        self.assertEqual(result["context"]["seed"], BIG_SEED)
        self.assertEqual(result["controls"], controls)
        self.assertTrue(result["verifiedSnapshot"])
        self.assertTrue(result["lightLeakApplied"])
        direct = self.lab.request("POST", "/api/resolve", {"controls": controls, "context": context(BIG_SEED)}).json()
        self.assertEqual(result["appliedFingerprint"], direct["appliedFingerprint"])

    def test_malicious_imports_are_rejected(self) -> None:
        exported = self.lab.request("POST", "/api/export", {"name": "Base", "controls": {"warmth": 0.1},
                                                            "context": context()}).body.decode()
        document = json.loads(exported)
        tampered = json.loads(exported)
        tampered["appliedRecipe"]["stages"].insert(0, {"kind": "colorGrade", "configuration": {"saturation": 5}})
        nudged = json.loads(exported)
        nudged["appliedRecipe"]["stages"][0]["configuration"]["curves"][0][1] += 0.01
        injected = json.loads(exported)
        injected["controls"]["brightness"] = 7
        unknown = json.loads(exported)
        unknown["installInto"] = "Aperture"
        wrong_schema = json.loads(exported)
        wrong_schema["schema"] = "aperture.app-settings"
        cases = {
            "injected stage": json.dumps(tampered),
            "nudged snapshot": json.dumps(nudged),
            "out of range": json.dumps(injected),
            "unknown field": json.dumps(unknown),
            "wrong schema": json.dumps(wrong_schema),
            "numeric seed": exported.replace(f'"seed" : "{document["context"]["seed"]}"', f'"seed" : {document["context"]["seed"]}'),
            "not json": "{nope",
            "empty": "",
        }
        for label, text in cases.items():
            response = self.lab.request("POST", "/api/import", raw=text.encode(), content_type="text/plain")
            self.assertIn(response.status, (400, 422), f"{label}: {response.body[:200]!r}")
        self.assertNotEqual(cases["numeric seed"], exported, "numeric-seed case must change the text")
        self.assertEqual(self.lab.request("POST", "/api/import", raw=exported.encode(), content_type="image/png").status, 415)
        self.assertEqual(self.lab.request("POST", "/api/import", raw=b"\xff\xfe\x00", content_type="text/plain").code, "invalid-json")


@unittest.skipUnless(RENDERER.is_file(), "run tools/film-lab/build.sh first")
class FilmLabLifecycleTests(unittest.TestCase):
    def test_shutdown_removes_the_session_and_stops_the_renderer(self) -> None:
        lab = LabServer()
        response = lab.request("POST", "/api/samples", {"names": ["day-portrait"]})
        self.assertEqual(response.status, 201)
        state = lab.request("GET", "/api/_test/state", origin=None).json()
        self.assertTrue(lab.session.is_dir())
        self.assertEqual(stat.S_IMODE(lab.session.stat().st_mode), 0o700)
        self.assertFalse(str(lab.session).startswith(str(TOOL_DIR.parents[1])), "session must live outside the repo")
        self.assertEqual(lab.stop(), 0)
        self.assertFalse(lab.session.exists())
        with self.assertRaises(ProcessLookupError):
            os.kill(state["pid"], 0)

    @staticmethod
    def _open_upload(lab: LabServer, length: int, prefix: bytes = b"") -> socket.socket:
        """Start an upload whose body never finishes, holding its request open."""
        connection = socket.create_connection(("127.0.0.1", lab.port), timeout=10)
        connection.sendall((
            f"POST /api/photos HTTP/1.1\r\nHost: 127.0.0.1:{lab.port}\r\nOrigin: {lab.origin}\r\n"
            f"X-Film-Lab-Token: {lab.token}\r\nContent-Type: image/png\r\nContent-Length: {length}\r\n\r\n"
        ).encode() + prefix)
        return connection

    def test_uploads_are_refused_before_their_bodies_are_kept(self) -> None:
        lab = LabServer()
        try:
            for _ in range(4):
                self.assertEqual(lab.request("POST", "/api/samples", {"names": SAMPLES}).status, 201)
            png = (FIXTURES / "night-flash.png").read_bytes()
            full = lab.request("POST", "/api/photos", raw=png, content_type="image/png")
            self.assertEqual((full.status, full.code), (409, "too-many-photos"))
            photos = lab.request("GET", "/api/session", origin=None).json()["photos"]
            self.assertEqual(lab.request("DELETE", f"/api/photos/{photos[0]['photoId']}").status, 200)
            # Two unfinished uploads hold both upload slots; a third is refused
            # and its body discarded rather than kept.
            held = [self._open_upload(lab, 10_000_000, png[:1000]) for _ in range(2)]
            time.sleep(0.5)
            refused = lab.request("POST", "/api/photos", raw=png, content_type="image/png")
            self.assertEqual((refused.status, refused.code), (429, "busy"))
            for connection in held:
                connection.close()
            deadline = time.monotonic() + 10
            while True:
                response = lab.request("POST", "/api/photos", raw=png, content_type="image/png")
                if response.status == 201 or time.monotonic() > deadline:
                    break
                time.sleep(0.1)
            self.assertEqual(response.status, 201, response.body)
        finally:
            lab.stop()

    def test_open_connections_are_bounded(self) -> None:
        lab = LabServer()
        idle: list[socket.socket] = []
        try:
            idle = [socket.create_connection(("127.0.0.1", lab.port), timeout=10) for _ in range(32)]
            time.sleep(0.5)
            with self.assertRaises((http.client.HTTPException, ConnectionError, OSError)):
                lab.request("GET", "/api/session", origin=None, timeout=10)
            for connection in idle:
                connection.close()
            idle = []
            deadline = time.monotonic() + 10
            while True:
                try:
                    status = lab.request("GET", "/api/session", origin=None, timeout=10).status
                except (http.client.HTTPException, OSError):
                    status = None
                if status == 200 or time.monotonic() > deadline:
                    break
                time.sleep(0.1)
            self.assertEqual(status, 200)
        finally:
            for connection in idle:
                connection.close()
            lab.stop()

    def test_an_abandoned_upload_leaves_no_media(self) -> None:
        # The upload waits job-timeout + 10 s; queue more work than that ahead of it.
        lab = LabServer("--job-timeout", "2")
        try:
            for _ in range(7):
                self.assertEqual(lab.request("POST", "/api/_test/sleep", {"milliseconds": 1800, "wait": False}).status, 202)
            png = (FIXTURES / "night-flash.png").read_bytes()
            response = lab.request("POST", "/api/photos", raw=png, content_type="image/png")
            self.assertEqual((response.status, response.code), (504, "timeout"))
            deadline = time.monotonic() + 30
            while True:
                state = lab.request("GET", "/api/_test/state", origin=None).json()
                if (not state["busy"] and not any(state["depth"].values())) or time.monotonic() > deadline:
                    break
                time.sleep(0.1)
            self.assertEqual(state["media"], [])
            self.assertEqual(lab.request("GET", "/api/session", origin=None).json()["photos"], [])
            self.assertEqual(sorted(p.name for p in (lab.session / "photos").iterdir()), [])
            self.assertEqual(sorted(p.name for p in (lab.session / "media").iterdir()), [])
        finally:
            lab.stop()

    def test_test_hooks_are_off_by_default(self) -> None:
        port = free_port()
        temp = Path(tempfile.mkdtemp(prefix="film-lab-test-"))
        ready = temp / "ready.json"
        process = subprocess.Popen([sys.executable, str(SERVER), "--port", str(port), "--presets-dir", str(temp / "p"),
                                    "--ready-file", str(ready)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            deadline = time.monotonic() + 60
            while not ready.exists() or not ready.stat().st_size:
                self.assertLess(time.monotonic(), deadline)
                time.sleep(0.05)
            time.sleep(0.05)
            token = json.loads(ready.read_text())["token"]
            connection = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
            connection.request("POST", "/api/_test/crash", body=b"{}", headers={
                "X-Film-Lab-Token": token, "Origin": f"http://127.0.0.1:{port}", "Content-Type": "application/json"})
            self.assertEqual(connection.getresponse().status, 404)
            connection.close()
        finally:
            process.send_signal(signal.SIGTERM)
            process.wait(20)

    def test_refuses_to_bind_anything_but_loopback(self) -> None:
        lab = LabServer()
        try:
            addresses = []
            for family, address in ((socket.AF_INET, self._lan_address()),):
                if address is None:
                    continue
                with socket.socket(family) as probe:
                    probe.settimeout(2)
                    addresses.append(probe.connect_ex((address, lab.port)))
            for result in addresses:
                self.assertNotEqual(result, 0, "the server must not accept LAN connections")
        finally:
            lab.stop()

    @staticmethod
    def _lan_address() -> str | None:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
            try:
                probe.connect(("192.0.2.1", 9))  # TEST-NET-1; no packets are sent for UDP connect.
                address = probe.getsockname()[0]
            except OSError:
                return None
        return None if address.startswith("127.") else address


if __name__ == "__main__":
    unittest.main()
