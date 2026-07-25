# AGENTS.md

Working notes for AI agents on this repository. Human-facing setup and process
docs live in [`CONTRIBUTING.md`](CONTRIBUTING.md); this file is the short path
to being productive here.

## What this is

Lunogram is a multi-channel customer outreach platform (email, SMS, push,
in-app inbox) — campaigns, drag-and-drop journeys, segmentation. It is a fork
of the archived [Parcelvoy](https://github.com/parcelvoy/platform).

**This checkout is a personal fork** (`origin` → `MrSnoozles/lunogram`) whose
current goal is to integrate a WYSIWYG email editor. See
[Current work](#current-work-wysiwyg-email-editor) below.

## Contributing back to upstream

The work here is intended to land in
[`lunogram/platform`](https://github.com/lunogram/platform) as pull requests.
**The upstream maintainer has already agreed to accept the WYSIWYG editor
contribution** (confirmed 2026-07-25), so this is not a speculative fork — do
not re-litigate whether the feature is wanted.

Remotes:

| Remote | Repository |
| --- | --- |
| `origin` | `MrSnoozles/lunogram` (the fork) |
| `upstream` | `lunogram/platform` (PR target) |

Branching rules:

- **Never cut a feature branch from `main`.** The fork's `main` carries
  fork-local files (`AGENTS.md`, `CLAUDE.md`, `PLAN_TEMPLATICAL.md`) that must
  never appear in a pull request diff. Branch from `upstream/main`, or from
  `feat/dev-environment` while that PR is still open — it carries the `make dev`
  tooling you need to work, and rebasing onto `upstream/main` once it lands
  drops the commit cleanly.
- Before opening a PR, check for leakage:
  `git diff --name-only upstream/main <branch> | grep -E "AGENTS|CLAUDE|PLAN_"`
  should print nothing.
- Name branches to match upstream convention: `feat/…`, `fix/…`, `ci/…`.
- Commits are Conventional Commits with a scope: `feat(console): …`,
  `fix(http): …`, `test(scheduled): …`.
- Keep PRs focused — upstream's `CONTRIBUTING.md` asks for one change per PR.
  The Templatical work is deliberately split into separate branches per phase
  (see [`PLAN_TEMPLATICAL.md`](PLAN_TEMPLATICAL.md)).
- Rebase on `upstream/main` regularly; this is a multi-week effort against a
  moving target.

Branches in flight:

| Branch | Contents | Status |
| --- | --- | --- |
| `feat/dev-environment` | Live-reload dev setup, corrected env-var docs | ready to PR |
| `main` (fork-local) | Agent docs and the integration plan | never PR'd |

## Stack and layout

Go backend + React console + a Deno side-service, with WASM plugins.

| Path | What lives there |
| --- | --- |
| `cmd/lunogram/` | Single binary entrypoint; wires config → stores → pubsub → HTTP. |
| `internal/` | All backend code (not importable externally). |
| `internal/config/` | Every env var, as struct tags. **The source of truth for configuration.** |
| `internal/store/` | Postgres access, split into three databases: `management`, `subjects`, `journey` (+ `rbac`). Migrations live under each store's `migrations/`. |
| `internal/http/controllers/v1/` | HTTP API — `management/` (console) and `client/` (SDK/public). |
| `internal/http/console/` | Serves the embedded console bundle (`dist/`) for production builds. |
| `internal/pubsub/` | NATS JetStream publishing/consumers. Subjects in `pubsub/schemas/events.go`. |
| `internal/integrations/` | Loads the embedded provider/action WASM modules. |
| `modules/` | WASM guest sources (own `go.mod` each), built with TinyGo. |
| `pkg/modules/` | Shared types between host and WASM guests — kept free of runtime deps so TinyGo can compile them. |
| `console/` | React 18 + Vite + TypeScript + Tailwind 4 frontend. |
| `renderer/` | Deno service that compiles and renders React Email templates over NATS. |
| `docs/` | Next.js documentation site (separate pnpm project). |

### How an email actually gets rendered

Worth internalising before touching the editor:

1. The console stores an email template as `templates.data` JSONB. For email
   that shape is `EmailTemplateData` (`console/src/types.ts`) — `subject`,
   `from`, `preheader`, `plaintext`, and `code.source` holding **React Email
   JSX**.
2. The Go backend does not render JSX. It publishes over NATS:
   - `email.compile.<project>` → the Deno renderer transpiles JSX with Sucrase
     into a self-contained bundle, which is cached.
   - `email.render.<project>` → the renderer executes that bundle with props
     and returns HTML + plain text.
3. So **the renderer service must be running** for previews, test sends, and
   real sends to work. `make dev` starts it.

## Development

```bash
cp .env.example .env
cp console/.env.example console/.env
make dev
```

Opens on **http://localhost:5173** (console, hot reload) with the Go API on
**:8080** (rebuilt by [air](https://github.com/air-verse/air) on `.go`, `.sql`
and `.wasm` changes). Vite proxies `/api`, `/static`, `/unsubscribe` and
`/preferences` to :8080, so use :5173 while developing — not :8080, which
serves the last *built* console bundle.

Log in with `admin@localhost` / `admin` (from `AUTH_DRIVER=basic`).

| Command | Does |
| --- | --- |
| `make dev` | Backing services + API + console, live reload on all of them. |
| `make dev-api` / `make dev-console` | Just one half of the above. |
| `make dev-services` / `make dev-down` / `make dev-logs` | Postgres, Redis, NATS, renderer in Docker. |
| `make lint` | eslint (console) + golangci-lint. Run before proposing a change. |
| `make test` | Full Go suite, `-race`. Needs Docker — store tests spin up real containers (`internal/container/`). |
| `make test-short` | `-short` subset; skips the container-backed tests. |
| `make generate` | `go generate ./...`, console OpenAPI types, then `gofmt`. |
| `make modules` | TinyGo-builds the WASM provider/action modules. Slow; only needed after touching `modules/`. |
| `make build` | Production build (modules + console bundle + binary). |

Console-only commands run from `console/`: `pnpm dev`, `pnpm lint`,
`pnpm test` (vitest), `pnpm build`.

### Configuration gotchas

- **The binary never reads `.env`.** It parses the process environment via
  `caarlos0/env` struct tags. `etc/dev.sh` exports `.env` before starting the
  API; `docker compose` reads it only for `${...}` interpolation.
- Env var names come from nested `envPrefix` + `env` tags in
  `internal/config/config.go` — e.g. the store URIs are
  `POSTGRES_MANAGEMENT_URI`, `POSTGRES_SUBJECTS_URI`, `POSTGRES_JOURNEY_URI`,
  and RBAC's is `RBAC_POSTGRES_URI`. Read the struct rather than guessing.
- `internal/http/CSRFConfig` exists but is not wired into any middleware.
  Setting `CSRF_*` variables does nothing today.

### Known wrinkles

- `renderer/deno.lock` is lockfile format v5, which the Deno version pinned in
  `renderer/Dockerfile` (2.2.6) cannot read. Production dodges this because the
  Dockerfile never copies the lock file; `docker-compose.dev.yml` passes
  `--no-lock` for the same reason. Bumping the pin would be the real fix.
- `make generate` rewrites `internal/wasm/test/*.wasm` because TinyGo output is
  not byte-reproducible. CI ignores this (`git diff --exit-code -- . ':!*.wasm'`)
  — don't chase those diffs.
- `console/README.md` is a leftover Create React App stub. The project uses
  Vite; ignore it.

## Conventions

- **Commits**: Conventional Commits with a scope matching the area —
  `fix(console): …`, `feat(scheduled): …`, `fix(http): …`, `test(scheduled): …`.
- **Go**: standard `gofmt`; mocks are generated by minimock into
  `*_mock_test.go`; enum strings by stringer into `*_string.go`. Never
  hand-edit `*_gen.go`, `*.sql.go`, `*_string.go`, `*_mock_test.go`.
- **TypeScript/React**: Prettier with 4-space indent, no semicolons, double
  quotes, 100 columns, trailing commas. Import alias `@/` → `console/src/`.
- **UI**: shadcn/Radix primitives in `console/src/components/ui/`. Read
  [`console/DESIGN.md`](console/DESIGN.md) before adding components or colours
  — it is the design token spec and is CI-linted.
- **API changes** flow from OpenAPI: edit
  `internal/http/controllers/v1/management/oapi/resources.yml`, then
  `make generate` to regenerate both Go server types and
  `console/src/oapi/management.generated.ts`.
- **Enterprise seams**: imports from `@lunogram-enterprise/*` are stubbed to
  inert proxies in open-source builds by a Vite plugin (`console/vite.config.ts`),
  and gated at runtime by `isEnterprise` / `__ENTERPRISE__`. Go equivalents use
  the `enterprise` build tag (`*_enterprise.go`). Code that must work in this
  fork belongs on the OSS side of those seams.
- PRs: keep them focused, add tests, run `make lint`.

## Current work: WYSIWYG email editor

Goal: integrate [Templatical](https://github.com/templatical/sdk) so users can
build emails and campaigns visually instead of writing React Email JSX.

**The phased implementation plan lives in
[`PLAN_TEMPLATICAL.md`](PLAN_TEMPLATICAL.md)** — read it before starting
integration work. The rest of this section is the background it assumes.

### Where it plugs in

The email editor lives at
`console/src/views/campaign/template/mail/editor/`. `Editor.tsx` renders
`codeEditor/CodeEditor.tsx`, which already switches between three modes via
`codeEditor/hooks/useEditorMode.ts`:

```
EditorMode = "code" | "builder" | "blocks"
```

- `code` — the Monaco React Email editor. The only mode available in OSS today.
- `builder` — AI-assisted authoring. Enterprise-only.
- `blocks` — the visual block editor. **The scaffolding is in OSS but the
  implementation is not**: types are opaque placeholders
  (`EmailDocument = Record<string, unknown>`) and the real component comes from
  `@lunogram-enterprise/block-editor`, which the Vite stub plugin replaces with
  a no-op. `getInitialEditorMode()` gates `blocks` behind `isEnterprise`.

So the integration has a ready-made seam: implement `blocks` for the OSS build
using Templatical, backed by the existing contracts.

### Contracts to satisfy

- `handleBlocksChange(doc: EmailDocument, jsxSource: string)` — the block
  editor must emit **both** a document JSON *and* JSX source.
- `useTemplatePersistence.ts` writes `data.blocks` (the document),
  `data.editorMode`, and `data.code.source` (the JSX) on save.
- `EmailTemplateData` in `console/src/types.ts` and the Zod schema in
  `console/src/validation/campaign/template/data.ts` (which has a
  `editor: "code" | "visual"` field, defaulting to `"visual"`, currently
  unused by the editor).

### The render strategy — decided

Templatical stores templates as portable JSON and renders to **MJML → HTML**;
Lunogram's send path renders **React Email JSX** through the Deno renderer.
The chosen approach is a **second render path inside `renderer/`**, not a
JSON→JSX adapter — writing an adapter would mean maintaining a parallel
reimplementation of Templatical's renderer against a pre-1.0 target, and
inheriting React Email's email-client quirk coverage instead of MJML's.

This is cheap because **`compiled_js` is opaque to Go**. `EmailRenderer.Compile`
(`internal/pubsub/email.go`) sends `{source}`, receives `{compiled_js}`,
SHA-256s it for cache invalidation and stores it; `Render` hands it back with
props. Go never parses it. The bundle is already a JSON envelope —
`renderer/compiler.ts` returns `JSON.stringify({ code, tailwindConfigBindings })`.

So the whole change lives in `renderer/`:

- `compile` — for a Templatical document, return
  `{ kind: "templatical", doc, mjml }`.
- `renderTemplate` — `JSON.parse` the bundle; `kind === "templatical"` →
  Templatical/MJML path, otherwise the existing React Email path.

No Go changes, no wire-schema changes, no migration: existing bundles carry no
`kind` and fall through to the current branch. Preview, test send, real send and
plain-text generation all route through `EmailRenderer`, so one branch covers
all four.

### Feasibility: verified under Deno 2.2.6

Probed against the exact version `renderer/Dockerfile` pins (2026-07-25):

| Step | Result |
| --- | --- |
| `@templatical/types` → `createDefaultTemplateContent()` | works |
| `@templatical/renderer` → `renderToMjml(content)` | works, valid MJML |
| `mjml@5` → MJML→HTML | works, 0 errors — **API is async, must be awaited** |
| `mjml@4` | also works (sync, returns `{html, json, errors}`) |

Notes from the probe:

- `@templatical/renderer` is 36 KB, pure ESM, references **no Node built-ins**,
  and has exactly one runtime dependency (`@templatical/types`). `mjml` is only
  a devDependency there — it renders *to* MJML, so the MJML→HTML step is yours
  to add. `mjml` itself pulls a large dependency tree into the renderer image.
- **Merge tags land on Liquid for free.** `convertMergeTagsToValues()` turns
  `<span data-merge-tag="{{ user.first_name }}">Label</span>` into the literal
  `{{ user.first_name }}`, and that survives MJML→HTML intact — so it feeds
  straight into the existing `internal/render` Liquid engine (`osteele/liquid`),
  matching the `{{ user.id }}` convention already used by WASM action
  `VariableSpec` defaults.
- **Licensing works out.** `@templatical/renderer` and `@templatical/types` are
  MIT, so the server side links only MIT code. Only `@templatical/editor`
  (console-side) is FSL-1.1.
- ⚠️ Social icons default to fetching PNGs from
  `https://cdn.jsdelivr.net/npm/@templatical/renderer@<version>/assets/social`
  (`DEFAULT_SOCIAL_ICONS_BASE_URL`) — confirmed present in rendered output. For
  a self-hosted platform, pass `socialIconsBaseUrl` in `RenderOptions` to serve
  them from Lunogram's own storage; verified to fully replace the CDN URLs.

A **rich document** was then probed — three multi-column sections (`2`, `2-1`,
`3`), five images with links, a table, a divider and social icons, with merge
tags in headings, paragraphs and button URLs. All of it renders, and
MJML→HTML reports **zero errors**:

- Column layouts produce correct proportional widths (`50%/50%`, `66.67%/33.33%`).
- `stackOnMobile: false` correctly emits `<mj-group>`.
- All five images survive to `<img>` tags with `src` and link wrapping intact.
- Merge tags survive the full pipeline in every position tested.
- Output carries responsive `@media` rules and `<!--[if mso]>` Outlook
  conditionals — i.e. the email-client quirk coverage that motivated this
  approach in the first place.

Gotchas found while probing, worth knowing when writing fixtures or tests:

- `createDefaultTemplateContent()` returns **zero blocks** — an empty template.
- `createSocialIconsBlock()` defaults to `icons: []` and renders **nothing**
  until populated.
- MJML head defaults emit a bare `<mj-image fluid-on-mobile="true" />` inside
  `<mj-attributes>`; count `<mj-image src=` when asserting on real images.
- Custom blocks remain untested: `renderCustomBlock` and
  `getCustomBlockStylesheet` in `RenderOptions` are consumer-supplied and will
  need wiring if the editor's custom/API-backed blocks are enabled.

### Practical notes

- Packages: `@templatical/editor`, `@templatical/core`, `@templatical/renderer`,
  `@templatical/types`, plus optional `@templatical/media-library`,
  `@templatical/quality` and format importers. Current version 0.19.0.
- The editor mounts imperatively — `init({ container, onChange })` returning an
  editor handle with `toMjml()` — so a React wrapper needs a `ref` container, an
  async mount in `useEffect`, and teardown on unmount.
- It is Vue + TipTap internally. The console already bundles TipTap 3.20.1 for
  other editors; watch for duplicate/conflicting versions and add `dedupe`
  entries in `console/vite.config.ts` if needed (React is already deduped there
  for exactly this reason).
- **Licensing matters here.** Editor packages are Functional Source License 1.1
  (converting to MIT after two years); renderers and importers are MIT.
  Lunogram itself is a mix of Apache-2.0, AGPL-3.0 and BSL-1.1. Check
  compatibility for the specific packages pulled in before committing to them.
- Lunogram already has a media manager (`console/src/components/media-manager/`)
  and an uploads/storage backend — prefer wiring Templatical's media hooks to
  those rather than adding a parallel asset store.
