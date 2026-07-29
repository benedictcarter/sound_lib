# 🎧 Sound Library v1.1

The **workbench** release. v1.0 made the library searchable; v1.1 makes it *usable for hours
at a time* — one button keeps the whole catalog up to date, the transport finally tells you
what's playing, the waveform editor is properly hands-on, the table bends to your layout,
and closing the window no longer hangs the app.

Everything is still local, offline, and free of subscriptions and LLMs.

## ⬇️ Download — Windows, no install, no Python
Grab **`SoundLibrary_v1.1_win64.zip`** below, unzip, and double-click `app\SoundLibrary.exe`.
Then click **Choose library folder**, pick your sounds, and go.
> First launch may show a Windows SmartScreen prompt (the app is unsigned): **More info → Run anyway**.
> **Everything's bundled** — text, semantic, Find-similar, chop, loop *and* **CLAP search-by-sound**
> (for CLAP, click **Download CLAP** once to fetch the model; the next **Rescan library** builds the index).

**Upgrading from v1.0?** Just replace the folder. Your ratings, tags, levels and analysis live
*with your audio*, not in the app, so nothing is lost. Column widths and order are per-user
prefs and start at the defaults.

---

## ✨ What's new in v1.1

### 🔄 One button keeps everything up to date
- **"Rescan library" is now the single end-to-end updater.** It runs the whole chain in order —
  catalog scan → chop + loudness analysis → acoustic fingerprints → semantic index → CLAP index
  (if you've downloaded the model) — each step **incremental** (only what's new or changed) and
  each in the background, so the app stays usable throughout. Per-step progress reads out on the
  button itself (*"Updating 3/5: fingerprints 812/1440"*).
- It also **runs automatically at startup**, so a library you added files to yesterday is caught
  up without you thinking about it.
- The separate **Analyse Audio / Update semantic index / Update fingerprints / Build CLAP index**
  buttons are **gone** — folded into this one. (**Download CLAP** stays: it's a one-time model fetch.)
- Fixes analysis in the standalone build, which previously tried to shell out to a Python that
  end users don't have.

### ▶️ Playback that tells you what's going on
- **The playing row is outlined in yellow** — no more hunting for what you're hearing.
- **Three independent transports** — Track, Loop and Chops each own their play button, and each
  button only ever reflects *its own* kind. Starting one supersedes the others; only one thing
  plays at a time. **Space** toggles whichever you used last.
- **Clicking a different row stops the old one** (with Autoplay off) instead of leaving it running.
- **Loop and chop previews now show the playhead**, mapped back onto the original file's timeline
  so the cursor tracks the part of the waveform you're actually hearing.
- **Files the player can't handle directly are tinted red**, with a tooltip saying what to do.
- **24-bit WAVs that Godot's loader rejects now just play.** These are `WAVE_FORMAT_EXTENSIBLE`
  files — very common in commercial libraries — and they used to fail silently. Press Play and the
  app quietly makes a 16-bit sibling and plays that. Same for MP3/OGG/FLAC/AIFF, decoded on demand.

### ✂️🔁 A hands-on waveform editor
- **Drag handles on the loop region edges** — grab either end of the yellow region and move that
  end only, with the other end held fast.
- **The blue chop boundaries drag too**, so you can nudge one piece without re-tuning the
  thresholds for the whole file. Make chops / Play chops follow exactly what you see.
- **The crossfaded ends of a loop are shaded violet**, labelled with the fade length — you can see
  how much of your region is blended rather than heard in place, clamped exactly as the baker does.
- **"Min loop s"** sets a minimum length for **Suggest loop**: rhythmic content grows by *whole
  cycles* (a part-cycle would land the wrap off-beat), textures widen their sustain plateau, and a
  file too short to satisfy it returns the longest loop it can and says so.
- **Times are shown to the millisecond** (`m:ss.mmm`) across the transport, status lines and chop
  columns. You edit audio in milliseconds; a rounded second was lying to you.

### 📊 A table that bends to your layout
- **Drag a column header sideways to reorder columns** — a gold insertion line and a ghost label
  show where it'll land — and **the order is remembered** between sessions.
- **Column resizing now lands exactly where you drop it.** Columns used to stop at a different
  width each (the table silently refused to go narrower than its own title text) and the next drag
  would jump; titles now elide to fit, and the per-column filter controls shrink with them.
- **New Directory column** — the file's full folder path, sortable, text-filterable, with the full
  path on hover. Handy when two bundles use the same filenames.

### 🚪 Closing the window actually closes it
- **Fixed: the app could hang on X / Alt-F4.** Because the update pipeline runs at startup, most
  sessions had a background job going, and quitting waited for it — potentially minutes of
  analysis across 7,000 files, which reads as *"not responding"*.
- Close is now intercepted: preferences are saved, running jobs are **asked to stop** (they wind
  up in about 40 ms), stragglers are killed after 2.5 seconds, and the window closes as soon as
  nothing is running. Typical close is well under a second.
- **Your index can no longer be corrupted by a quit.** `index.json` and the search indexes are
  written atomically, and a cancelled catalog scan discards its partial result rather than writing
  a catalog missing every file it hadn't reached yet.

---

## 🚀 Getting started (from source)
1. Point `library.cfg` at your audio folder (or use **Choose library folder** in-app).
2. `py -m pip install -r indexer/requirements.txt`
   (plus `indexer/requirements-clap.txt` for CLAP search-by-sound).
3. Run in Godot 4.6 (`--path app`) — the first launch indexes the library for you.
4. Click **Download CLAP** once if you want search-by-sound; the next **Rescan library** builds it.

Your audio lives **outside** the repo; your ratings, tags, levels and analysis live **with the
audio**, never in git.

---

<details>
<summary><b>📦 What Sound Library is (from v1.0)</b></summary>

A fast, local, **searchable catalog + audition/edit workbench** for large sound-effects
libraries — built for the [Sonniss GDC Game Audio Bundles](https://sonniss.com/gameaudiogdc)
(~7,000 WAVs, ~217 GB), but it works on any folder of audio.

### 🔎 Browse & search
- **Excel-style table** with per-column filters (text box, tick-boxes, or a two-knob min–max
  range slider — unit-aware: mm:ss, kHz, MB, dB), click-to-sort, zebra rows.
- **Three ways to find a sound:**
  - **Text filter** — space-separated AND terms across name/description/tags.
  - **Semantic search** — describe it in words (*"guns shooting"*); ranks by the **meaning**
    of the metadata (tiny local sentence model, no internet, no LLM).
  - **CLAP search** — describe it (*"creepy metallic scrape"*) and rank by the **actual sound**,
    whatever the file is named.
- **Right-click → Find similar** — point at a sound and rank the library by how it *sounds*.
- One **Keywords panel** with a **Filter / Semantic / CLAP** picker.

### 🔊 Audition & organise
- **Star ratings**, **plays** counter, free-text **tags** — stored *with your library*, so they
  survive re-indexing.
- **Spreadsheet-grade editing**: drag-select a range, Shift/Ctrl extend, **Ctrl+C / Ctrl+V**
  (Excel-compatible), Del to clear, type to overwrite a whole selection.

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

### 🧠 Search tech (all local, offline)
- **Semantic (text→meaning):** BAAI `bge-small` embeddings via `fastembed` (ONNX, ~50 MB, CPU).
- **CLAP (text→sound & sound→sound):** `laion/clap-htsat-unfused` run **as ONNX (no PyTorch)** —
  audio pre-processing reimplemented in NumPy to match the model exactly, downloaded on demand
  (~120 MB). **GPU-accelerated** via DirectML/CUDA (~7 min to index the full library on a modern GPU).
- **Lightweight fingerprints:** a tiny MFCC/spectral vector for "Find similar" with zero extra deps.

</details>

---

## 📝 Notes
- Everything runs offline; nothing is uploaded. The only network access is the optional
  one-time CLAP model download.
- **Full changelog:** [`v1.0...v1.1`](https://github.com/benedictcarter/sound_lib/compare/v1.0...v1.1)
- `SoundLibrary_v1.1_win64.zip` — 158 MB (381 MB unzipped)
  SHA-256 `a410e5bdf52058a6c9df106bd4bf4369a31412b9e6ef262172f36e1d90f79bde`
