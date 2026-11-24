const { test, expect } = require("../../support/test");
const { seededItems } = require("../../support/content");

// PHP that reaches the visitor instead of running: source from a file PHP did
// not parse (a short open tag with short_open_tag off, a template served as
// text), and error messages printed into the page. display_errors is off in
// opt/php/www.conf, so an error message here means that stopped holding. Also
// phpinfo() output left in a template, which lists the server's environment.
// Checked in the HTML as sent, since a browser hides <?php ... ?> as a comment.
const PHP_OUTPUT = [
  { name: "PHP open tag", pattern: /<\?(?:php\b|=|\s)/i },
  {
    name: "PHP error message",
    pattern:
      /\b(?:Fatal error|Parse error|Recoverable fatal error|Warning|Notice|Deprecated)(?:<\/b>)?:\s+.*? in (?:<b>)?\/\S+?\.php(?:<\/b>)?(?::\d+| on line)/,
  },
  { name: "PHP stack trace", pattern: /Stack trace:\s*(?:<br \/>\s*)?#0 / },
  { name: "WordPress critical error", pattern: /There has been a critical error on this website/ },
  { name: "phpinfo() output", pattern: /<title>PHP [^<]* - phpinfo\(\)<\/title>|<h1 class="p">PHP Version / },
];

// Templates the seeded content does not reach.
const OTHER_PATHS = ["?s=e2e", "e2e-page-that-does-not-exist/"];

// The site's seeded pages and posts, from the content.json the seed reads, so
// a page added there is checked too. Permalinks are /%postname%/
// (seed/seed.sh): a page sits below its parents, a post at its slug, and an
// ACF post type's posts below its key (ACF's default rewrite slug).
function seededPaths(site) {
  const { frontPage } = require(`../../seed/content/${site.key}/content.json`);
  const items = seededItems(site);
  const bySlug = new Map(items.map((item) => [item.slug, item]));
  const pathOf = (item) =>
    (item.parent ? pathOf(bySlug.get(item.parent)) : ["page", "post"].includes(item.type) ? "" : `${item.type}/`) +
    `${item.slug}/`;
  return items.map((item) => (item.slug === frontPage ? "./" : pathOf(item)));
}

test("no PHP source or error messages reach the page", async ({ page, site }) => {
  const found = [];

  for (const path of [...seededPaths(site), ...OTHER_PATHS]) {
    await test.step(path, async () => {
      const response = await page.goto(path);
      const status = response?.status() ?? 0;
      if (status >= 500) {
        found.push(`${path}: HTTP ${status}`);
      }

      const html = (await response?.text()) ?? "";
      for (const { name, pattern } of PHP_OUTPUT) {
        const match = html.match(pattern);
        if (match) {
          found.push(`${path}: ${name}: ${match[0].slice(0, 200)}`);
        }
      }
    });
  }

  expect(found, "PHP source or errors in the HTML the site sends").toEqual([]);
});
