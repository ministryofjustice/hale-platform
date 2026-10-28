# End-to-end tests

Playwright tests that run against a throwaway copy of the multisite: the same
images, plugins and themes as hale.docker, four sites, and dummy content only.
One command builds the stack, seeds it, runs the tests and removes it again,
pass or fail.

```
make test-e2e
```

Playwright, Chromium and the npm packages run only inside a container
(`hale-test/playwright`, or `hale-test/browserstack` for BrowserStack runs).
Nothing from npm is installed or run on the host.

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

- Docker with Compose v2 and BuildKit (Docker Desktop has both), bash, git,
  openssl, and PHP and Composer, which `make build` already needs. Not
  Node.js or npm. The scripts run on the bash 3.2 and LibreSSL that macOS
  ships, and on Intel and Apple silicon Macs.
- The repo checked out under your home folder, or another folder Docker
  Desktop shares (Settings, Resources, File sharing): the stack mounts
  `tests/e2e` into its containers.
- `composer install` has been run, so `./wordpress` and `./vendor` exist. The
  stack is built from them, so the plugin and theme versions are whatever
  `composer.lock` gives.
- Dev package links (`make symlink`) can stay. `make test-e2e` builds the
  clones they point to; `make test-e2e-release` needs the composer versions,
  so when it finds links it offers to swap them for those (`composer install`)
  and runs `make symlink` once the images are built. hale.docker serves the
  composer versions in between. Without a terminal, or in CI, it stops
  instead unless `E2E_RESTORE_LINKS=1` is set. See
  [dev/ clones and composer.lock](#dev-clones-and-composerlock).

## Running tests

| Command | Purpose |
| --- | --- |
| `make test-e2e-cmds` | List these commands and the main options. |
| `make test-e2e` | Start, seed, test, remove, on a stack with your linked `dev/` clones. With BrowserStack credentials it also runs the tests on BrowserStack before removing the stack; without them it prints `No credentials available, skipping BrowserStack tests`. It checks the BrowserStack account first: when BrowserStack rejects the credentials, or the account has no Automate plan, an orange warning at the start says the BrowserStack tests will be skipped, and the run does not fail on that alone. |
| `make test-e2e-release` | The same, with every package at its `composer.lock` version, as CI runs it. See [dev/ clones and composer.lock](#dev-clones-and-composerlock). |
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
After `composer update` or a change in `opt/` or a Dockerfile,
`make test-e2e-up` rebuilds the images itself; after editing theme or plugin
code inside `./wordpress` by hand, run `E2E_BUILD=1 make test-e2e-up`. Content your tests create stays on the stack between
runs.

### Environment variables

| Variable | Effect |
| --- | --- |
| `KEEP_STACK=1` | Leave the stack running after the run, to look at it in a browser or with `docker compose -f docker-compose.test.yml logs`. Also keeps it when the setup fails. |
| `REUSE_STACK=1` | Use a stack that is still running instead of starting a new one, and leave it running. Use it with `KEEP_STACK=1` for a fast edit-and-rerun loop. Tests that add content add more on each run. |
| `E2E_BUILD=1` | Rebuild the images before the run. Without it they are rebuilt only when missing or when their build inputs have changed since the last build: the Dockerfiles, anything in `opt/`, `composer.lock` or `tests/e2e/package-lock.json` (`stack/image-inputs.sh`). Set it after editing a file inside `./wordpress` by hand, which is not checked. |
| `E2E_RESTORE_LINKS=1` | When a build finds dev package links in `./wordpress/wp-content`, swap them for the composer versions and link them again afterwards without asking. |
| `E2E_DEV=0` | Build with every package at its `composer.lock` version, on any command. Every command but `make test-e2e-release` defaults to `E2E_DEV=1`, the linked `dev/` clones. |
| `HALE_TEST_PORT` | Host port, default `8443`. |
| `HALE_TEST_PROJECT` | Compose project name, default `hale-test`. Set a different one with a different port to run two stacks at once. |
| `E2E_VERBOSE=1` | Show all of browserstack-node-sdk's logging in the terminal during a BrowserStack run. By default only Playwright's output, each distinct SDK warning or error once, and the build report link are shown; the full SDK log is always in `tests/e2e/log/usage.log`. |
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
| Packages | `@playwright/test` and `@axe-core/playwright`, installed by `npm ci --ignore-scripts` from `package-lock.json` at image build time (`--omit=dev`, so not `browserstack-node-sdk`). No install scripts run. |
| Network | The `e2e` network only, which is `internal`: nginx is the one thing it can reach. No internet, no host. |
| Files | `tests/e2e` read-only. Writable: `.auth/` and `output/` only. |
| Docker | No socket. Starting, seeding and removing the stack happens on the host. |
| Process | Non-root, all capabilities dropped, `no-new-privileges`, read-only root filesystem. |

`make test-e2e-ui` and `make test-e2e-report` use the `playwright-ui`
service instead: the same container plus a port on `127.0.0.1`, which needs
the default network, so those two can reach the internet.

`make test-e2e-browserstack` uses the `browserstack` service: the same
limits, but a separate image that adds `browserstack-node-sdk`, the default
network so it can reach BrowserStack, and a writable `log/` for the SDK's
logs. The SDK is a `devDependency` in `package.json`, so the `playwright`
image is built with `npm ci --omit=dev` and never holds it.

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
    specs/auth0/           login through the mock Auth0 tenant
    specs/auth0-requests/  what the Auth0 plugin sent the tenant, against a baseline
    auth0-mock/            the mock Auth0 tenant and its request baselines
    seed/                  seed script, sites and content fixtures
    stack/                 image build and stack.sh, which runs the stack
    docker/                the Playwright image and its entrypoint
    support/               stack settings, the shared `test` fixture, the forwarder
    playwright.config.js   Playwright configuration
    playwright.browserstack-skipped.config.js
                           lists the BrowserStack tests as skipped, for the report
    browserstack.yml       BrowserStack platforms
    package.json           Playwright, axe-core and browserstack-node-sdk, installed in the images only
    output/                run output (not committed):
      playwright-report/   last HTML report, local and BrowserStack tests together
      test-results/        screenshots, videos and traces of failures
      blob/                the local run's blob report, merged into the HTML report
      browserstack/        the BrowserStack run's own report, results and blob
    log/                   browserstack-node-sdk logs (not committed)
```

`docker-compose.test.yml` stays in the repo root.

- Name a spec `<name>.mobile.spec.js` to run it on a phone: Playwright runs
  those in the `<site>-mobile-chrome` projects (Pixel 5 emulation) and leaves
  them out of the desktop ones. BrowserStack's `mobile` platform picks the
  same files.
- Import `test` and `expect` from `support/test.js`. Its `site` fixture is
  the `sites.json` entry for the project running the test.
- Use relative paths: `page.goto("about/")`. `baseURL` is the site's URL, and
  a leading `/` would go to the main site instead.
- Start logged in with `test.use({ storageState: authFile("editor") })`.
- Tests share one stack, so a test that creates content gives it a unique
  title rather than assuming it is the only one.

## Auth0 login tests

The deployed sites log in through Auth0 (the `auth0` plugin, Login by Auth0).
The test stack runs a mock Auth0 tenant, so the login can be tested end to end
without the real one, and before and after a plugin upgrade.

- **The tenant.** `auth0-mock/server.js`, the `auth0-mock` service in
  `docker-compose.test.yml`, at `https://auth0.e2e.test/`. It implements what
  the plugin calls: `/authorize` (a one-field login page), `/oauth/token`,
  the JWKS, `/userinfo`, the Management API's `GET /api/v2/users/{id}` and
  logout. ID tokens are signed and checked as real ones are. Like the real
  tenant, it refuses callback and logout addresses that are not in its
  Allowed Callback URLs and Allowed Logout URLs, which are set in
  `docker-compose.test.yml`. It runs on the plain `node` Alpine image and has
  no npm packages.
- **The sites.** The seed creates `/auth0/`, `/auth0-two/`,
  `/auth0-private/` (wp-force-login) and `/auth0-network/` and activates the
  plugin on those alone, with its default settings. On `/auth0-network/` it is
  active without its activation hook having run there, as on every site but
  one when the plugin is network-activated. `/auth0-two/` has hale-components'
  switch user on, and `e2esiteadmin` is the administrator of `/auth0/` only. Every other site keeps the WordPress login form,
  so the rest of the tests are unaffected. `x-auth0-tenant` in
  `docker-compose.test.yml` gives WordPress the tenant's domain and client
  credentials, as the deployed environments' secrets do.
- **Who signs in.** The tenant's session is a cookie on its own domain, so
  tests running in parallel never share one. `support/auth0.js` signs in
  through the login page (`signInAtAuth0`) or sets the session directly
  (`setAuth0Session`), which can also make the tenant return an error. Its
  `identities` are the seeded users' email addresses, plus one with no
  WordPress account and one whose address is not verified.
- **Certificates.** `stack/stack.sh` generates the tenant's TLS certificate
  and ID token signing key in `.stack/certs/`. WordPress checks the TLS
  certificate against its own CA bundle, so the seed copies
  `seed/mu-plugins/e2e-auth0-mock.php` into the test site, which makes it
  trust the mock's certificate for requests to the tenant.

`specs/auth0/` tests what a person sees: signing in, returning to the page
they asked for, moving between two Auth0 sites, logging out of both WordPress
and Auth0 (and not without WordPress's nonce), the errors for someone Auth0
signs in but WordPress must not, the WordPress session the login leaves,
signing in on a site the plugin was network-activated onto, switching user,
and that a site administrator cannot read or change the tenant settings.

`specs/auth0-requests/` runs after them and compares every kind of request
the plugin sent the tenant with the baseline for the plugin's major version,
`auth0-mock/request-shapes.v<major>.json`, with the values that change on
every request (state, nonce, code) left out. The sites send the version they
run in an `X-E2E-Auth0-Plugin` header (from the seed's test-only mu-plugin).
Each run writes its shapes to `output/auth0-request-shapes.v<major>.json`.
When the plugin changes what it sends, review the difference, then copy the
new file over that version's baseline.

    make test-e2e-run FILE=specs/auth0/

runs the login tests alone, and `ARGS=--project=auth0-requests` adds the
request check. Both need the local stack: a BrowserStack browser cannot reach
the tenant.

## dev/ clones and composer.lock

`make test-e2e`, and every other command that builds or starts a stack, tests
what your local site serves: each `dev/` clone that `make symlink` linked, in
place of its `composer.lock` version. Packages that are not linked are their
`composer.lock` versions, so with no clones linked it tests the same thing as
`make test-e2e-release`. `E2E_DEV=0` turns the clones off for any command.

A clone goes in as `git status` sees it: the checked-out branch, uncommitted
changes and new files, but nothing `.gitignore` covers (`node_modules`, built
assets, local leftovers). That is what the package holds once the change is
committed. `./wordpress` is not changed. The build lists the clones it uses,
and the run ends with:

```
[e2e] Ran dev/ clones, not the composer.lock versions.
```

The build warns about a clone that does not include the commit
`composer.lock` pins for it, which would test older code than
`make test-e2e-release`, and about an untracked `package-lock.json` in a
theme clone, which the theme build would use. The warning comes before
anything is built, gives the commands that fix each clone, and asks whether to
go on with the clones as they are. Without a terminal it goes on.

`make test-e2e-release` tests every package at its `composer.lock` version,
as it would be deployed, and is what CI runs. A change in a package reaches
it once it is pushed and `composer.lock` points at it
(`composer update ministryofjustice/<package>`; a branch works, as
`dev-<branch>` in `composer.json`). A pass on `make test-e2e` shows the
change works; a pass on `make test-e2e-release` shows it works from
`composer.lock`.

Switching between the two rebuilds `hale-test/wordpress`. With clones
linked, every build runs, since a clone can change without anything the
stale check hashes changing; Docker's cache keeps an unchanged rebuild short.
`make test-e2e-run` and `REUSE_STACK=1` use a running stack as it was built,
and the run ends by naming the clones it holds.

## BrowserStack

The same specs run on real browsers and devices on BrowserStack, against the
local test stack. BrowserStack Local opens a tunnel from inside the
`browserstack` container, so the remote browsers reach the stack at
`https://localhost:8443/` through the same forwarder as the local tests.

Set the credentials in the environment or in `.env` at the repo root (ignored
by git), which compose reads:

```
BROWSERSTACK_USERNAME=your_username
BROWSERSTACK_ACCESS_KEY=your_access_key
```

```
make test-e2e-browserstack
make test-e2e-browserstack ARGS=--project=mobile
```

It starts, seeds and removes a stack as `make test-e2e` does, and takes the
same `ARGS`, `KEEP_STACK` and `REUSE_STACK`. `make test-e2e` runs it too,
after the local tests and on the same stack, whenever the credentials are
set; `make test-e2e-run` never does.

On BrowserStack the projects are the platforms in `browserstack.yml`,
`desktop` and `mobile`, in place of one project per site. Each spec in
`specs/<site>/` runs against its own site and the rest (`all-sites/`,
`network/`) against the main site, so `all-sites/` covers one site there, not
every one. `make test-e2e` passes `ARGS` to the BrowserStack run without
`--project`, as the local project names do not exist there.
`make test-e2e-browserstack` logs the test users in on its new stack before
the tests, as the local run's `setup` project does.

At the start of the run, before anything is built,
`support/browserstack-account.js` checks the account: BrowserStack's
Automate plan API for the credentials, then one BrowserStack browser session,
opened and closed at once, because an expired plan still looks active in the
plan API and only refuses sessions. That session shows in Automate as a
`Hale account check` build. When BrowserStack rejects the credentials, cannot
be reached, or will not start a browser (an expired plan), an
orange `[e2e] BrowserStack account check failed: ...` warning gives the
reason. `make test-e2e` then says the BrowserStack tests will be skipped, runs
the local tests, and repeats the warning where the BrowserStack tests would
have run; the skip is not a failure. `make test-e2e-browserstack` stops with
an error before it starts a stack. `NO_COLOR` turns the colour off.

A BrowserStack run writes its results to `output/browserstack/`, so the
local run's stay in `output/`. Both runs also write a blob report, and once
the BrowserStack tests have run, `stack.sh` merges the blobs with Playwright's
`merge-reports` into `output/playwright-report/`, so `make test-e2e-report`
shows the local tests and the BrowserStack ones (projects `desktop` and
`mobile`) on one page. When the BrowserStack tests are skipped, an offline run
of `playwright.browserstack-skipped.config.js` lists each of them as skipped,
with the reason, and that goes into the same report. The report leaves
skipped tests out of its default list: open the Skipped tab, or the
`#?q=s:skipped` link the run prints at the end. The first run builds
`hale-test/browserstack`. Platforms are in `browserstack.yml`: Chrome on
macOS for the desktop specs, and Chrome on a Samsung Galaxy for the
`*.mobile.spec.js` specs. Results and recordings are in the BrowserStack
Automate dashboard; the SDK's own logs are in `tests/e2e/log/`, which only
you can read: the SDK's helper writes the access key into its debug log
there, unredacted. Do not attach that folder to an issue or share it. The
terminal shows Playwright's output and the SDK's warnings and errors, each
once; `E2E_VERBOSE=1` shows the SDK's full logging there too.
The helper binary the SDK downloads is kept in `tests/e2e/.stack/browserstack/`
between runs; delete that folder to make it download a fresh one.

## CI

`.github/workflows/e2e.yaml` runs `make test-e2e-release` on GitHub Actions,
the same command and the same Playwright container as locally. It is started by hand
(`workflow_dispatch`). On failure it uploads the HTML report and traces.

## Cleaning up

A run removes its stack even when tests fail. If a run is killed before its
teardown, or `KEEP_STACK=1` was set:

```
make test-e2e-down
```
