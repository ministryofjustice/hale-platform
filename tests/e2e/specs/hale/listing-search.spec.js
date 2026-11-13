const { test, expect } = require("../../support/test");
const { seededItems } = require("../../support/content");

// Hale's Listing page template (hale/page-listing.php): a flexible post
// type's posts, newest first, ten a page, with a keyword search (Relevanssi),
// a dropdown for each taxonomy in the page's listing_filters, and a Clear
// link. Live sites use it for pages such as an inquiry's documents page.
//
// The seed makes the post type, Inquiry documents, and its taxonomies,
// Document Category and Document Type, as ACF's screens would, and gives it
// eight transcripts, four rulings and one report, which alone mentions the
// puffin and is a Welsh language version. See seed/content/hale/.
const LISTING = "inquiry-documents/";
const NO_MATCH = "zzqxjvw";
const PER_PAGE = 10;

const documents = (site, category) =>
  seededItems(site)
    .filter(({ type, terms }) => type === "inquiry_document" && (!category || terms?.document_category?.includes(category)))
    .sort((a, b) => b.date.localeCompare(a.date));

const form = (page) => page.locator(".listing-search-form form");
const keyword = (page) => form(page).getByLabel("Search inquiry documents");
const category = (page) => form(page).getByLabel("Document Category");
const docType = (page) => form(page).getByLabel("Document Type");
const count = (page) => page.locator(".listing-item-count");
const items = (page) => page.locator(".flexible-post-type-list .list-item");
const titles = (page) => items(page).locator(".list-item-title");
const pager = (page) => page.locator("nav.archive-pagination-nav");
const next = (page) => pager(page).getByRole("link", { name: "Next page" });
const previous = (page) => pager(page).getByRole("link", { name: "Previous page" });
const noResults = (page) => page.locator("#primary h2.govuk-heading-l");

// Submit the form and wait for the page it loads.
async function search(page) {
  await Promise.all([page.waitForEvent("load"), form(page).getByRole("button", { name: "Search" }).click()]);
}

test("listing page renders its search, filters and newest documents", async ({ page, site }) => {
  const all = documents(site);
  const response = await page.goto(LISTING);

  expect(response?.status()).toBe(200);
  await expect(page.getByRole("heading", { level: 1 })).toHaveText("Inquiry documents");
  await expect(keyword(page)).toHaveValue("");
  await expect(form(page).getByRole("heading", { name: "Filters" })).toBeVisible();
  await expect(category(page).locator("option")).toHaveText(["Select option", "Reports", "Rulings", "Transcripts"]);
  await expect(docType(page).locator("option")).toHaveText(["Select option", "Welsh language version"]);
  await expect(form(page).getByRole("link", { name: "Clear" })).toHaveAttribute("href", new RegExp(`/${LISTING}$`));

  await expect(count(page)).toHaveText(`${all.length} inquiry documents`);
  await expect(titles(page)).toHaveText(all.slice(0, PER_PAGE).map(({ title }) => title));
  for (const [i, item] of (await items(page).all()).entries()) {
    await expect(item.locator(".list-item-title a")).toHaveAttribute(
      "href",
      new RegExp(`/inquiry_document/${all[i].slug}/$`),
    );
    await expect(item.locator(".detail-published-date")).toContainText("Published:");
  }
});

test("keyword search finds the one matching document", async ({ page }) => {
  await page.goto(LISTING);

  await keyword(page).fill("puffin");
  await search(page);

  await expect(page).toHaveURL(/[?&]listing_search=puffin\b/);
  await expect(keyword(page)).toHaveValue("puffin");
  await expect(count(page)).toHaveText("1 inquiry document");
  await expect(titles(page)).toHaveText(["Puffin survey report"]);
  await expect(pager(page)).toHaveCount(0);
});

test("a category filter lists only that category, newest first", async ({ page, site }) => {
  const transcripts = documents(site, "Transcripts");
  await page.goto(LISTING);

  await category(page).selectOption({ label: "Transcripts" });
  await search(page);

  await expect(page).toHaveURL(/[?&]document_category=[1-9]\d*\b/);
  await expect(category(page).locator("option:checked")).toHaveText("Transcripts");
  await expect(count(page)).toHaveText(`${transcripts.length} inquiry documents`);
  await expect(titles(page)).toHaveText(transcripts.map(({ title }) => title));
  for (const item of await items(page).all()) {
    await expect(item).toContainText("Transcripts");
  }
});

test("filters and the keyword combine", async ({ page }) => {
  await page.goto(LISTING);

  await category(page).selectOption({ label: "Reports" });
  await docType(page).selectOption({ label: "Welsh language version" });
  await search(page);

  await expect(titles(page)).toHaveText(["Puffin survey report"]);

  // A keyword the one report does not have.
  await keyword(page).fill("transcript");
  await search(page);

  await expect(items(page)).toHaveCount(0);
  await expect(noResults(page)).toHaveText("Your search for “transcript” matched no inquiry documents");
});

test("Clear removes the keyword and filters", async ({ page, site }) => {
  await page.goto(LISTING);
  await keyword(page).fill("puffin");
  await category(page).selectOption({ label: "Reports" });
  await search(page);
  await expect(count(page)).toHaveText("1 inquiry document");

  await form(page).getByRole("link", { name: "Clear" }).click();

  await expect(page).toHaveURL(new RegExp(`/${LISTING}$`));
  await expect(keyword(page)).toHaveValue("");
  await expect(category(page).locator("option:checked")).toHaveText("Select option");
  await expect(count(page)).toHaveText(`${documents(site).length} inquiry documents`);
});

test("a keyword with no matches says so", async ({ page }) => {
  await page.goto(LISTING);

  await keyword(page).fill(NO_MATCH);
  await search(page);

  await expect(noResults(page)).toHaveText(`Your search for “${NO_MATCH}” matched no inquiry documents`);
  await expect(page.locator("#primary")).toContainText("Try searching again with expanded criteria.");
  await expect(items(page)).toHaveCount(0);
  await expect(count(page)).toHaveCount(0);
  await expect(pager(page)).toHaveCount(0);
});

test("filters with no matches say so", async ({ page }) => {
  await page.goto(LISTING);

  await category(page).selectOption({ label: "Rulings" });
  await docType(page).selectOption({ label: "Welsh language version" });
  await search(page);

  await expect(noResults(page)).toHaveText("Your search matched no inquiry documents");
  await expect(items(page)).toHaveCount(0);
  await expect(pager(page)).toHaveCount(0);
});

test("pagination pages through every document once", async ({ page, site }) => {
  const all = documents(site);
  const pages = Math.ceil(all.length / PER_PAGE);
  await page.goto(LISTING);

  await expect(pager(page).locator(".archive-pagination-current-page")).toHaveText(`Page 1 of ${pages}`);
  await expect(previous(page)).toHaveCount(0);

  await next(page).click();

  await expect(page).toHaveURL(new RegExp(`/${LISTING}page/2/$`));
  await expect(pager(page).locator(".archive-pagination-current-page")).toHaveText(`Page 2 of ${pages}`);
  await expect(titles(page)).toHaveText(all.slice(PER_PAGE, 2 * PER_PAGE).map(({ title }) => title));
  await expect(next(page)).toHaveCount(0);

  await previous(page).click();

  await expect(page).toHaveURL(new RegExp(`/${LISTING}$`));
  await expect(titles(page)).toHaveText(all.slice(0, PER_PAGE).map(({ title }) => title));
});
