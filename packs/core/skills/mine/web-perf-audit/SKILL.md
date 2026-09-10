---
name: web-perf-audit
description: Audit a web page's real loading behaviour from a browser trace — LCP, CLS, image priority, third-party weight, and whether the point of the page loads before the furniture. Use when asked to make a page faster, to explain a Core Web Vitals number, to compare a before/after trace, or when a page "feels slow" and you need evidence rather than a guess.
---

# Web performance audit

Field measurement from a real browser, not lab guesses. The goal is usually LCP — either
lowering it, or discovering the reported number is not measuring the thing anyone looks at.

**Attribute before you infer.** Every wrong answer recorded at the bottom of this file came
from reasoning about a plausible cause instead of asking the browser which element, which
frame, which importer. Attribution is nearly always one observer or one flag away.

## The loop

1. **Capture** a trace (below), or take one you have been handed.
2. **Read it** with the analyser: `pnpm perf-trace summary <trace.json>`.
3. **Attribute** whatever looks wrong — element, frame, importer — before proposing a fix.
4. **Change one thing.**
5. **Re-measure and compare**: `pnpm perf-trace compare <before> <after>`.

Stop when the number moves or the evidence says the number was never the problem.

## Capturing a trace

Conditions that expose problems a fast desktop hides:

- Cold cache, fresh profile (isolated browser context, or incognito)
- **Slow 4G** network, **4× CPU** throttling
- Record with reload, so the trace starts at navigation
- Desktop 1440×900 and a phone viewport — the fold differs and so does the LCP element

Two setup traps:

- **Accept the cookie banner first, then reload.** Otherwise the consent dialog is often
  the largest element on screen and becomes the LCP, hiding the content's real number.
- **Auth-gated environments.** Feature/staging hosts behind basic auth reject a fresh
  isolated context with `ERR_INVALID_AUTH_CREDENTIALS`. Use a context that already holds
  the credentials, or ask for them.

Driving the browser directly (Chrome DevTools MCP) works for public pages and is
repeatable. For anything needing a login or a specific profile, ask for a handed-over
trace instead — and say so rather than quietly measuring the wrong thing.

## What to look at, in order

**1. Is the LCP element the point of the page?**
If LCP is the header logo, a cookie dialog, or a stray paragraph, the page has no content
worth measuring yet — that is the finding. Read the candidate list: the *last* one wins,
so an early content candidate followed by a late larger element means the content is fine
and something else is stealing the title.

**2. Was the LCP resource discovered late, or delivered slowly?**
Split it. `load delay` is discovery, `load duration` is delivery. They have opposite fixes:

| Symptom | Fix |
|---|---|
| Late discovery, fast download | Preload it. `fetchPriority: "high"` if it is the LCP |
| Early discovery, slow download | Reduce contention, or shrink the asset |
| Both fine, but LCP is still late | The element is not painting — it is gated on hydration |

That third row is the one people miss. Bytes arriving and pixels painting are separate
problems, and a preload fixes only the first.

**3. What competed?** `pnpm perf-trace contention <trace>` lists what was in flight when
the LCP resource was requested. On HTTP/2 and HTTP/3 every stream gets a share, so a 0.5 KB
file behind 800 KB still takes a second. Size does not decide order — priority does.

**4. Third-party weight.** `pnpm perf-trace thirdparty <trace>`. Anything third-party
starting before the page has painted is competing for a link the content needs.

**5. CLS, main frame only.** Then attribute it (below).

## Attribution recipes

**Which element is the LCP** — size alone will not tell you:

```js
new PerformanceObserver((l) => {
  for (const e of l.getEntries()) console.log(e.startTime, e.size, e.url, e.element);
}).observe({ type: "largest-contentful-paint", buffered: true });
```

**Which element shifted** — a trace gives node ids, not elements:

```js
new PerformanceObserver((l) => {
  for (const e of l.getEntries()) {
    if (e.hadRecentInput) continue;
    for (const s of e.sources) console.log(e.value, s.node, s.previousRect, s.currentRect);
  }
}).observe({ type: "layout-shift", buffered: true });
```

A source rect of `[0,0,0,0]` means "no box in the viewport" — **not** "removed".

**Which module pulled a dependency in** — a bundle analyser shows what is in a chunk, never
who imported it. Add a temporary webpack plugin on `compiler.hooks.done` that writes
`stats.toJson({ modules: true, reasons: true })`, then walk the reasons upward. Remove it
after.

**INP needs real interactions.** A load trace contains none. Drive genuine clicks, then read
the breakdown: **input delay** is the part a busy main thread inflates. A low input delay
means the main thread was free and the JS bundle is not hurting responsiveness — whatever
its size.

## Fixes that keep working

- **Preload the LCP resource.** React 19 forwards `fetchPriority` onto the preload link it
  emits. For a CSS `background-image` — which gets no automatic preload and cannot take
  `loading` or `fetchPriority` — call `preload(url, { as: "image", fetchPriority: "high" })`
  from `react-dom` during render.
- **`loading="lazy"` below the fold.** In a server-rendered React 19 app this also *removes*
  the preload link, which is usually the larger win: one page went from 63 image preloads
  to 6 that way.
- **Reserve the box.** Explicit CSS width and height reserve space as well as `aspect-ratio`
  does; check before assuming an image is unsized. Verify by breaking every image and
  re-measuring — if the height holds, there is no shift to fix.
- **Render the content on the server** when its data is already prefetched. This is the fix
  when bytes arrive early but paint late.
- **Never `loading="lazy"` on a `display: none` element.** The browser never brings it into
  view, so it never loads at all. To defer hidden tracking frames, delay *mounting* until
  after the load event instead.

## Traps, each one paid for

- **Read LCP and CLS on the main frame only.** A third-party `about:blank` iframe reports
  its own. One page read CLS 0.13 across all frames and 0.012 on its own.
- **Distrust anything measured before first paint.** Reading `scrollHeight` forces layout
  while rendering is still blocked. A probe once "found" a 27 662 px document that collapsed
  6 ms *before* first paint — invisible to every reader, and it was nearly promoted to the
  top finding.
- **Compare runs from the document request**, not navigation start. A 773 ms "regression"
  was entirely a later document start on a colder host. `perf-trace compare` normalises this.
- **A warm-cache trace cannot answer a delivery question.** If most requests report
  `fromCache` and roughly zero bytes moved, priority and contention are unmeasurable. Say so
  and re-capture.
- **A deep import does not fix a barrel leak if the target file is itself the problem.**
  Three components imported `themes/theme-service` directly to dodge a barrel and still got
  410 KB of Node polyfill, because that file held the server half.
- **Check whether the metric is measuring the content at all** before optimising it. One
  page's "15.5 s LCP" was a cookie dialog; its real content LCP was 3.4 s and needed no work.

## Reporting

Lead with the number that changed and the evidence. Then:

- Separate what you measured from what you inferred.
- Give the cost as well as the win — a fix that trades 300 ms of script delivery for 10 s of
  LCP is still worth stating in both directions.
- When a hypothesis was wrong, say so plainly and move on. It is cheaper than letting
  someone act on it.

## The analyser

In the kramp frontend monorepo:

```
pnpm perf-trace summary     <trace.json>
pnpm perf-trace images      <trace.json>
pnpm perf-trace thirdparty  <trace.json>
pnpm perf-trace contention  <trace.json>
pnpm perf-trace shifts      <trace.json>
pnpm perf-trace compare     <before.json> <after.json>
```

Its companion `pnpm shell-size` measures the bundle on disk; this one measures what the
browser did with it. Bundle findings belong in
`docs/simplification/lib-restructure-perf.md`, which tracks the hypotheses and baselines.

Elsewhere, copy `tools/perf-trace.mjs` — it is a dependency-free Node script that reads a
DevTools trace JSON.
