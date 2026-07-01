# 🎧 Sound Library v1.0

A fast, local, **searchable catalog + audition/edit workbench** for large sound-effects
libraries — built for the [Sonniss GDC Game Audio Bundles](https://sonniss.com/gameaudiogdc)
(~7,000 WAVs, ~217 GB), but it works on any folder of audio.

Browse thousands of files instantly, **find sounds three different ways** (by name, by
meaning, or by how they *actually sound*), level-balance them, chop long recordings into
individual hits, and bake seamless loops — all in one keyboard-friendly tool. **Godot 4.6**
front-end, **Python** for the heavy lifting. No cloud, no subscription, no LLM.

---

## ✨ Highlights

### 🔎 Browse & search
- **Excel-style table** with per-column filters (text box, tick-boxes, or a two-knob min–max
  range slider — unit-aware: mm:ss, kHz, MB, dB), click-to-sort, drag-to-resize, zebra rows.
- **Three ways to find a sound:**
  - **Text filter** — space-separated AND terms across name/description/tags.
  - **Semantic search** — describe it in words (*"guns shooting"*); ranks by the **meaning**
    of the metadata (tiny local sentence model, no internet, no LLM).
  - **CLAP search** — describe it (*"creepy metallic scrape"*) and rank by the **actual sound**,
    whatever the file is named.
- **Right-click → Find similar** — point at a sound and rank the library by how it *sounds*.
- One **Keywords panel** with a **Filter / Semantic / CLAP** picker.

### 🔊 Audition & organise
- Transport (Play / Stop / Autoplay / **Loop** / seek / volume), **Space** to play-pause anywhere.
- **Star ratings**, **plays** counter, free-text **tags** — stored *with your library*, so they
  survive re-indexing.
- **Spreadsheet-grade editing**: drag-select a range, Shift/Ctrl extend, **Ctrl+C / Ctrl+V**
  (Excel-compatible), Del to clear, type to overwrite a whole selection.
- Reads **MP3** and other formats (decoded to WAV on demand); MP3 plays directly.

### 🎚️ Level-balance by ear
- Measures each file's **integrated loudness (LUFS)**; a **0–10 perceptual "Level" dial** auto-drives
  a per-track **Gain dB**, capped so nothing clips — same Level = equally loud.

### ✂️ Chop long files into individual sounds
- **Waveform visualiser** (perceptual/loudness Y-axis): kept sounds green, dead space grey, chop
  points blue, threshold orange. Tune live or **Suggest** a threshold from the file's own loudness.
- **Make chops** writes each piece next to the original (**16-bit**, original kept), appearing in
  the library instantly — tagged, rateable, re-choppable.

### 🔁 Make seamless loops
- **Suggest loop** auto-picks a good loop region — a whole number of cycles for **rhythmic** sounds
  (gunfire, engines) so the rhythm never hiccups, or the steady **sustain** for textures.
- **Crossfade preview** auditions the loop *in memory*; **Make loop** bakes a click-free `_loop.wav`.

### 🛠️ Handy extras
- **Right-click:** open folder · copy path · find similar · suggest/make loop · suggest/make chops ·
  convert to WAV · **convert to 16-bit (bulk)** · **delete → Recycle Bin** (with confirm).
- **Change your library folder** and re-index from the UI. New chops/loops are **auto-analysed**.
- Built-in **Help** describing every button and shortcut.

---

## 🧠 Search tech (all local, offline)
- **Semantic (text→meaning):** BAAI `bge-small` embeddings via `fastembed` (ONNX, ~50 MB, CPU).
- **CLAP (text→sound & sound→sound):** `laion/clap-htsat-unfused` run **as ONNX (no PyTorch)** —
  audio pre-processing reimplemented in NumPy to match the model exactly, downloaded on demand
  (~120 MB). **GPU-accelerated** via DirectML/CUDA (~7 min to index the full library on a modern GPU).
- **Lightweight fingerprints:** a tiny MFCC/spectral vector for "Find similar" with zero extra deps.

---

## 🚀 Getting started
1. Point `library.cfg` at your audio folder (or use **Choose library folder** in-app).
2. `py -m pip install -r indexer/requirements.txt`
3. `py indexer/index.py` to build the catalog.
4. Run in Godot 4.6 (`--path app`).
5. (Optional) In-app: **Update semantic index** / **Update fingerprints**; for the strongest sound
   search, `pip install -r indexer/requirements-clap.txt` → **Download CLAP** → **Build CLAP index**.

Your audio lives **outside** the repo; your ratings/tags/analysis live **with the audio**, never in git.

---

## 📝 Notes
- Everything runs offline; nothing is uploaded.
- A fully self-contained, Python-free build (no setup for end users) is on the way.
