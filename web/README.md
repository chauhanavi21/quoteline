# Quoteline web UI

A single-page, no-framework view of the engine's output. Every number on the
page comes from `quoteline export`; nothing is typed in.

Open `index.html` by double-click. It needs no server.

## Rebuild after changing the engine or the page

```
dune exec quoteline -- export --seed 42 --events 20000 --out web/data
node web/build-data.mjs web/data web/data.js     # bundle the JSON
node web/build-bundle.mjs                         # bundle the JS modules
```

`data.js` and `app.bundle.js` are committed so the page works straight from a
clone. The sources are `viz.js`, `book.js`, `charts.js`, `charts2.js`, `app.js`.

Why a bundle: browsers block `<script type="module">` on `file://`, so a page
opened by double-click needs one classic script.

## Behaviour

- Respects `prefers-reduced-motion`: no scroll animation, no auto-playing replay.
- Dark and light themes from the same tokens; the toggle is remembered.
- Every chart has a table view and keyboard-driven tooltips.
