# End-to-end tests

Playwright tests that run against a throwaway copy of the multisite: the same
images, plugins and themes as hale.docker, four sites, and dummy content only.
One command builds the stack, seeds it, runs the tests and removes it again,
pass or fail.

```
make test-e2e        # or: npm run test:e2e
```

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

- Docker
- Node.js and npm
- `composer install` has been run, so `./wordpress` and `./vendor` exist. The
  stack is built from them, so the plugin and theme versions are whatever
  `composer.lock` gives.
- `./wordpress/wp-content` holds real folders, not dev package links. The
  build stops if it finds symlinks; `composer install` restores the folders.

First time:

```
npm ci
npx playwright install chromium
```

## Running tests

| Command | Purpose |
| --- | --- |
| `make test-e2e` / `npm run test:e2e` | Start, seed, test, remove. The HTML report opens when a test fails. |
| `npm run test:headed` | The same, with the browser visible. |
| `npm run test:ui` | Playwright UI mode. |
| `npm run test:debug` | Step through tests with the Playwright Inspector. |
| `npm run test:report` | Open the last HTML report. |
| `make test-e2e-build` / `npm run test:e2e:build` | Rebuild the `hale-test/*` images. |
| `make test-e2e-down` / `npm run test:e2e:down` | Remove a stack left running. |

Run one site or one file with Playwright's usual arguments:

```
npx playwright test --project=justice
npx playwright test specs/hale/editor-block.spec.js
```

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
| `make test-e2e-ui` | Playwright UI mode on the running stack. |
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
| `E2E_BUILD=1` | Rebuild the images before the run. Without it they are rebuilt only when missing or when `composer.lock` has changed since the last build, so set it after a Dockerfile or theme change. |
| `HALE_TEST_PORT` | Host port, default `8443`. |
| `HALE_TEST_PROJECT` | Compose project name, default `hale-test`. Set a different one with a different port to run two stacks at once. |
| `E2E_PASSWORD` | Password for every test user, default `hale-e2e-test-only`. |

## How a run works

1. **Images.** `tests/e2e/stack/build.sh` builds `hale-test/wordpress-base`
   from `wordpress.local.dockerfile`, then `hale-test/wordpress` on top of it
   with the theme CSS and JavaScript compiled (`stack/wordpress.dockerfile`,
   the same `npm run production` loop as the deploy workflow). It also builds
   `hale-test/nginx` and `hale-test/wptools`. Separate tags, so hale.docker's
   images are never replaced.
2. **Start.** The global setup (`global-setup.js`) removes any earlier stack,
   generates a self-signed certificate for `localhost` in `tests/e2e/.stack/`,
   and runs `docker compose up --wait`. `config.sh` installs the network
   when the wordpress container starts.
3. **Seed.** A one-shot `seed` container runs `seed/seed.sh`, then exits.
4. **Ready check.** Every site has to return 200 before a test starts.
5. **Log in once.** The `setup` project (`auth.setup.js`) logs in as each
   role and saves the session to `tests/e2e/.auth/`.
6. **Tests.** One Playwright project per site, each with its own `baseURL`,
   plus a `network` project for the network admin.
7. **Teardown.** `global-teardown.js` runs
   `docker compose down -v --remove-orphans`: containers, network and volumes
   go.

The global setup prints how long each step took.

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
    stack/                 test image build
    support/               stack settings and the shared `test` fixture
    browserstack.yml       BrowserStack platforms
    playwright-report/     last HTML report (not committed)
    test-results/          screenshots, videos and traces of failures (not committed)
```

`playwright.config.js` and `docker-compose.test.yml` stay in the repo root.

- Import `test` and `expect` from `support/test.js`. Its `site` fixture is
  the `sites.json` entry for the project running the test.
- Use relative paths: `page.goto("about/")`. `baseURL` is the site's URL, and
  a leading `/` would go to the main site instead.
- Start logged in with `test.use({ storageState: authFile("editor") })`.
- Tests share one stack, so a test that creates content gives it a unique
  title rather than assuming it is the only one.

## CI

`.github/workflows/e2e.yaml` runs the same build and command on GitHub
Actions. It is started by hand (`workflow_dispatch`). It installs Chromium
with `npx playwright install --with-deps` rather than using the Playwright
container, because the global setup drives Docker on the runner. On failure
it uploads the HTML report and traces.

## BrowserStack

The same tests can run on BrowserStack against the local test stack, through
BrowserStack Local. Credentials are read from a `.env` file at the project
root (ignored by git):

```
BROWSERSTACK_USERNAME=your_username
BROWSERSTACK_ACCESS_KEY=your_access_key
```

```
npm run test:browserstack
```

Platforms are set in `tests/e2e/browserstack.yml`. Results and recordings are in the
BrowserStack Automate dashboard.

## Cleaning up

A run removes its stack even when tests fail. If a run is killed before its
teardown, or `KEEP_STACK=1` was set:

```
make test-e2e-down
```
