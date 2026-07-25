# Plan: integrate the Templatical WYSIWYG email editor

Status: **approved, not started.** The upstream maintainer agreed on
2026-07-25 to accept this as a contribution to
[`lunogram/platform`](https://github.com/lunogram/platform), so the work is
intended to land upstream as a series of pull requests.
Related: [`AGENTS.md`](AGENTS.md) (verification results, architecture notes,
branching rules)

Each phase below is a separate branch and a separate PR, cut from
`upstream/main`:

| Phase | Branch | Status |
| --- | --- | --- |
| 1 — renderer second path | `feat/templatical-renderer` | **done**, pushed |
| 2 — Go template type | `feat/templatical-template-type` | **done**, pushed |
| 3 — console editor | `feat/templatical-editor` | **done**, pushed |
| 4 — feature wiring | `feat/templatical-editor` | **mostly done**, pushed |

Each branch is stacked on the previous one, so a phase can be reviewed with
only its own diff. Rebase down the stack as earlier PRs land.

## Goal

Let users compose campaign and journey emails visually with
[Templatical](https://github.com/templatical/sdk), instead of hand-writing
React Email JSX in the Monaco editor. The existing code editor stays — this is
additive, not a replacement.

## Approach

Templatical stores templates as portable JSON and renders **JSON → MJML →
HTML**. Lunogram's send path renders **React Email JSX → HTML** through the
Deno renderer. Rather than converting Templatical JSON into React Email JSX
(which would mean maintaining a parallel reimplementation of Templatical's
renderer against a pre-1.0 target, and inheriting React Email's email-client
quirk coverage instead of MJML's), we add a **second render path inside
`renderer/`**, selected by a discriminator on the stored bundle.

This is cheap because `compiled_js` is **opaque to Go**:
`EmailRenderer.Compile` (`internal/pubsub/email.go`) sends `{source}`, receives
`{compiled_js}`, SHA-256s it for cache invalidation, and stores it; `Render`
hands it back with props. Go never parses it. The bundle is already a JSON
envelope — `renderer/compiler.ts` returns
`JSON.stringify({ code, tailwindConfigBindings })`.

There are exactly **three call sites** to reason about:

| Call site | When |
| --- | --- |
| `internal/http/controllers/v1/management/templates.go:261` | `Compile` on template save |
| `internal/providers/channels/email.go:74` | `Compile` on send, if no cached bundle |
| `internal/providers/channels/email.go:80` | `Render` on send |

Preview, test send, real send and plain-text generation all funnel through
these, so one branch in the renderer covers every surface.

## Already verified

Probed against the Deno version `renderer/Dockerfile` pins (2.2.6) —
details and gotchas in [`AGENTS.md`](AGENTS.md):

- `@templatical/renderer` + `@templatical/types` run under Deno. 36 KB, pure
  ESM, **no Node built-ins**, one runtime dependency. Both MIT.
- `mjml@5` handles MJML → HTML under Deno with zero errors. **Its API is
  async** — must be awaited. `mjml@4` also works (sync).
- A rich document (three multi-column sections, five linked images, table,
  divider, social icons) renders correctly: proportional column widths,
  `<mj-group>` for `stackOnMobile: false`, responsive `@media`, and
  `<!--[if mso]>` Outlook conditionals.
- **Merge tags land on Liquid for free.** `convertMergeTagsToValues()` turns
  `<span data-merge-tag="{{ user.first_name }}">Label</span>` into the literal
  `{{ user.first_name }}`, which survives MJML → HTML intact and is then
  substituted by the existing downstream Liquid pass
  (`render.RenderJSON` in `internal/pubsub/consumer/campaigns_render.go:161`).

## Current state: the seam already exists

`console/src/views/campaign/template/mail/editor/codeEditor/hooks/useEditorMode.ts`
already models three modes:

```
EditorMode = "code" | "builder" | "blocks"
```

- `code` — Monaco + React Email. The only mode available in OSS today.
- `builder` — AI-assisted authoring. Enterprise-only.
- `blocks` — the visual block editor. **Scaffolding is in OSS, implementation
  is not**: types are opaque placeholders (`EmailDocument = Record<string, unknown>`),
  the component comes from `@lunogram-enterprise/block-editor` (stubbed to an
  inert proxy by the Vite plugin in OSS builds), and `getInitialEditorMode()`
  gates `blocks` behind `isEnterprise`.

Mode switching, the confirm-on-switch dialog, the editor/preview-text tab bar
and persistence are all already written. The work is to supply an OSS `blocks`
implementation behind that seam.

Existing contracts to satisfy:

| Contract | Location |
| --- | --- |
| `handleBlocksChange(doc, jsxSource)` | `useEditorMode.ts` |
| writes `data.blocks`, `data.editorMode`, `data.code.source` | `useTemplatePersistence.ts` |
| `EmailTemplateData` | `console/src/types.ts` |
| Zod schema (`editor: "code" \| "visual"`, currently unused) | `console/src/validation/campaign/template/data.ts` |

## Data flow

Today:

```
console (Monaco)  --JSX-->  templates.go  --email.compile-->  renderer (Sucrase)
                                                                    |
                                                              {code, twBindings}
                                                                    |
send: email.go --bundle+props--> email.render --> @react-email/render --> HTML + text
                                                                    |
                                            render.RenderJSON (Liquid) --> final
```

Proposed, with the second path:

```
console (Templatical) --doc JSON--> templates.go --email.compile--> renderer
                                                                       |
                                                    {kind:"templatical", doc, mjml}
                                                                       |
send: email.go --bundle+props--> email.render --> renderToMjml + mjml2html --> HTML
                                                  + html-to-text          --> text
                                                                       |
                                            render.RenderJSON (Liquid) --> final
```

Bundles with no `kind` fall through to the existing React Email branch, so
current templates keep working untouched and no migration is needed.

**Safety property worth knowing:** the Go `EmailTemplateData` struct
(`internal/providers/channels/email.go:35`) has no `blocks`/`editorMode`
fields, so `ComposeEmailTemplateData`'s unmarshal → marshal round-trip drops
them. The raw Templatical document therefore never reaches the Liquid pass,
where its `{{ }}` contents would otherwise be misinterpreted — the same reason
`email.Code` is explicitly cleared today.

---

## Phase 1 — Renderer: second render path — DONE

Shipped on `feat/templatical-renderer`. Zero Go changes, zero wire-format
changes. New file `renderer/templatical.ts`; branches in `renderer/compiler.ts`;
`renderer/compiler_test.ts` covers both paths.

**Rendering happens at compile time, not per render.** This deviates from the
original sketch. Templatical output depends only on the document — merge tags
survive as literal `{{ … }}` for the downstream Liquid pass, so props cannot
affect the result. The bundle is therefore
`{ kind: "templatical", html, plainText }` and `renderTemplate` just returns it.
Rendering per call would have re-run MJML once per recipient.

Three things found while building it, all now handled:

- **`html-to-text` uppercases headings by default**, turning a merge tag in a
  heading into `{{ USER.FIRST_NAME }}` — which Liquid cannot resolve, so the
  raw tag would ship in the text part of every email. Disabled for `h1`–`h6`.
- **mjml needs permissions the service never granted**: `--allow-sys=homedir`
  (env-paths, read on import) and `--allow-read` (it stats its `filePath`
  option before parsing). Without them the service dies on first render. Added
  to `renderer/Dockerfile`, the `deno.json` tasks, and `docker-compose.dev.yml`.
- **Social icons really do point at jsDelivr.** `TEMPLATICAL_SOCIAL_ICONS_BASE_URL`
  overrides the base URL; hosting the assets is still Phase 5.

**Verified:** 5/5 tests pass inside the production image, and a NATS round trip
against the running service returns `kind = templatical`, 6.2 KB of HTML with
merge tags, images and Outlook conditionals intact.

Pre-existing issues left alone: `deno.json` has a react/react-dom version skew
(react 18.3.1 vs react-dom 19.x via `@react-email/render`'s caret range) that
trips React's isomorphic check under `deno test` but not under `deno run`;
`deno fmt` would reformat untouched lines in `compiler.ts` and `main.ts`.

**Test:** a fixture document + snapshot, run under `deno task test`.

## Phase 2 — Go: explicit template-type discrimination — DONE

Shipped on `feat/templatical-template-type`.

`EmailTemplateData` gains `type` (`""`/`"react-email"` → JSX, `"templatical"` →
visual document) and `blocks`. A new `CompileSource()` method picks the source
by type, and both compile call sites use it —
`internal/http/controllers/v1/management/templates.go` on save (via
`templateDataEnvelope.compileSource()`, which reads `type` and `blocks` out of
the untyped `Remaining` map) and `internal/providers/channels/email.go` on send.
Both previously gated on `code.source` being non-empty and would have skipped a
Templatical template outright. The console types and the Zod schema were
widened to match.

**`email.Blocks` must be cleared after rendering**, alongside `email.Code`.
Before this phase the Go struct had no `blocks` field, so the
unmarshal → marshal round-trip dropped the document by accident. Adding the
field removed that protection: the composed payload goes to
`render.RenderJSON`, which walks the whole JSON and would evaluate merge tags
and any literal `{{ }}` in user-authored text.

**Verified:** new tests in `email_templatical_test.go` cover source selection
per type, the clearing behaviour, and the untyped-fallback path; all four
template controller tests pass; the full `management` package passes in 309s.

## Phase 3 — Console: mount the editor in `blocks` mode — DONE

**Files:** new `console/src/views/campaign/template/mail/editor/blockEditor/`,
plus `useEditorMode.ts`, `CodeEditor.tsx`, `NewCampaign.tsx`, `Template.tsx`,
`validation/campaign/template/data.ts`, `console/package.json`

1. Add `@templatical/editor` (+ `@templatical/core`, `@templatical/types`).
2. React wrapper around the imperative API: `init({ container, onChange })` in
   an async `useEffect` against a `ref`, teardown on unmount, guarded against
   double-mount in StrictMode.
3. Ungate `blocks` for OSS in `getInitialEditorMode()` and drop the two
   `isEnterprise &&` guards in `ModeToggle` (`CodeEditor.tsx:275`) so the
   toolbar offers a real choice instead of one lone active-looking button.
4. Wire `onChange` → `handleBlocksChange`. **See open decision 1** — the second
   argument is currently typed as JSX source, which no longer applies.
5. Reuse the existing `editor` / `preview-text` tab bar and mode-switch
   confirmation dialog rather than adding new chrome. Follow
   [`console/DESIGN.md`](console/DESIGN.md).

### Where the user chooses the editor — decided

**At template creation, not in the Editor step and not in the Content step.**

Switching afterwards is destructive — `confirmModeSwitch()` in
`useEditorMode.ts` clears `blocksData` when leaving `blocks`, which is why
`ModeSwitchDialog` exists. That makes the *first* choice the one that matters,
so it belongs at the moment the template is created. The toolbar `ModeToggle`
stays for changing your mind later, behind the existing confirmation.

Rejected: the **Content** step ("Template Setup" — subject, from, reply-to).
That is deliverability metadata scoped per locale; a creative "how do I build
this" decision buried there gets skimmed past, and would resurface every time
a locale is added.

There are two creation sites:

| Site | Trigger | Behaviour |
| --- | --- | --- |
| `NewCampaign.tsx:203` | New Campaign form, first template for `project.locale` | **Ask here.** The channel is already picked in this form, so show the editor choice when `channel === "email"`. |
| `Template.tsx:159` | Locale dropdown creates a template with `data: {}` | **Do not ask.** Inherit the mode from an existing template on the campaign so locales stay consistent. |

**Half the plumbing already exists.** `NewCampaign.tsx:205` seeds the template
with `templateSchemaMap[channel].parse({})`, and `emailTemplateDataSchema`
(`validation/campaign/template/data.ts:11`) already stamps
`editor: z.enum(["code", "visual"]).default("visual")` into `data` on every new
email template — a field nothing currently reads. What is missing is a control
in the form and a read in the editor.

**Resolve the field collision first.** Two parallel concepts exist today:

- `data.editor` — `"code" | "visual"`, written at creation by the Zod schema,
  never read.
- `data.editorMode` — `"code" | "builder" | "blocks"`, written on every save by
  `useTemplatePersistence.ts`, read by `getInitialEditorMode()`.

Converge on `editorMode` and retire `editor`. Nothing reads `editor`, so
existing rows carrying `editor: "visual"` are inert and no migration is needed.

**One more thing to change:** `CodeEditor.tsx:487` seeds
`DEFAULT_REACT_EMAIL_TEMPLATE` whenever `data.code.source` is absent, so a
template created in visual mode would still be pre-filled with React Email
JSX. Gate that seeding on the resolved mode being `code`.

**Acceptance:** New Campaign → pick the visual editor → the Editor step opens
Templatical with an empty document (no JSX seeded) → drag blocks → save →
reopen and the document round-trips → preview shows the rendered email. Adding
a second locale keeps the same editor without asking again.

## Phase 4 — Feature wiring — MOSTLY DONE

1. **Merge tags** — configure Templatical's merge-tag syntax to `{{ }}` and
   populate the picker from the project's user/event schema (the console
   already surfaces these via the schema map used elsewhere).
2. **Media library** — point Templatical's media hooks at the existing
   `console/src/components/media-manager/` and the uploads/storage backend
   rather than introducing a second asset store.
3. **Plain text** — feed the `preview-text` tab from the renderer's derived
   text, honouring the existing custom-override behaviour
   (`plaintext.custom` wins).
4. **Test send** — confirm `useSendTestEmail` works unchanged on this path.
**Done:** merge tags (campaign variables mapped to the picker, liquid syntax,
object/array variables dropped), media library (the editor's Browse Media
opens Lunogram's own manager via a promise bridge), plain text (Preview Text
tab reads the backend-derived text from the bundle), and a Preview tab that
resolves merge tags against the recipient chosen in the toolbar.

**Known limitation:** the Preview and Preview Text panels, and the campaign
detail preview, all read the bundle — which the backend writes on save. They
therefore reflect the last save, not unsaved edits. Live preview would mean
rendering MJML client-side; decide before promising it.

**Still open:** send test on this path is unverified end to end, and starter
templates are untouched — `EmailTemplate` in `console/src/types.ts` already
   carries an optional `blocks` field, and the gallery is fed by the
   `WEBHOOK_EMAIL_TEMPLATES_URL` endpoint. Decide whether to ship starter
   Templatical documents.

## Phase 5 — Hardening

1. Custom blocks: wire `renderCustomBlock` / `getCustomBlockStylesheet` in
   `RenderOptions`, or explicitly disable custom blocks for now.
2. Self-host social icon PNGs.
3. Render-failure handling: a malformed document must not break the send
   pipeline — surface the error in the editor.
4. Bundle-size check on the console build; renderer image-size check once
   `mjml` is added.
5. Docs: update `CONTRIBUTING.md` / `docs/` for the new editor mode.

---

## Decisions

1. **No enterprise edition.** This fork does not build it (confirmed
   2026-07-25), so `blocks` can simply *be* Templatical. No coexistence with
   `@lunogram-enterprise/block-editor` is required, and there is no need for a
   fourth editor mode or a build-time swap.
2. **`handleBlocksChange` loses its `jsxSource` argument.** It exists only
   because the enterprise block editor emits JSX. Templatical does not, and
   with (1) settled the signature is ours to change — the argument would carry
   nothing meaningful. Narrow it to `handleBlocksChange(doc)`.
3. **The document lives in `data.blocks`, keyed by `data.type`.** Phase 2. The
   alternative — stashing it in `data.code.source` — needs no Go changes at all
   but puts a JSON document in a field named "source" that means JSX
   everywhere else.
4. **`code` mode stays.** Keeping React Email available means existing
   templates and power users are unaffected.

## Risks

| Risk | Notes |
| --- | --- |
| **Licensing** | `@templatical/editor` is FSL-1.1 (converts to MIT after two years). `@templatical/renderer` and `@templatical/types` are MIT, so the backend links only MIT code — the FSL dependency is confined to the console. Confirm FSL is acceptable for this fork's distribution model before Phase 3. |
| **Pre-1.0 SDK** | Version 0.19.0; expect breaking changes. Pin exact versions. |
| **Vue inside React** | The editor is Vue + TipTap internally. The console already bundles TipTap 3.20.1 for other editors — watch for duplicate instances and add `dedupe` entries in `console/vite.config.ts` if needed (React is already deduped there for the same reason). |
| **Renderer image weight** | `mjml` pulls a large dependency tree (babel helpers, css-tree, domutils) into the renderer container. |
| **jsDelivr social icons** | Default icon URLs point at `cdn.jsdelivr.net`, i.e. an external dependency embedded in every sent email. Must be overridden for a self-hosted platform. |
| **Custom blocks untested** | `renderCustomBlock` / `getCustomBlockStylesheet` are consumer-supplied and unverified. |
| **Deno pin** | `renderer/deno.lock` is format v5, unreadable by the pinned Deno 2.2.6; dev works around it with `--no-lock`. Consider bumping the pin as part of this work. |

## Out of scope

- Replacing the React Email code editor.
- The AI `builder` mode.
- Non-email channels (SMS, push, inbox).
- Templatical's collaboration, comments and scoring features.
