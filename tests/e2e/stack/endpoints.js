// Print the test stack's addresses and what each one is for. Run by
// `make test-e2e-urls` in the playwright container. Reads the sites and port
// from support/stack.js, so it follows sites.json and HALE_TEST_PORT.
// stack.sh checks on the host whether the stack is up and passes the answer in
// E2E_STACK_RUNNING, since the container cannot ask Docker.

const { NETWORK_URL, LOGIN_PATH, PASSWORD, PORT, PROJECT, sites, users } = require("../support/stack");

const rows = [];
const section = (title) => rows.push(["", ""], [title, ""]);
const row = (url, purpose) => rows.push([url, purpose]);

section("Sites");
for (const site of sites) {
  row(site.url, `${site.key} site (${site.theme} theme)`);
}

section("Seeded pages (main site shown; on other sites add the site path, e.g. /ppo/about/. justice has no blocks page or posts)");
row(`${NETWORK_URL}about/`, "About page, shared fixture");
row(`${NETWORK_URL}blocks/`, "Custom blocks page, used by specs/all-sites/blocks.spec.js");
row(`${NETWORK_URL}news/`, "Posts page");
row(`${NETWORK_URL}first-news-story/`, "Post with a featured image");

section("hale site pages (modelled on websitebuilder.service.justice.gov.uk; specs/hale/pages.spec.js)");
row(`${NETWORK_URL}about-website-builder/`, "Menu section: banner, feature tiles, media and text");
row(`${NETWORK_URL}about-website-builder/features/`, "Child page");
row(`${NETWORK_URL}designing-your-site/`, "Menu section: rounded panels");
row(`${NETWORK_URL}designing-your-site/creating-content/`, "Child page");
row(`${NETWORK_URL}user-guides/`, "Menu section: rounded panels");
row(`${NETWORK_URL}user-guides/get-started/`, "Child page: images, separators, cards");

const govwind = sites.find((s) => s.key === "govwind");
if (govwind) {
  section("govwind site pages (modelled on the IPA site; specs/govwind/pages.spec.js)");
  row(`${govwind.url}about-us/`, "Menu: two-column panels, FAQ accordion");
  row(`${govwind.url}get-support/`, "Menu: submenu parent");
  row(`${govwind.url}get-support/get-support-from-the-independent-public-advocate/`, "Submenu child page");
  row(`${govwind.url}news/`, "Menu: filterable listing of the posts");
  row(`${govwind.url}briefings/`, "Menu");
  row(`${govwind.url}contact-us/`, "Menu");
}

const justice = sites.find((s) => s.key === "justice");
if (justice) {
  section("justice site pages (modelled on www.justice.gov.uk; specs/justice/pages.spec.js)");
  row(`${justice.url}courts/procedure-rules/`, "Header link: Procedure rules, left menu");
  row(`${justice.url}courts/procedure-rules/civil/`, "Child page: breadcrumbs, search block, Archived pages panel, document links");
  row(`${justice.url}documents/pd-making-document.pdf`, "Document (PDF), served by WP Document Revisions");
  row(`${justice.url}documents/cpr-email-address-list.docx`, "Document (DOCX)");
  row(`${justice.url}documents/court-forms-destination-table.xlsx`, "Document (XLSX)");
}

section("Admin");
row(`${NETWORK_URL}${LOGIN_PATH}`, "Login (test-only wps-hide-login path)");
row(`${NETWORK_URL}wp-admin/`, "Main site dashboard");
row(`${NETWORK_URL}wp-admin/network/`, "Network admin");
row(`${NETWORK_URL}wp-admin/network/sites.php`, "Network sites list, used by specs/network/");
for (const site of sites.filter((s) => s.path)) {
  row(`${site.url}wp-admin/`, `${site.key} dashboard`);
}

section("Reports");
row("http://localhost:9323/", "HTML report, served by make test-e2e-report");

const width = Math.max(...rows.filter(([, purpose]) => purpose).map(([url]) => url.length));
console.log(`Test stack (${PROJECT}) at ${NETWORK_URL}`);
console.log(
  process.env.E2E_STACK_RUNNING === "1"
    ? "Status: running"
    : "Status: not running. Start it with make test-e2e-up (or check Docker is reachable).",
);
for (const [url, purpose] of rows) {
  console.log(purpose ? `  ${url.padEnd(width)}  ${purpose}` : url);
}
console.log("");
console.log(`Users (password ${PASSWORD}): ${Object.entries(users).map(([role, login]) => `${login} (${role})`).join(", ")}`);
console.log(`Self-signed certificate: accept the browser warning once for localhost:${PORT}.`);
