const { test, expect } = require("../../support/test");
const { seededItems } = require("../../support/content");

// The search results page of every theme. The seed gives each site twelve
// "Search result <n>" pages that mention the kittiwake
// (seed/content/shared/search-result.html), and nothing else on the sites
// uses the word except justice's own two fixtures below. WordPress shows ten
// results a page, so a search for it has two pages. Relevanssi answers the
// searches; seed.sh builds its index.
const TERM = "kittiwake";
const NO_MATCH = "zzqxjvw";
const PER_PAGE = 10;

// Theme bugs these tests have found, by theme, then by what they break. A
// test a bug breaks is expected to fail (test.fail), with the reason shown in
// the report, so the run passes. Once the theme is fixed the test passes,
// which Playwright reports as a failure: remove the entry then.
const KNOWN_ISSUES = {
  ppo: {
    results:
      "ppo/search.php lists results from its own WP_Query for Documents and Pages, but Relevanssi " +
      "(relevanssi_prevent_default_request) empties every front-end search query except the main one, " +
      "so the page never lists a result. The Pages query also leaves out paged, so page 2 would repeat page 1.",
  },
  justice: {
    nextWithNoResults:
      "MOJ\\Justice\\Search::getPaginationArgs() passes max_num_pages, 0 when nothing matches, to " +
      "get_next_posts_page_link(), which takes 0 as no limit, so a search with no results links to its page 2.",
  },
};

// Expect this test to fail on the site's theme, if a known issue breaks it.
function expectKnownIssue(site, issue) {
  const description = KNOWN_ISSUES[site.theme]?.[issue];
  test.fail(!!description, description);
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
  ppo: {
    searchPath: (term) => `?s=${encodeURIComponent(term)}`,
    // No h1: the page is two columns, documents and pages, with an h2 each.
    heading: (page) => page.getByRole("main").getByRole("heading", { level: 2 }),
    headingText: ["Documents", "Pages"],
    form: (page) => page.getByRole("main").locator("form.search-form"),
    results: (page) => page.locator(".col-lg-6:not(.tile-container) article"),
    resultLink: "h2.entry-title a",
    count: null,
    noResults: (page) => page.locator(".col-lg-6:not(.tile-container) .alert-warning"),
    noResultsText: ["Sorry, no matching pages were found."],
    next: (page) => page.locator(".post-nav").getByRole("link", { name: "Older posts" }),
    previous: (page) => page.locator(".post-nav").getByRole("link", { name: "Newer posts" }),
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
  expectKnownIssue(site, "results");
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
  expectKnownIssue(site, "results");
  const theme = themeFor(site);
  const expected = expectedResults(site);
  await page.goto(theme.searchPath(TERM));

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
  expectKnownIssue(site, "nextWithNoResults");
  const theme = themeFor(site);
  const response = await page.goto(theme.searchPath(NO_MATCH));

  expect(response?.status()).toBe(200);
  for (const text of theme.noResultsText) {
    await expect(theme.noResults(page)).toContainText(text);
  }
  await expect(theme.results(page)).toHaveCount(0);
  await expect(theme.next(page)).toHaveCount(0);
});

test("pagination pages through every result once", async ({ page, site }) => {
  expectKnownIssue(site, "results");
  const theme = themeFor(site);
  const expected = expectedResults(site);
  await page.goto(theme.searchPath(TERM));

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
