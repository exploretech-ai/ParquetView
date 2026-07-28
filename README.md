<h1 align="center">ParquetView</h1>

<p align="center">A fast, native Parquet viewer for macOS.</p>

<p align="center">
  <a href="https://github.com/Alyetama/ParquetView/releases/latest/download/ParquetView.dmg"><b>⬇️ Download for macOS</b></a>
  &nbsp;·&nbsp;
  <a href="https://alyetama.github.io/ParquetView">Website</a>
  &nbsp;·&nbsp;
  <a href="#first-launch">First launch</a>
</p>

<p align="center">
  <img src="docs/mockup.png" alt="ParquetView showing a Parquet file" width="820">
</p>

Parquet files are annoying to peek into. You either fire up Python and pandas, or hunt for some web tool you don't trust with your data. ParquetView is just a Mac app: double-click a `.parquet` file and look at it.

Opening a file reads only its footer, not the data, so file size barely affects how long it takes to show up. Scrolling then pulls in the row groups you're actually looking at.

## Download

**[⬇️ Download ParquetView for macOS](https://github.com/Alyetama/ParquetView/releases/latest/download/ParquetView.dmg)** (Apple Silicon & Intel)

Open the `.dmg`, drag ParquetView to Applications, then see [First launch](#first-launch) below (it's unsigned, so macOS needs one extra click).

## Features

- Opens huge files without reading them end to end. Scrolling pulls in row groups as you go.
- Open a file however you want: the file picker, drag-and-drop, or Finder's "Open With".
- Shows the schema and column types up front, plus a metadata panel with row count, file size, compression codec, row-group count, and the writer.
- Click a column header to sort it.
- Search, or build a proper filter with multiple conditions (contains, equals, regex, `>`, `<`, is-empty) joined by AND/OR.
- Double-click a cell to select its value so you can copy it, or type over it to edit.
- Light/dark/auto theme, row density, and font size. It remembers what you picked.

Worth knowing:

- **Sorting and searching read the whole file**, unlike scrolling. Sorting loads the column you sorted by into memory; searching streams every row group. Neither is instant on a large file.
- **A search stops after 100,000 matches** and says so in the status bar.
- **Editing a cell does not change the file.** Edits last for the session, are marked with a colored bar, and are gone when you reopen the file. Nothing is written back to the `.parquet`.

## First launch

ParquetView isn't signed with an Apple Developer ID, so macOS blocks it the first time you open it. Nothing's wrong; you just have to tell macOS you meant it. Pick one:

1. **Right-click to open.** In Finder, right-click (or Control-click) ParquetView, choose **Open**, then **Open** again.
2. **On newer macOS,** if that doesn't offer an Open button: go to **System Settings → Privacy & Security**, scroll down, and click **Open Anyway**.
3. **Or from the Terminal,** strip the quarantine flag and open it normally:
   ```bash
   /usr/bin/xattr -dr com.apple.quarantine /Applications/ParquetView.app
   ```

## Build from source

You'll need Rust 1.77+ (the floor in `src-tauri/Cargo.toml`), Node 18+, and the Xcode command-line tools.

```bash
npm install
npm run tauri build   # → src-tauri/target/release/bundle/macos/ParquetView.app
```

That builds for whatever Mac you're on. The DMG on the releases page is universal, built with:

```bash
npm run tauri build -- --target universal-apple-darwin
```

`./install.sh` does the whole thing: builds, strips quarantine flags, ad-hoc signs, copies to `/Applications`, and registers the app so "Open With" works.

`npm run tauri dev` runs it with hot reload.

One gotcha: Tauri's bundler shells out to `xattr`, and if a non-Apple `xattr` is first on your `PATH` (conda ships one), the build prints `failed to remove extra attributes from app bundle` and exits non-zero *after* the `.app` is already built. The app is fine; `install.sh` works around it by calling `/usr/bin/xattr` directly.

It's a [Tauri](https://tauri.app) app: a Rust backend with a web frontend, and the `arrow`/`parquet` crates do the actual Parquet reading.

## License

[MIT](LICENSE) © 2026 Alyetama
