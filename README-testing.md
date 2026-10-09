# Playwright testing

Playwright has been added to the Hale Platform to provide automated front-end testing against the local Docker environemnt.

Tests can be run locally using Playwright or remotely through BrowserStack against the local Hale Platform.

## Requirements:

- Hale must be running locally
- Node.js and npm must be installed
- A BrowserStack account is needed to run the BrowserStack tests

## Installation

- checkout the add-playwright-test branch
- install dependencies:

`npm ci`

- Install Playwright browsers:

`npx playwright install`

## Running tests

The following npm scripts are available:

| Command | Purpose |
| --- | --- |
| `npm test` | Runs the Playwright test suite locally against `https://hale.docker`. The HTML report opens when the tests complete. |
| `npm run test:headed` | Runs the tests locally with the browser visible. Useful for watching how a test interacts with the site. |
| `npm run test:ui` | Opens Playwright UI mode for running and debugging tests interactively. |
| `npm run test:debug` | Runs Playwright in debug mode, allows tests to be stepped through using the Playwright Inspector. |
| `npm run test:report` | Opens the HTML report from the last Playwright test run. |
| `npm run test:browserstack` | Runs the Playwright test suite through BrowserStack against  Hale Platform running locally. |

## Current test suite coverage

The current Playwright test suite provides basic checks against the Hale Platform homepage.

The tests currently check that:

- the homepage loads and returns a page title
- the homepage contains the expected `Ministry of Justice Website Builder` title
- a level-one heading is visible on the homepage
- a user can follow the `How to make a good website` link and navigate to the `designing-your-site` page
- the site footer is visible

These tests provide initial coverage to confirm that Playwright can interact with the locally running Hale Platform and that the same tests can be run through BrowserStack.

### Running Playwright tests locally

To run playwright tests locallay against `https://hale.docker`:

` npm test`

This generates a HTML report which opens automatically when the test run completes.  Video and screen shots are only included when tests fail.

### Running Browserstack tests

BrowserStack credentials are loaded from a local .env file.

Create a .env fiel at the project root and include:

```
BROWSERSTACK_USERNAME=your_username
BROWSERSTACK_ACCESS_KEY=your_access_key
```

To run BrowserStack tests:

` npm run test:browserstack`

Note: .env is included in .gitignore

The BrowserStack test results and session recordings can be viewed in the BrowserStack Automate dashboard.


