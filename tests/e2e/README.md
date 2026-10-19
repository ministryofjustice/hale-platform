# End-to-end tests

Playwright tests that run against a throwaway copy of the multisite: the same
images, plugins and themes as hale.docker, four sites, and dummy content only.
One command builds the stack, seeds it, runs the tests and removes it again,
pass or fail.

```
make test-e2e
```

Playwright, Chromium and the npm packages run only inside a container
(`hale-test/playwright`). Nothing from npm is installed or run on the host.

The test stack runs alongside hale.docker and never touches it. They share
code, never state.

| | hale.docker | test stack |
| --- | --- | --- |
| Compose project | `hale-platform` | `hale-test` (`docker-compose.test.yml`) |
| Address | `https://hale.docker` (443) | `https://localhost:8443` (loopback only) |
| Database | `database` volume | in memory (`tmpfs`), gone on teardown |
| Code | bind-mounted `./wordpress`, `./dev` | baked into `hale-test/*` images |
| Firewall, page cache, Redis | on/off by flag | off, no Redis |

## Requirements

- Docker, bash, git and openssl. Not Node.js or npm.
- `composer install` has been run, so `./wordpress` and `./vendor` exist. The
  stack is built from them, so the plugin and theme versions are whatever
  `composer.lock` gives.
- `./wordpress/wp-content` holds real folders, not dev package links. The
  build stops if it finds symlinks; `composer install` restores the folders.

## Running tests

| Command | Purpose |
| --- | --- |
| `make test-e2e` | Start, seed, test, remove. |
| `make test-e2e-report` | Serve the last HTML report, with screenshots, videos and traces, at http://localhost:9323. |
| `make test-e2e-build` | Rebuild the `hale-test/*` images, including `hale-test/playwright`. |
| `make test-e2e-down` | Remove a stack left running. |

Pass Playwright's usual arguments in `ARGS` to run one site or one file:

```
make test-e2e ARGS=--project=justice
make test-e2e ARGS=specs/hale/editor-block.spec.js
```

The browser has no display in the container, so there is no headed or
Inspector mode. UI mode (`make test-e2e-ui`, below) shows the browser, each
step and its DOM snapshot, and lets you pick locators.

Each of those starts, seeds and removes a stack, about 45 seconds before the
first test. While writing a test, keep one stack running and rerun against it:

```
make test-e2e-up                                          # start and seed, leave it running
make test-e2e-run FILE=specs/hale/editor-block.spec.js    # run one file on it, as often as you like
make test-e2e-run FILE=specs/all-sites/                   # or a folder; no FILE runs everything
make test-e2e-ui                                          # or UI mode: the eye icon reruns a test on save
make test-e2e-down                                        # remove it when you are done
```

| Command | Purpose |
| --- | --- |
| `make test-e2e-up` | Start and seed a stack and leave it running. Replaces any stack already running. |
| `make test-e2e-run FILE=...` | Run specs on the running stack, skipping the setup. |
| `make test-e2e-ui` | Playwright UI mode on the running stack, at http://localhost:9323. Ctrl-C stops it; the stack keeps running. |
| `make test-e2e-urls` | List every address the stack serves (sites, seeded pages, login, admin, report) and whether it is running. |

A running stack picks up changes to spec files straight away. After changing
the seed or content fixtures, run `make test-e2e-up` again for a fresh stack.
After changing theme or plugin code, run `E2E_BUILD=1 make test-e2e-up` to
rebuild the images too. Content your tests create stays on the stack between
runs.

### Environment variables

| Variable | Effect |
| --- | --- |
| `KEEP_STACK=1` | Leave the stack running after the run, to look at it in a browser or with `docker compose -f docker-compose.test.yml logs`. Also keeps it when the setup fails. |
| `REUSE_STACK=1` | Use a stack that is still running instead of starting a new one, and leave it running. Use it with `KEEP_STACK=1` for a fast edit-and-rerun loop. Tests that add content add more on each run. |
| `E2E_BUILD=1` | Rebuild the images before the run. Without it they are rebuilt only when missing or when `composer.lock` or `tests/e2e/package-lock.json` has changed since the last build, so set it after a Dockerfile or theme change. |
| `HALE_TEST_PORT` | Host port, default `8443`. |
| `HALE_TEST_PROJECT` | Compose project name, default `hale-test`. Set a different one with a different port to run two stacks at once. |
| `E2E_PASSWORD` | Password for every test user, default `hale-e2e-test-only`. |
| `E2E_UI_PORT` | Host port for UI mode and the report, default `9323`. |

## How a run works

`stack/stack.sh` runs every step on the host except the tests themselves,
which run in the `playwright` service of `docker-compose.test.yml`.

1. **Images.** `tests/e2e/stack/build.sh` builds `hale-test/wordpress-base`
   from `wordpress.local.dockerfile`, then `hale-test/wordpress` on top of it
   with the theme CSS and JavaScript compiled (`stack/wordpress.dockerfile`,
   the same `npm run production` loop as the deploy workflow). It also builds
   `hale-test/nginx`, `hale-test/wptools` and `hale-test/playwright`
   (`docker/playwright.dockerfile`). Separate tags, so hale.docker's images
   are never replaced.
2. **Start.** `stack.sh` removes any earlier stack, generates a self-signed
   certificate for `localhost` in `tests/e2e/.stack/`, and runs
   `docker compose up --wait`. `config.sh` installs the network when the
   wordpress container starts.
3. **Seed.** A one-shot `seed` container runs `seed/seed.sh`, then exits.
4. **Playwright container.** `docker compose run --rm playwright test ...`.
   Its entrypoint (`docker/entrypoint.sh`) starts `support/forward.js`, which
   listens on `localhost:8443` inside the container and passes connections to
   nginx, so the browser uses the same address as the sites' stored domain.
5. **Ready check.** The global setup (`global-setup.js`) waits for every site
   to return 200.
6. **Log in once.** The `setup` project (`auth.setup.js`) logs in as each
   role and saves the session to `tests/e2e/.auth/`.
7. **Tests.** One Playwright project per site, each with its own `baseURL`,
   plus a `network` project for the network admin.
8. **Teardown.** `stack.sh` runs `docker compose down -v --remove-orphans`:
   containers, networks and volumes go.

`stack.sh` prints how long each step took.

## Isolation

The `playwright` container is the only place npm code runs, and it gets as
little as the tests need:

| | |
| --- | --- |
| Packages | `@playwright/test` and `@axe-core/playwright`, installed by `npm ci --ignore-scripts` from `package-lock.json` at image build time. No install scripts run. |
| Network | The `e2e` network only, which is `internal`: nginx is the one thing it can reach. No internet, no host. |
| Files | `tests/e2e` read-only. Writable: `.auth/` and `output/` only. |
| Docker | No socket. Starting, seeding and removing the stack happens on the host. |
| Process | Non-root, all capabilities dropped, `no-new-privileges`, read-only root filesystem. |

`make test-e2e-ui` and `make test-e2e-report` use the `playwright-ui`
service instead: the same container plus a port on `127.0.0.1`, which needs
the default network, so those two can reach the internet.

To change a package, edit `package.json`, then update the lockfile and
rebuild the image. `make test-e2e-lock` runs npm in the Playwright image with
`--package-lock-only --ignore-scripts`, so it downloads metadata only and runs
no package code:

```
make test-e2e-lock
make test-e2e-build
```

The `hale-test/playwright` base image carries the browsers, so its tag in
`docker/playwright.dockerfile` must match the `@playwright/test` version.
Dependabot raises both.

## Seeded data

Everything the tests see is created by the seed on every run. No database is
exported or copied from anywhere.

`seed/seed.sh` uses WP-CLI for the network:

- Network-activates the plugins listed in the script. Plugins that take over
  login or call third parties are left off, each with the reason next to it.
  `composer.json` is the list of what is installed.
- Moves the login page to `/e2e-test-login/` with wps-hide-login, as the
  deployed environments move theirs. The test stack uses its own path.
- Blocks outbound HTTP from WordPress (`WP_HTTP_BLOCK_EXTERNAL`).
- Creates the sites in `seed/sites.json`, activates each one's theme, and gives
  the test users their role on every site.

`seed/import-content.php` then loads each site's pages and posts from
`seed/content/<site>/content.json`. Page content is block markup in `.html`
files, so a fixture can use any block, and the diff in a pull request shows
exactly what changed. Pages and posts have fixed IDs and slugs, so tests can go
straight to them. A page can sit below another (`parent`), use a page template
(`template`), set post meta (`meta`) and have its own `date`. The comment at
the top of `seed/import-content.php` lists every `content.json` key.

- `themeMods` sets theme mods, such as the Hale Customizer colours.
- For block themes, `styleVariation` applies a theme style variation,
  `navigations` creates navigation menus, and `templateParts` saves template
  parts over the theme's own, as the Site Editor would.
- `logo` sets the site logo.

Images are generated by the seed, not committed. `content.json` lists them
under `images` with a size. Block markup refers to what the seed creates with
`{{image:<name>.url}}`, `{{image:<name>.id}}`, `{{page:<slug>.url}}`,
`{{page:<slug>.id}}`, `{{document:<name>.url}}`, `{{document:<name>.id}}` and,
in template parts, `{{navigation:<name>.id}}`. The
seed stops on a reference it does not know. Links to pages the seed does not
create go to `example.test`.

Documents are generated too. `documents` in `content.json` lists WP Document
Revisions documents by name, each with a `type` (`pdf`, `docx` or `xlsx`) and
optionally a `title`, `slug` and `lines` of text. `seed/documents.php` writes
a small, valid file of that type with the title and text in it, and the same
bytes every run, then creates the document post and its attachment as an
upload in wp-admin would. WPDR serves it at `/documents/<slug>.<type>`.

A site in `sites.json` with a `blogId` is created with that ID. govwind has
`61`, because the govwind theme applies its IPA colours to `.website-61`.

| Site | Path | Theme |
| --- | --- | --- |
| hale | `/` | hale |
| justice | `/justice/` | justice |
| ppo | `/ppo/` | ppo |
| govwind | `/govwind/` | govwind |

Each site has `home` (front page) and `about`. Sites with `customBlocks` set in
`sites.json` also have `blocks`, a page of website-builder-blocks blocks, and
hale, ppo and govwind have news posts. The justice theme allows only its own
block list and does not allow posts (saving one ends the request), so it has
neither, and tests of those blocks skip it.

The hale site follows websitebuilder.service.justice.gov.uk: its colours, its
homepage, and a menu of three sections (`about-website-builder`,
`designing-your-site`, `user-guides`), each with one page below it. The pages
use the same blocks as the live ones, with shorter text and generated images.

The govwind site follows the IPA site (websitebuilder.service.justice.gov.uk/ipa-fse/):
the IPA style variation, its header (logo, menu, search) and footer, and a
menu of About us, Get support (with one page below it), News, Briefings and
Contact us. News lists the site's three posts with the website-builder-blocks
filterable listing. The text keeps the structure of the live pages but leaves
out details of real incidents and people.

The justice site follows www.justice.gov.uk: the home page (Home template,
"Most popular" panel), and Procedure rules (`courts/procedure-rules`) with
Civil below it. The theme fixes its header, footer and "Most popular" links in
code, and builds the left menu from the pages below `courts/procedure-rules`,
so the seed creates that page tree and sets the side panels in page meta.
Civil links a PDF, a DOCX and an XLSX document under "Practice direction
updates", which the theme shows as file-download links with format and size.

`make test-e2e-urls` lists these pages.

The seed marks PublishPress Revisions' first-run redirect as done on every
site, so the first wp-admin page a test opens is the one it asked for.

| User | Role |
| --- | --- |
| `e2eadmin` | Network admin |
| `e2eeditor` | Editor on every site |
| `e2eauthor` | Author on every site |
| `e2econtributor` | Contributor on every site |

To add a site, add it to `seed/sites.json` and add
`seed/content/<site>/content.json`. It gets its own Playwright project
automatically.

## Writing tests

```
tests/
  Makefile                 the make test-e2e* commands, included by the root Makefile
  e2e/
    specs/all-sites/       run once for every site
    specs/<site>/          run for that site only
    specs/network/         network admin, run against the main site
    seed/                  seed script, sites and content fixtures
    stack/                 image build and stack.sh, which runs the stack
    docker/                the Playwright image and its entrypoint
    support/               stack settings, the shared `test` fixture, the forwarder
    playwright.config.js   Playwright configuration
    package.json           Playwright and axe-core, installed in the image only
    output/                run output (not committed):
      playwright-report/   last HTML report
      test-results/        screenshots, videos and traces of failures
```

`docker-compose.test.yml` stays in the repo root.

- Import `test` and `expect` from `support/test.js`. Its `site` fixture is
  the `sites.json` entry for the project running the test.
- Use relative paths: `page.goto("about/")`. `baseURL` is the site's URL, and
  a leading `/` would go to the main site instead.
- Start logged in with `test.use({ storageState: authFile("editor") })`.
- Tests share one stack, so a test that creates content gives it a unique
  title rather than assuming it is the only one.

## CI

`.github/workflows/e2e.yaml` runs `make test-e2e` on GitHub Actions, the same
command and the same Playwright container as locally. It is started by hand
(`workflow_dispatch`). On failure it uploads the HTML report and traces.

## Cleaning up

A run removes its stack even when tests fail. If a run is killed before its
teardown, or `KEEP_STACK=1` was set:

```
make test-e2e-down
```
