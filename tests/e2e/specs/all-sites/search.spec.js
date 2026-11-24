const { test, expect } = require("../../support/test");
const { seededItems } = require("../../support/content");

// The search results page of every theme with a site search. The seed gives
// each of those sites twelve "Search result <n>" pages that mention the
// kittiwake (seed/content/shared/search-result.html), and nothing else on the
// sites uses the word except the hale and justice fixtures in extraResults below.
// WordPress shows ten results a page, so a search for it has two pages.
// Relevanssi answers the searches; seed.sh builds its index.
const TERM = "kittiwake";
const NO_MATCH = "zzqxjvw";
const PER_PAGE = 10;
// The seed gives each site a draft page that alone uses this word
// (seed/content/shared/draft-page.html). A draft is not published, so a
// search for the word finds nothing.
const DRAFT_TERM = "guillemot";

test.skip(({ site }) => site.theme === "ppo", "The ppo theme has no search field, so its sites have no search to test");

// Theme bugs these tests have found, by theme, then by what they break. Each
// has its reason, shown in the report, and its symptom: what the page shows
// instead of what the test expects. A test a bug breaks checks the symptom in
// place of the rest of the test, so anything else going wrong on that page
// (a broken selector, an error page) still fails it. Once the theme is fixed
// the symptom is gone and the test fails: remove the entry then.
const KNOWN_ISSUES = {
  justice: {
    nextWithNoResults: {
      reason:
        "MOJ\\Justice\\Search::getPaginationArgs() passes max_num_pages, 0 when nothing matches, to " +
        "get_next_posts_page_link(), which takes 0 as no limit, so a search with no results links to its page 2.",
      symptom: async (page, theme) => {
        await expect(theme.next(page)).toHaveAttribute("href", /\/page\/2\b/);
      },
    },
  },
};

// If a known issue breaks this test on the site's theme, check that the page
// shows its symptom, put its reason in the report and return true, so the
// test stops there. Returns false otherwise.
async function showsKnownIssue(page, site, theme, issue) {
  const known = KNOWN_ISSUES[site.theme]?.[issue];
  if (!known) {
    return false;
  }
  test.info().annotations.push({ type: "known issue", description: known.reason });
  await test.step(
    `known ${site.theme} issue "${issue}" still shows (if the theme is fixed, remove it from KNOWN_ISSUES)`,
    () => known.symptom(page, theme),
  );
  return true;
}

// Where each theme puts the parts of its search page. heading is the page's
// main heading; count is the line with the number of results, where the
// theme has one.
const themes = {
  hale: {
    searchPath: (term) => `?s=${encodeURIComponent(term)}`,
    heading: (page) => page.getByRole("heading", { level: 1 }),
    headingText: ["Search results", `for ${TERM}`],
    form: (page) => page.locator(".hale-search-header form[role=search]"),
    results: (page) => page.locator(".hale-search-result__item"),
    resultLink: "h3 a",
    count: (page) => page.locator(".index > h2"),
    noResults: (page) => page.locator(".no-results"),
    noResultsText: ["Nothing found", "Sorry, but nothing matched your search terms."],
    next: (page) => page.locator(".moj-pagination").getByRole("link", { name: "Next" }),
    previous: (page) => page.locator(".moj-pagination").getByRole("link", { name: "Previous" }),
    // seed/content/hale/: an inquiry document, a post of the flexible post
    // type the seed makes with ACF and has Relevanssi index.
    extraResults: [{ title: "Kittiwake evidence", href: /\/inquiry_document\/kittiwake-evidence\/$/ }],
  },
  justice: {
    // The theme's own address; ?s= redirects there.
    searchPath: (term) => `search/${encodeURIComponent(term)}`,
    // Each result's title is an h1 too.
    heading: (page) => page.locator(".hero__title"),
    headingText: ["Search Results"],
    form: (page) => page.locator("form#search-bar-main"),
    results: (page) => page.locator(".search-result-list__element"),
    resultLink: ".search-result-card__title a",
    count: (page) => page.locator(".search-bar-block__results-text"),
    noResults: (page) => page.locator(".search-result-list__no-results"),
    noResultsText: ["No results", `Your search for ${NO_MATCH} did not return any results.`],
    // The pager always shows Previous and Next; the one that goes nowhere has
    // no href.
    next: (page) => page.locator("a.pagination__link--next[href]"),
    previous: (page) => page.locator("a.pagination__link--previous[href]"),
    // seed/content/justice/: a page that says kittiwake over and over, and a
    // document with it in its title (justice indexes documents).
    extraResults: [
      { title: "Kittiwake guidance", href: /\/about\/kittiwake-guidance\/$/ },
      // A permalink, so with the trailing slash; WPDR serves it either way.
      { title: "Kittiwake survey report", href: /\/documents\/kittiwake-survey-report\.pdf\/?$/ },
    ],
  },
  govwind: {
    searchPath: (term) => `?s=${encodeURIComponent(term)}`,
    heading: (page) => page.getByRole("heading", { level: 1 }),
    headingText: ["Search results"],
    // The header has a search form too.
    form: (page) => page.getByRole("main").locator("form.wp-block-search"),
    results: (page) => page.locator(".wp-block-post-template > li"),
    resultLink: ".wp-block-post-title a",
    count: (page) => page.getByRole("main").locator(".wp-block-query-total").first(),
    noResults: (page) => page.getByRole("main"),
    noResultsText: ["Nothing found", "Sorry, but nothing matched your search terms."],
    next: (page) => page.locator("a.wp-block-query-pagination-next"),
    previous: (page) => page.locator("a.wp-block-query-pagination-previous"),
  },
};

function themeFor(site) {
  const theme = themes[site.theme];
  if (!theme) {
    throw new Error(`search.spec.js does not know where the ${site.theme} theme puts its search results`);
  }
  return theme;
}

// What a search for TERM should find on the site: its title and address.
function expectedResults(site) {
  const pages = seededItems(site)
    .filter((item) => item.file.endsWith("/search-result.html"))
    .map(({ slug, title }) => ({ title, href: new RegExp(`/${slug}/$`) }));
  return [...pages, ...(themes[site.theme].extraResults ?? [])];
}

// The results on the page, each matched to the expected result it links to.
// Fails on a result that is not one of them.
async function shownResults(page, theme, expected) {
  const links = await theme
    .results(page)
    .locator(theme.resultLink)
    .evaluateAll((as) => as.map((a) => ({ text: a.textContent.trim(), href: a.getAttribute("href") })));

  return links.map(({ text, href }) => {
    const match = expected.find(({ title, href: pattern }) => text.includes(title) && pattern.test(href));
    expect(match, `result "${text}" (${href}) is one of the seeded kittiwake pages`).toBeDefined();
    return match.title;
  });
}

test("search page renders with the search term in its form", async ({ page, site }) => {
  const theme = themeFor(site);
  const response = await page.goto(theme.searchPath(TERM));

  expect(response?.status()).toBe(200);
  for (const text of theme.headingText) {
    await expect(theme.heading(page).filter({ hasText: text }).first()).toBeVisible();
  }
  await expect(theme.form(page).locator('input[name="s"]')).toHaveValue(TERM);
  await expect(
    page.locator(`link[href*="/themes/${site.theme}/"], script[src*="/themes/${site.theme}/"]`).first(),
  ).toBeAttached();
});

test("searching from the form shows results for the new term", async ({ page, site }) => {
  const theme = themeFor(site);
  await page.goto(theme.searchPath(NO_MATCH));

  const input = theme.form(page).locator('input[name="s"]');
  await input.fill(TERM);
  await input.press("Enter");

  await expect(page).toHaveURL(new RegExp(TERM));
  await expect(theme.form(page).locator('input[name="s"]')).toHaveValue(TERM);
  await expect(theme.results(page).first()).toBeVisible();
});

test("results link to the matching pages and show the term", async ({ page, site }) => {
  const theme = themeFor(site);
  const expected = expectedResults(site);
  const response = await page.goto(theme.searchPath(TERM));

  expect(response?.status()).toBe(200);
  const results = theme.results(page);
  await expect(results).toHaveCount(Math.min(expected.length, PER_PAGE));
  if (theme.count) {
    await expect(theme.count(page)).toContainText(new RegExp(`\\b${expected.length} results\\b`));
  }

  const shown = await shownResults(page, theme, expected);
  expect(new Set(shown).size, "no result is listed twice").toBe(shown.length);
  for (const result of await results.all()) {
    await expect(result).toContainText(new RegExp(TERM, "i"));
  }
});

test("a search with no matches says so", async ({ page, site }) => {
  const theme = themeFor(site);
  const response = await page.goto(theme.searchPath(NO_MATCH));

  expect(response?.status()).toBe(200);
  for (const text of theme.noResultsText) {
    await expect(theme.noResults(page)).toContainText(text);
  }
  await expect(theme.results(page)).toHaveCount(0);
});

test("draft pages are not in the results", async ({ page, site }) => {
  const theme = themeFor(site);
  const drafts = seededItems(site).filter(({ status }) => status === "draft");
  expect(drafts.length, "the seed has a draft page").toBeGreaterThan(0);
  const response = await page.goto(theme.searchPath(DRAFT_TERM));

  expect(response?.status()).toBe(200);
  await expect(theme.form(page).locator('input[name="s"]')).toHaveValue(DRAFT_TERM);
  await expect(theme.results(page)).toHaveCount(0);
  for (const { id, slug, title } of drafts) {
    // A draft has no pretty permalink yet: WordPress links it by ID.
    await expect(
      page.locator(`a[href*="/${slug}/"], a[href*="page_id=${id}"], a[href*="?p=${id}"]`),
      `no link to the draft "${title}"`,
    ).toHaveCount(0);
    await expect(page.locator("body"), `the draft "${title}" is not listed`).not.toContainText(title);
  }
});

// Its own test, so a known issue here leaves the rest of the no-results page
// checked.
test("a search with no matches has no next page", async ({ page, site }) => {
  const theme = themeFor(site);
  await page.goto(theme.searchPath(NO_MATCH));

  await expect(theme.results(page)).toHaveCount(0);
  if (await showsKnownIssue(page, site, theme, "nextWithNoResults")) {
    return;
  }
  await expect(theme.next(page)).toHaveCount(0);
});

test("pagination pages through every result once", async ({ page, site }) => {
  const theme = themeFor(site);
  const expected = expectedResults(site);
  const response = await page.goto(theme.searchPath(TERM));

  expect(response?.status()).toBe(200);
  // Counted before each read: shownResults() does not wait for the page.
  await expect(theme.results(page)).toHaveCount(PER_PAGE);
  await expect(theme.previous(page)).toHaveCount(0);
  const first = await shownResults(page, theme, expected);

  await theme.next(page).click();
  await expect(page).toHaveURL(/\/page\/2\b/);
  await expect(theme.form(page).locator('input[name="s"]')).toHaveValue(TERM);
  // Two pages hold everything, so the second is the last.
  await expect(theme.results(page)).toHaveCount(expected.length - PER_PAGE);
  const second = await shownResults(page, theme, expected);
  expect([...first, ...second].sort()).toEqual(expected.map(({ title }) => title).sort());
  await expect(theme.next(page)).toHaveCount(0);

  await theme.previous(page).click();
  await expect(page).not.toHaveURL(/\/page\/2\b/);
  await expect(theme.results(page)).toHaveCount(PER_PAGE);
  expect((await shownResults(page, theme, expected)).sort()).toEqual([...first].sort());
});
