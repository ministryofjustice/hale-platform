/**
 * Returns the URLs of all seeded WordPress pages for a given site.
 *
 * Reads the site's content.json and filters for pages (post are not currently included).
 * Builds each page's URL path using its slug and any parent relationships,
 * including nested pages. The configured front page uses the site's root URL.
 *
 * Checks for missing parents and circular relationships before combining
 * each page path with the site's base URL.
 *
 */

const path = require("node:path");

function getSitePageUrls(site) {

  // Load the seeded content for the selected site
  const content = require(
    path.join(__dirname, "../seed/content", site.key, "content.json")
  );

  // filter for pages only
  const pages = content.items.filter(item => item.type === "page");

  // Create a pages relative URL path 
  function getPagePath(page) {

    //front page ---> root URL
    if (page.slug === content.frontPage) {
      return "";
    }

    const pathParts = [page.slug];
    const visited = new Set([page.slug]);
    let parentSlug = page.parent;

    // Trace the page's parent relationships and end loop when no parent is found
    while (parentSlug) {

      // Prevent circular parent relationships
      if (visited.has(parentSlug)) {
        throw new Error(`Circular parent relationship: ${parentSlug}`);
      }

      visited.add(parentSlug);

      // Find the parent page using its slug
      const parent = pages.find(page => page.slug === parentSlug);

      if (!parent) {
        throw new Error(`Parent page not found: ${parentSlug}`);
      }

      // Stop if we've reached the front page
      if (parent.slug === content.frontPage) {
        break;
      }

      // Add the parent slug to the beginning of the path
      pathParts.unshift(parent.slug);

      // Move to the next parent
      parentSlug = parent.parent;
    }

    return pathParts.join("/");
  }

  // Ensure the site's base URL ends with a slash
  const baseURL = site.url.endsWith("/")
    ? site.url
    : `${site.url}/`;

  // create and return the URLs for all seeded pages
  return pages.map(page => {
    const pagePath = getPagePath(page);
     return new URL(pagePath ? `${pagePath}/` : "", baseURL).toString();
  });
}

module.exports = { getSitePageUrls };