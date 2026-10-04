# impeccable command map

Edit `data.py` for definitions and pairings, `gen.py` for the grouped layout, and `build.py` for the standalone page wrapper. The main rail reads setup → plan/build → diagnose → optional fix/style/motion groups → polish; utilities have a separate bottom lane. Group arrows show order of use rather than individual command prerequisites.

From this directory, regenerate with a local Archify checkout (set `ARCHIFY_ROOT` to its `archify/` package directory):

```bash
python3 gen.py
node "$ARCHIFY_ROOT/bin/archify.mjs" finalize architecture commands.json commands.html --quality showcase --out-dir "$SITE_QA_DIR/archify" --json
node "$ARCHIFY_ROOT/bin/archify.mjs" visual-check commands.html --out-dir "$SITE_QA_DIR/archify" --summary --require-provenance
python3 build.py index.html
```

`SITE_QA_DIR` points to the dated `_tmp/` screenshot folder. If needed, clone `https://github.com/tt-a1i/archify` into `_tmp/archify/`; the package directory is `_tmp/archify/archify/`. Keep `commands.html`, delivery sidecars and visual-check evidence as temporary build artifacts. Commit `commands.json` and the finished `index.html` with the generator sources. The page embeds its map and assets; loading it needs no Archify checkout or server dependency.
