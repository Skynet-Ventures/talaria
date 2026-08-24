# Web-search transcript results

Talaria renders a bounded specialist card only for Hermes' exact,
case-sensitive `web_search` tool. This slice is based on the repository's
pinned Hermes authority (`40643cba`); names that merely resemble web search
remain generic tool evidence.

## Admission

- Results must be explicit structured arrays, either directly or under the
  known Hermes result aliases and wrappers. Prose containing links is never
  promoted.
- Traversal depth, visited nodes, candidate rows, visible rows, strings, and
  decoded JSON containers are bounded before display work.
- A result destination is admitted only when it is an absolute HTTP or HTTPS
  URL with a nonempty host and no user information, control characters, bidi
  controls, backslashes, or unsafe percent-decoded form.
- Titles, queries, snippets, diagnostics, and restored Codable snapshots are
  sanitized and re-admitted. A nameless result may retain a bounded inert
  candidate and search-specific explicit-error bit, but only exact tool-call
  ID pairing with `web_search` can promote either one. Other exact tool names
  discard both without applying that search-specific failure bit.

## Presentation

Each linked result shows the admitted destination host next to its title so a
deceptive title cannot hide where the action goes. Opening and copying are
explicit 44-point user actions; Talaria does not navigate to or fetch a result
automatically. Queries, hosts, diagnostics, and literal snippets are
selectable, and snippets have an explicit copy action. Semantic text styles,
bounded VoiceOver labels, and the transcript's reduced-motion disclosure
policy apply on mobile.

Generic arguments/results remain inspectable alongside specialist evidence.
Exact-ID hydration preserves ordered coexistence with file diffs, structured
terminal output, and ordinary tool runs. Meaningful failed specialist evidence
is monotonic across sparse replay and exact stored/live overlays.

## Verification

`ToolWebSearchRenderingTests` covers exact-name authority, aliases and
wrappers, traversal and text budgets, URL deception, control/bidi sanitation,
Codable re-admission, omitted-name exact pairing, completion-before-start,
generating-placeholder coalescing, late replay safety, failure monotonicity,
overlay behavior, ordering, accessibility, selection, and reduced motion.
