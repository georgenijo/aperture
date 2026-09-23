// Aperture Film Lab browser UI. Dependency-free; talks only to the local
// server that served it. Candidate JSON is handled as opaque text/blobs and
// never parsed here, so a UInt64 seed is never rounded by a JS number.
"use strict";

(() => {
  const $ = (id) => document.getElementById(id);
  const DEBOUNCE_MS = 120;

  // ---- Session capability -------------------------------------------------
  // The token arrives in the URL fragment (never sent to the server in a
  // request line or Referer), then moves to sessionStorage and off the URL bar.
  const hashToken = new URLSearchParams(location.hash.slice(1)).get("token");
  if (hashToken) {
    sessionStorage.setItem("film-lab-token", hashToken);
    history.replaceState(null, "", location.pathname);
  }
  const token = sessionStorage.getItem("film-lab-token") || "";

  const state = {
    schema: null,
    controls: {},          // id -> value (only non-neutral values are kept)
    remembered: {},        // id -> last non-off value for effect toggles
    context: null,
    photos: [],
    selected: null,
    photoGeneration: 0,
    settingsGeneration: 0,
    contextRequest: 0,     // latest context validation; older answers are ignored
    lastInputAt: 0,
    debounce: null,
    inflight: 0,
    mode: "split",
    split: 50,
    processedUrl: null,
    originalUrls: new Map(),
    fullJob: null,
    batchJob: null,
    looks: [],
    lastApplied: null,
    stats: { previews: [], stale: 0, superseded: 0, errors: 0 },
  };
  window.filmLab = { state, stats: state.stats };

  // ---- Networking -----------------------------------------------------------

  class ApiError extends Error {
    constructor(status, code, message, extra) {
      super(message);
      this.status = status;
      this.code = code;
      this.extra = extra || {};
    }
  }

  async function api(method, path, body, options = {}) {
    const headers = { "X-Film-Lab-Token": token };
    let payload;
    if (body instanceof Blob || typeof body === "string") {
      payload = body;
      headers["Content-Type"] = options.contentType || "application/octet-stream";
    } else if (body !== undefined) {
      payload = JSON.stringify(body);
      headers["Content-Type"] = "application/json";
    }
    Object.assign(headers, options.headers || {});
    const response = await fetch(path, { method, headers, body: payload, cache: "no-store", credentials: "omit" });
    if (!response.ok) {
      let error = { code: "http-" + response.status, message: response.statusText };
      try { error = (await response.json()).error || error; } catch (_) { /* not JSON */ }
      throw new ApiError(response.status, error.code, error.message, error);
    }
    if (options.raw) return response;
    return response.json();
  }

  async function mediaUrl(name) {
    const response = await api("GET", "/media/" + encodeURIComponent(name), undefined, { raw: true });
    return URL.createObjectURL(await response.blob());
  }

  function downloadBlob(blob, fileName) {
    const url = URL.createObjectURL(blob);
    const link = document.createElement("a");
    link.href = url;
    link.download = fileName;
    document.body.append(link);
    link.click();
    link.remove();
    setTimeout(() => URL.revokeObjectURL(url), 10000);
  }

  // ---- Feedback -------------------------------------------------------------

  let toastTimer = null;
  function toast(message, kind = "error") {
    const element = $("toast");
    element.textContent = message;
    element.className = "toast" + (kind === "info" ? " info" : "");
    element.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { element.hidden = true; }, kind === "info" ? 3000 : 7000);
  }

  function reportError(error) {
    state.stats.errors += 1;
    toast(error instanceof ApiError ? error.message : String(error.message || error));
  }

  function setStatus(text, isError = false) {
    const element = $("status");
    element.textContent = text;
    element.classList.toggle("error", isError);
  }

  function latencySummary() {
    const samples = state.stats.previews.slice(-20).map((s) => s.endToEnd).sort((a, b) => a - b);
    if (!samples.length) return "";
    const median = samples[Math.floor(samples.length / 2)];
    return `preview ${median} ms median (last ${samples.length})`;
  }

  // ---- Controls -------------------------------------------------------------

  function definition(id) {
    return state.schema.controls.find((control) => control.id === id);
  }

  function valueOf(id) {
    const control = definition(id);
    return Object.prototype.hasOwnProperty.call(state.controls, id) ? state.controls[id] : control.neutral;
  }

  function setControl(id, value) {
    const control = definition(id);
    if (control.kind === "number") {
      value = Math.min(control.max, Math.max(control.min, Number(value)));
      if (!Number.isFinite(value)) return;
      value = Math.round(value / control.step) * control.step;
      value = Number(value.toFixed(4));
    }
    if (value === control.neutral) delete state.controls[id];
    else state.controls[id] = value;
    syncControl(id);
    settingsChanged();
  }

  function buildControls() {
    const container = $("control-groups");
    container.replaceChildren();
    for (const group of state.schema.groups) {
      const card = document.createElement("section");
      card.className = "card";
      const title = document.createElement("h2");
      title.textContent = group.label;
      card.append(title);
      for (const control of state.schema.controls.filter((c) => c.group === group.id)) {
        card.append(buildControl(control));
      }
      container.append(card);
    }
  }

  function buildControl(control) {
    const row = document.createElement("div");
    row.className = "control";
    row.id = "control-" + control.id;
    row.dataset.control = control.id;

    const label = document.createElement("div");
    label.className = "label";
    const dot = document.createElement("span");
    dot.className = "changed";
    const text = document.createElement("span");
    text.textContent = control.label;
    label.append(dot, text);

    if (control.offValue !== undefined) {
      const toggle = document.createElement("label");
      toggle.className = "toggle";
      const box = document.createElement("input");
      box.type = "checkbox";
      box.dataset.role = "toggle";
      box.title = "Effect on/off";
      box.addEventListener("change", () => {
        if (box.checked) {
          const restore = state.remembered[control.id];
          setControl(control.id, restore !== undefined && restore !== control.offValue ? restore : control.neutral);
        } else {
          const current = valueOf(control.id);
          if (current !== control.offValue) state.remembered[control.id] = current;
          setControl(control.id, control.offValue);
        }
      });
      toggle.append(box, document.createTextNode("on"));
      label.append(toggle);
    }
    row.append(label);

    if (control.kind === "number") {
      const range = document.createElement("input");
      range.type = "range";
      range.min = control.min;
      range.max = control.max;
      range.step = control.step;
      range.dataset.role = "range";
      range.setAttribute("aria-label", control.label);
      range.addEventListener("input", () => setControl(control.id, range.value));
      const number = document.createElement("input");
      number.type = "number";
      number.min = control.min;
      number.max = control.max;
      number.step = control.step;
      number.dataset.role = "number";
      number.setAttribute("aria-label", control.label + " value");
      number.addEventListener("change", () => {
        if (number.value === "" || !Number.isFinite(Number(number.value))) { syncControl(control.id); return; }
        setControl(control.id, number.value);
      });
      row.append(range, number);
    } else {
      const select = document.createElement("select");
      select.dataset.role = "select";
      select.setAttribute("aria-label", control.label);
      for (const option of control.options) {
        const element = document.createElement("option");
        element.value = option;
        element.textContent = (control.optionLabels && control.optionLabels[option]) || option;
        select.append(element);
      }
      select.addEventListener("change", () => setControl(control.id, select.value));
      row.append(select);
    }

    const reset = document.createElement("button");
    reset.type = "button";
    reset.className = "reset";
    reset.textContent = "↺";
    reset.title = "Reset to the shipping 1998 value";
    reset.addEventListener("click", () => setControl(control.id, control.neutral));
    row.append(reset);

    if (control.help) {
      const help = document.createElement("div");
      help.className = "help";
      help.textContent = control.help;
      row.append(help);
    }
    return row;
  }

  function syncControl(id) {
    const control = definition(id);
    const row = $("control-" + id);
    const value = valueOf(id);
    row.classList.toggle("is-changed", value !== control.neutral);
    const off = control.offValue !== undefined && value === control.offValue;
    row.classList.toggle("off", off);
    const toggle = row.querySelector('[data-role="toggle"]');
    if (toggle) toggle.checked = !off;
    const range = row.querySelector('[data-role="range"]');
    if (range) range.value = value;
    const number = row.querySelector('[data-role="number"]');
    if (number && document.activeElement !== number) number.value = value;
    const select = row.querySelector('[data-role="select"]');
    if (select) select.value = value;
  }

  function syncAllControls() {
    for (const control of state.schema.controls) syncControl(control.id);
    const count = Object.keys(state.controls).length;
    $("changed-count").textContent = count ? `${count} control${count === 1 ? "" : "s"} changed` : "Shipping 1998 look";
  }

  // ---- Context --------------------------------------------------------------

  function readContext() {
    return {
      seed: $("ctx-seed").value.trim(),
      capturedAt: $("ctx-captured").value.trim(),
      timeZone: $("ctx-zone").value.trim(),
      photoQuality: $("ctx-quality").value,
    };
  }

  function writeContext(context) {
    $("ctx-seed").value = context.seed;
    $("ctx-captured").value = context.capturedAt;
    $("ctx-zone").value = context.timeZone;
    $("ctx-quality").value = context.photoQuality;
    state.context = { ...context };
  }

  function randomSeed() {
    const words = crypto.getRandomValues(new Uint32Array(2));
    return ((BigInt(words[0]) << 32n) | BigInt(words[1])).toString();
  }

  // ---- Settings changes and previews -----------------------------------------

  function settingsPayload() {
    return { controls: { ...state.controls }, context: { ...state.context } };
  }

  function settingsChanged() {
    state.settingsGeneration += 1;
    state.lastInputAt = performance.now();
    syncAllControls();
    markFullStale();
    schedulePreview();
  }

  function schedulePreview() {
    clearTimeout(state.debounce);
    state.debounce = setTimeout(requestPreview, DEBOUNCE_MS);
  }

  async function requestPreview() {
    const photo = state.selected;
    if (!photo) { refreshFacts(); return; }
    const photoGeneration = state.photoGeneration;
    const settingsGeneration = state.settingsGeneration;
    const inputAt = state.lastInputAt || performance.now();
    const sentAt = performance.now();
    state.inflight += 1;
    $("busy").hidden = false;
    try {
      const result = await api("POST", "/api/preview", {
        ...settingsPayload(), photoId: photo.photoId, photoGeneration, settingsGeneration,
        maxDimension: Number($("preview-size").value),
      });
      if (result.status === "superseded") { state.stats.superseded += 1; return; }
      if (result.photoGeneration !== state.photoGeneration || result.settingsGeneration !== state.settingsGeneration) {
        state.stats.stale += 1;  // A newer photo or setting is already on its way.
        return;
      }
      const url = await mediaUrl(result.media);
      if (photoGeneration !== state.photoGeneration || settingsGeneration !== state.settingsGeneration) {
        URL.revokeObjectURL(url);
        state.stats.stale += 1;
        return;
      }
      await showProcessed(url);
      const shownAt = performance.now();
      state.stats.previews.push({
        endToEnd: Math.round(shownAt - inputAt), request: Math.round(shownAt - sentAt),
        render: result.renderMs, width: result.width, height: result.height, at: Date.now(),
      });
      if (state.stats.previews.length > 500) state.stats.previews.shift();
      applyFacts(result);
      setStatus(`${result.width}×${result.height} preview · render ${result.renderMs} ms · ${latencySummary()}`);
      if ($("recipe-details").open) refreshRecipeText();
    } catch (error) {
      if (error.code === "unknown-photo") { await refreshSession(); }
      reportError(error);
      setStatus("Preview failed", true);
    } finally {
      state.inflight -= 1;
      if (state.inflight <= 0) { state.inflight = 0; $("busy").hidden = true; }
    }
  }

  function showProcessed(url) {
    return new Promise((resolve) => {
      const image = $("img-processed");
      const previous = state.processedUrl;
      image.onload = () => { if (previous) URL.revokeObjectURL(previous); resolve(); };
      image.onerror = () => resolve();
      state.processedUrl = url;
      image.src = url;
    });
  }

  function applyFacts(result) {
    $("fact-stamp").textContent = result.dateStampText ? `“${result.dateStampText}”` : "hidden";
    $("fact-leak").textContent = result.lightLeakApplied ? "yes (this seed)" : "no";
    $("fact-fingerprint").textContent = (result.appliedFingerprint || "").replace("sha256:", "").slice(0, 16) + (result.isBaseline ? " · shipping" : " · candidate");
    state.lastApplied = result;
  }

  async function refreshFacts() {
    try {
      const result = await api("POST", "/api/resolve", settingsPayload());
      applyFacts(result);
      $("recipe-text").textContent = result.appliedText;
    } catch (error) {
      reportError(error);
    }
  }

  async function refreshRecipeText() {
    try {
      const result = await api("POST", "/api/resolve", settingsPayload());
      $("recipe-text").textContent = result.appliedText;
    } catch (error) {
      reportError(error);
    }
  }

  // ---- Photos ---------------------------------------------------------------

  async function refreshSession() {
    const session = await api("GET", "/api/session");
    state.photos = session.photos;
    if (state.selected && !state.photos.some((p) => p.photoId === state.selected.photoId)) state.selected = null;
    renderStrip();
    return session;
  }

  function renderStrip() {
    const strip = $("strip");
    strip.replaceChildren();
    for (const photo of state.photos) {
      const item = document.createElement("li");
      const button = document.createElement("button");
      button.type = "button";
      button.className = "thumb" + (state.selected && state.selected.photoId === photo.photoId ? " active" : "");
      button.title = `${photo.name} · ${photo.width}×${photo.height}`;
      const image = document.createElement("img");
      image.alt = photo.name;
      originalUrl(photo).then((url) => { image.src = url; }).catch(() => {});
      button.append(image);
      button.addEventListener("click", () => selectPhoto(photo.photoId));
      const remove = document.createElement("button");
      remove.type = "button";
      remove.className = "remove";
      remove.textContent = "×";
      remove.title = "Remove from the reference set";
      remove.addEventListener("click", (event) => { event.stopPropagation(); removePhoto(photo.photoId); });
      const caption = document.createElement("div");
      caption.className = "caption";
      caption.textContent = photo.name;
      caption.title = photo.name;
      item.append(button, remove, caption);
      strip.append(item);
    }
    const limit = state.limits ? state.limits.maxPhotos : 12;
    $("strip-note").textContent = `${state.photos.length}/${limit} reference photos · settings are shared across the set`;
    $("canvas-empty").hidden = state.photos.length > 0;
    $("frame").hidden = !state.selected;
    $("render-set").disabled = state.photos.length === 0;
    $("render-full").disabled = !state.selected;
  }

  async function originalUrl(photo) {
    if (!state.originalUrls.has(photo.photoId)) {
      state.originalUrls.set(photo.photoId, mediaUrl(photo.original));
    }
    return state.originalUrls.get(photo.photoId);
  }

  async function selectPhoto(photoId) {
    const photo = state.photos.find((p) => p.photoId === photoId);
    if (!photo) return;
    state.selected = photo;
    state.photoGeneration += 1;
    const photoGeneration = state.photoGeneration;
    renderStrip();
    $("img-processed").removeAttribute("src");
    const url = await originalUrl(photo);
    if (photoGeneration !== state.photoGeneration) return;  // A newer selection owns the canvas.
    $("img-original").src = url;
    $("full-result").hidden = true;
    state.lastInputAt = performance.now();
    requestPreview();
  }

  async function removePhoto(photoId) {
    try {
      await api("DELETE", "/api/photos/" + encodeURIComponent(photoId));
      const url = state.originalUrls.get(photoId);
      state.originalUrls.delete(photoId);
      if (url) url.then((u) => URL.revokeObjectURL(u)).catch(() => {});
      const wasSelected = state.selected && state.selected.photoId === photoId;
      await refreshSession();
      if (wasSelected) {
        state.selected = null;
        if (state.photos.length) await selectPhoto(state.photos[0].photoId);
        else renderStrip();
      }
    } catch (error) {
      reportError(error);
    }
  }

  async function uploadFiles(files) {
    const list = Array.from(files);
    let last = null;
    for (const file of list) {
      setStatus(`Adding ${file.name}…`);
      try {
        last = await api("POST", "/api/photos", file, {
          contentType: file.type || "application/octet-stream",
          headers: { "X-Film-Lab-Filename": encodeURIComponent(file.name.slice(0, 120)) },
        });
      } catch (error) {
        reportError(new Error(`${file.name}: ${error.message}`));
      }
    }
    await refreshSession();
    if (last && (!state.selected || list.length === 1)) await selectPhoto(last.photoId);
    else if (!state.selected && state.photos.length) await selectPhoto(state.photos[0].photoId);
    setStatus(latencySummary() || "Ready");
  }

  async function addSamples() {
    setStatus("Adding sample fixtures…");
    try {
      const result = await api("POST", "/api/samples", { names: state.samples });
      await refreshSession();
      if (!state.selected && result.photos.length) await selectPhoto(result.photos[0].photoId);
      setStatus("Samples added");
    } catch (error) {
      reportError(error);
      await refreshSession();
    }
  }

  // ---- Explicit jobs (frozen settings) ---------------------------------------

  async function startJob(kind) {
    // Record exactly what is sent: settings may change while the request is in flight.
    const payload = settingsPayload();
    const controlsSnapshot = JSON.stringify(payload);
    const photoGeneration = state.photoGeneration;
    const body = { ...payload, kind, settingsGeneration: state.settingsGeneration };
    if (kind === "full") body.photoId = state.selected.photoId;
    const job = await api("POST", "/api/jobs", body);
    return { ...job, photoGeneration, controlsSnapshot };
  }

  async function pollJob(jobId, onProgress) {
    for (;;) {
      const job = await api("GET", "/api/jobs/" + encodeURIComponent(jobId));
      onProgress(job);
      if (job.status === "done" || job.status === "failed") return job;
      await new Promise((resolve) => setTimeout(resolve, 350));
    }
  }

  function markFullStale() {
    if (state.fullJob && !$("full-result").hidden) {
      const stale = state.fullJob.controlsSnapshot !== JSON.stringify(settingsPayload());
      $("full-meta").dataset.stale = stale ? "1" : "";
      renderFullMeta();
    }
  }

  function renderFullMeta() {
    const job = state.fullJob;
    if (!job || !job.result) return;
    const r = job.result;
    const stale = job.controlsSnapshot !== JSON.stringify(settingsPayload());
    $("full-meta").textContent = `${r.name}: ${r.width}×${r.height} JPEG, ${(r.bytes / 1048576).toFixed(2)} MB, quality ${r.quality}, ` +
      `${r.renderMs} ms. Settings revision ${job.settingsRevision}` + (stale ? " — settings have changed since; this render keeps the old ones." : ".");
  }

  async function renderFull() {
    if (!state.selected) return;
    const button = $("render-full");
    button.disabled = true;
    try {
      const job = await startJob("full");
      setStatus("Full-resolution render queued…");
      const finished = await pollJob(job.jobId, (j) => setStatus(`Full-resolution render ${j.status}…`));
      if (finished.status === "failed") throw new ApiError(0, finished.error.code, finished.error.message);
      const result = finished.results[0];
      if (result.error) throw new ApiError(0, result.error.code, result.error.message);
      state.fullJob = { ...job, settingsRevision: finished.settingsRevision, result };
      $("full-result").hidden = false;
      renderFullMeta();
      setStatus(`Full resolution ready: ${result.width}×${result.height}`);
    } catch (error) {
      reportError(error);
      setStatus("Full-resolution render failed", true);
    } finally {
      button.disabled = !state.selected;
    }
  }

  async function inspectFull() {
    const result = state.fullJob && state.fullJob.result;
    if (!result) return;
    try {
      const url = await mediaUrl(result.media);
      const image = $("viewer-img");
      if (image.src) URL.revokeObjectURL(image.src);
      image.src = url;
      $("viewer-title").textContent = `${result.name} · ${result.width}×${result.height} · 1:1`;
      $("viewer").hidden = false;
    } catch (error) {
      reportError(error);
    }
  }

  async function downloadFull() {
    const result = state.fullJob && state.fullJob.result;
    if (!result) return;
    try {
      const response = await api("GET", "/media/" + encodeURIComponent(result.media), undefined, { raw: true });
      const base = result.name.replace(/\.[A-Za-z0-9]+$/, "").replace(/[^A-Za-z0-9._-]+/g, "-").slice(0, 60) || "photo";
      downloadBlob(await response.blob(), `${base}-film-lab-${result.width}x${result.height}.jpg`);
    } catch (error) {
      reportError(error);
    }
  }

  async function renderSet() {
    const button = $("render-set");
    button.disabled = true;
    const grid = $("batch-grid");
    grid.replaceChildren();
    $("batch").hidden = false;
    $("batch").scrollIntoView({ behavior: "smooth", block: "nearest" });
    try {
      const job = await startJob("batch");
      const shown = new Set();
      const finished = await pollJob(job.jobId, (j) => {
        $("batch-note").textContent = `${j.completed}/${j.total} · settings revision ${j.settingsRevision} · ${j.status}`;
        for (const result of j.results) {
          if (shown.has(result.media || result.photoId)) continue;
          shown.add(result.media || result.photoId);
          grid.append(batchTile(result));
        }
      });
      if (finished.status === "failed") throw new ApiError(0, finished.error.code, finished.error.message);
    } catch (error) {
      reportError(error);
    } finally {
      button.disabled = state.photos.length === 0;
    }
  }

  function batchTile(result) {
    const figure = document.createElement("figure");
    const caption = document.createElement("figcaption");
    if (result.error) {
      caption.textContent = `${result.photoId}: ${result.error.message}`;
      figure.append(caption);
      return figure;
    }
    const image = document.createElement("img");
    image.alt = result.name;
    image.title = "Show this photo in the comparison";
    mediaUrl(result.media).then((url) => { image.src = url; }).catch(() => {});
    image.addEventListener("click", () => selectPhoto(result.photoId));
    caption.textContent = `${result.name} · ${result.width}×${result.height} · ${result.renderMs} ms`;
    figure.append(image, caption);
    return figure;
  }

  // ---- Looks, import and export ---------------------------------------------

  async function refreshLooks() {
    try {
      const result = await api("GET", "/api/presets");
      state.looks = result.presets;
      $("looks-dir").textContent = "Stored in " + result.directory;
      const list = $("looks");
      list.replaceChildren();
      if (!state.looks.length) {
        const empty = document.createElement("li");
        empty.className = "empty";
        empty.textContent = "No saved looks yet.";
        list.append(empty);
      }
      for (const look of state.looks) {
        const item = document.createElement("li");
        const name = document.createElement("span");
        name.className = "name";
        name.textContent = look.name || "(unreadable file)";
        const load = document.createElement("button");
        load.type = "button";
        load.textContent = "Load";
        load.disabled = !look.valid;
        load.addEventListener("click", () => loadLook(look.presetId));
        const remove = document.createElement("button");
        remove.type = "button";
        remove.textContent = "Delete";
        remove.addEventListener("click", () => deleteLook(look));
        item.append(name, load, remove);
        list.append(item);
      }
    } catch (error) {
      reportError(error);
    }
  }

  function applyImported(result, source) {
    state.controls = { ...result.controls };
    state.remembered = {};
    state.contextRequest += 1;  // Discard any context validation still in flight.
    writeContext(result.context);
    $("look-name").value = result.name || "";
    settingsChanged();
    applyFacts(result);
    if (result.appliedText) $("recipe-text").textContent = result.appliedText;
    toast(`${source} “${result.name}”` + (result.verifiedSnapshot ? " (applied recipe verified)" : ""), "info");
  }

  async function saveLook(replacePresetId) {
    const name = $("look-name").value.trim();
    if (!name) { toast("Name the look first."); $("look-name").focus(); return; }
    try {
      const body = { ...settingsPayload(), name };
      if (replacePresetId) body.replacePresetId = replacePresetId;
      const result = await api("POST", "/api/presets", body);
      toast(`${result.replaced ? "Replaced" : "Saved"} “${result.name}”`, "info");
      await refreshLooks();
    } catch (error) {
      if (error.code === "name-exists" && !replacePresetId && error.extra.presetId) {
        if (confirm(`A look named “${name}” already exists. Replace it?`)) await saveLook(error.extra.presetId);
        return;
      }
      reportError(error);
    }
  }

  async function loadLook(presetId) {
    try {
      applyImported(await api("GET", "/api/presets/" + encodeURIComponent(presetId)), "Loaded");
    } catch (error) {
      reportError(error);
    }
  }

  async function deleteLook(look) {
    if (!confirm(`Delete the saved look “${look.name || look.presetId}”? This removes its file.`)) return;
    try {
      await api("DELETE", "/api/presets/" + encodeURIComponent(look.presetId), { confirm: true });
      await refreshLooks();
    } catch (error) {
      reportError(error);
    }
  }

  async function exportLook() {
    const name = $("look-name").value.trim() || "Untitled 1998 candidate";
    try {
      const response = await api("POST", "/api/export", { ...settingsPayload(), name }, { raw: true });
      const disposition = response.headers.get("Content-Disposition") || "";
      const match = /filename="([^"]+)"/.exec(disposition);
      downloadBlob(await response.blob(), match ? match[1] : "look.film-lab.json");
    } catch (error) {
      reportError(error);
    }
  }

  async function importLook(file) {
    try {
      if (file.size > 256 * 1024) throw new Error("The file is larger than 256 KB.");
      const text = await file.text();  // Sent as opaque text; parsed only by the renderer.
      applyImported(await api("POST", "/api/import", text, { contentType: "text/plain; charset=utf-8" }), "Imported");
    } catch (error) {
      reportError(error);
    }
  }

  // ---- Comparison canvas -----------------------------------------------------

  function setMode(mode) {
    state.mode = mode;
    $("canvas").dataset.mode = mode;
    for (const button of document.querySelectorAll("[data-mode]")) {
      if (button.tagName === "BUTTON") button.classList.toggle("active", button.dataset.mode === mode);
    }
  }

  function setSplit(percent) {
    state.split = Math.min(100, Math.max(0, percent));
    $("frame").style.setProperty("--split", state.split + "%");
    $("split-handle").setAttribute("aria-valuenow", String(Math.round(state.split)));
  }

  function wireSplit() {
    const frame = $("frame");
    let dragging = false;
    const move = (event) => {
      const rect = frame.getBoundingClientRect();
      setSplit(((event.clientX - rect.left) / rect.width) * 100);
    };
    frame.addEventListener("pointerdown", (event) => {
      if (state.mode !== "split") return;
      dragging = true;
      frame.setPointerCapture(event.pointerId);
      move(event);
    });
    frame.addEventListener("pointermove", (event) => { if (dragging) move(event); });
    frame.addEventListener("pointerup", () => { dragging = false; });
    frame.addEventListener("pointercancel", () => { dragging = false; });
    $("split-handle").addEventListener("keydown", (event) => {
      if (event.key === "ArrowLeft") { setSplit(state.split - 2); event.preventDefault(); }
      if (event.key === "ArrowRight") { setSplit(state.split + 2); event.preventDefault(); }
    });
    setSplit(50);
  }

  function wireDrop() {
    let depth = 0;
    const veil = $("dropveil");
    window.addEventListener("dragenter", (event) => {
      if (!event.dataTransfer || !Array.from(event.dataTransfer.types).includes("Files")) return;
      depth += 1;
      veil.hidden = false;
      event.preventDefault();
    });
    window.addEventListener("dragover", (event) => { event.preventDefault(); });
    window.addEventListener("dragleave", () => { depth = Math.max(0, depth - 1); if (!depth) veil.hidden = true; });
    window.addEventListener("drop", (event) => {
      event.preventDefault();
      depth = 0;
      veil.hidden = true;
      if (event.dataTransfer && event.dataTransfer.files.length) uploadFiles(event.dataTransfer.files);
    });
  }

  // ---- Startup ---------------------------------------------------------------

  function wire() {
    for (const button of document.querySelectorAll("button[data-mode]")) {
      button.addEventListener("click", () => setMode(button.dataset.mode));
    }
    $("preview-size").addEventListener("change", () => { state.lastInputAt = performance.now(); requestPreview(); });
    $("file-input").addEventListener("change", (event) => { uploadFiles(event.target.files); event.target.value = ""; });
    $("add-samples").addEventListener("click", addSamples);
    $("render-set").addEventListener("click", renderSet);
    $("batch-close").addEventListener("click", () => { $("batch").hidden = true; });
    $("render-full").addEventListener("click", renderFull);
    $("full-inspect").addEventListener("click", inspectFull);
    $("full-download").addEventListener("click", downloadFull);
    $("viewer-close").addEventListener("click", () => { $("viewer").hidden = true; });
    document.addEventListener("keydown", (event) => { if (event.key === "Escape") $("viewer").hidden = true; });
    $("reset-all").addEventListener("click", () => {
      state.controls = {};
      state.remembered = {};
      settingsChanged();
    });
    $("save-look").addEventListener("click", () => saveLook());
    $("export-look").addEventListener("click", exportLook);
    $("import-input").addEventListener("change", (event) => {
      if (event.target.files[0]) importLook(event.target.files[0]);
      event.target.value = "";
    });
    $("recipe-details").addEventListener("toggle", () => { if ($("recipe-details").open) refreshRecipeText(); });
    $("new-seed").addEventListener("click", () => { $("ctx-seed").value = randomSeed(); contextChanged(); });
    for (const id of ["ctx-seed", "ctx-captured", "ctx-zone", "ctx-quality"]) {
      $(id).addEventListener("change", contextChanged);
    }
    wireSplit();
    wireDrop();
  }

  async function contextChanged() {
    const candidate = readContext();
    const request = ++state.contextRequest;
    try {
      // Validate before adopting, so a typo never reaches the preview queue.
      const result = await api("POST", "/api/resolve", { controls: { ...state.controls }, context: candidate });
      if (request !== state.contextRequest) return;  // A newer edit or loaded look superseded this one.
      writeContext(result.context);
      settingsChanged();
    } catch (error) {
      if (request !== state.contextRequest) return;
      reportError(error);
      writeContext(state.context);
    }
  }

  async function start() {
    if (!token) {
      setStatus("Missing session token: open the URL printed by run.sh.", true);
      return;
    }
    wire();
    try {
      const session = await refreshSession();
      state.schema = session.controls;
      state.samples = session.samples;
      state.limits = session.limits;
      $("base-recipe").textContent = `${session.baseRecipe.id} v${session.baseRecipe.version}`;
      const quality = $("ctx-quality");
      for (const option of state.schema.context.photoQuality.options) {
        const element = document.createElement("option");
        element.value = option;
        element.textContent = option;
        quality.append(element);
      }
      const defaults = {};
      for (const key of ["seed", "capturedAt", "timeZone", "photoQuality"]) defaults[key] = state.schema.context[key].default;
      writeContext(defaults);
      buildControls();
      syncAllControls();
      renderStrip();
      await refreshLooks();
      await refreshFacts();
      if (state.photos.length) await selectPhoto(state.photos[0].photoId);
      setStatus(`Ready · ${session.renderer}`);
    } catch (error) {
      reportError(error);
      setStatus("Cannot reach the Film Lab server", true);
    }
  }

  start();
})();
