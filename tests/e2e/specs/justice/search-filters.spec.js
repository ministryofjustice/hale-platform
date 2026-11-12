const { test, expect } = require("../../support/test");
const { seededItems } = require("../../support/content");

// The justice search page's sort links and Filters panel (justice/sidebar.php,
// justice/inc/search.php). The other themes' search pages have no filters;
// specs/all-sites/search.spec.js covers what they share.
//
// A search for kittiwake finds the twelve "Search result <n>" pages, a day
// apart from 1 March 2025, plus two fixtures of justice's own (see
// seed/content/justice/): Kittiwake guidance, the oldest page, below About
// this site and in the Courts section, which says kittiwake over and over;
// and the Kittiwake survey report, a PDF document.
const TERM = "kittiwake";
const GUIDANCE = "Kittiwake guidance";
const DOCUMENT = "Kittiwake survey report";
const PER_PAGE = 10;

const resultLinks = (page) => page.locator(".search-result-card__title a");
const resultCount = (page) => page.locator(".search-bar-block__results-text");
const sortLinks = (page) => page.locator(".search-bar-block__filters");
// The panel is in the page twice, for desktop and for mobile.
const filtersPanel = (page) => page.locator(".one-sidebar__sidebar--desktop form.sidebar-block__search-filter");

// The kittiwake pages, from the fixtures, and the document.
function pageCount(site) {
  return seededItems(site).filter(({ file }) => /(search-result|kittiwake-guidance)\.html$/.test(file)).length;
}

test("results are ordered by relevance, or by date with Most recent", async ({ page, site }) => {
  // The pages and the document: more than a page of results.
  const firstPage = Math.min(pageCount(site) + 1, PER_PAGE);
  await page.goto(`search/${TERM}`);

  const sort = sortLinks(page);
  await expect(sort.getByRole("link", { name: "Relevance" })).toHaveAttribute("aria-current", "page");
  // The oldest result, but the one that says kittiwake the most.
  await expect(resultLinks(page).first()).toHaveText(GUIDANCE);

  await sort.getByRole("link", { name: "Most recent" }).click();

  await expect(page).toHaveURL(/[?&]orderby=date\b/);
  await expect(sort.getByRole("link", { name: "Most recent" })).toHaveAttribute("aria-current", "page");
  // Counted first: allTextContents() does not wait, and an empty list would
  // pass the checks below.
  await expect(resultLinks(page)).toHaveCount(firstPage);
  await expect(page.locator(".search-result-card__date")).toHaveCount(firstPage);
  const dates = (await page.locator(".search-result-card__date").allTextContents()).map((date) =>
    Date.parse(date.trim()),
  );
  expect(dates.every(Number.isFinite), "every result shows a date").toBe(true);
  expect(dates, "newest first").toEqual([...dates].sort((a, b) => b - a));
  await expect(resultLinks(page).filter({ hasText: GUIDANCE })).toHaveCount(0);
});

test("web pages only leaves out documents", async ({ page, site, request }) => {
  await page.goto(`search/${TERM}`);

  await expect(resultCount(page)).toHaveText(`${pageCount(site) + 1} results`);
  const documentLink = page.locator(".search-result-list a.file-download", { hasText: DOCUMENT });
  await expect(documentLink).toContainText(new RegExp(`${DOCUMENT} \\(PDF, \\d+ K?B\\)`, "i"));
  // The result links the file itself, which downloads without logging in.
  const download = await request.get(await documentLink.getAttribute("href"));
  expect(download.status()).toBe(200);
  expect(download.headers()["content-type"]).toContain("application/pdf");

  const panel = filtersPanel(page);
  await panel.getByLabel("Limit your search to web pages only").check();
  await panel.getByRole("button", { name: "Apply filters" }).click();

  await expect(page).toHaveURL(new RegExp(`/search/${TERM}/?\\?(.*&)?post_types=page\\b`));
  await expect(resultCount(page)).toHaveText(`${pageCount(site)} results`);
  await expect(page.locator(".search-result-list a.file-download")).toHaveCount(0);
  await expect(filtersPanel(page).getByLabel("Limit your search to web pages only")).toBeChecked();
});

test("a Section filter keeps to the pages in that section", async ({ page }) => {
  await page.goto(`search/${TERM}`);

  const panel = filtersPanel(page);
  await panel.getByRole("group", { name: "Section" }).getByLabel("Courts").check();
  await panel.getByRole("button", { name: "Apply filters" }).click();

  await expect(page).toHaveURL(/[?&]section=courts\b/);
  await expect(resultCount(page)).toHaveText("1 result");
  await expect(resultLinks(page)).toHaveText([GUIDANCE]);
  await expect(filtersPanel(page).getByLabel("Courts")).toBeChecked();
});

test("searching within a page keeps to the pages below it", async ({ page, site }) => {
  const about = seededItems(site).find(({ slug }) => slug === "about");

  await page.goto(`search/${TERM}?parent=${about.id}`);

  // Not by role: each result's title is an h1 too.
  await expect(page.locator(".hero__title")).toHaveText(`Search Results for ${about.title}`);
  await expect(resultLinks(page)).toHaveText([GUIDANCE]);
});
