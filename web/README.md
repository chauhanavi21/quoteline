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

## Tests

`web/tests/browser.mjs` opens the page from disk in a real browser and checks 31
things: every section renders in dark and light, nothing is stuck hidden, no
console errors, the replay plays, pauses and scrubs, the replayed book is never
crossed, tooltips show the value of the data point under the pointer (checked
against the data, by mouse and by keyboard), the table view and legend toggle
work, reduced motion really removes the animation, and nothing scrolls sideways
at phone width.

```
cd web/tests && npm install && npm test
```

It needs Chrome, Edge or Chromium (set `CHROME_PATH` to choose one). The suite
was mutation-checked: corrupting the replay data and deleting the
reduced-motion CSS each make it fail.
