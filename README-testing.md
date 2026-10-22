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

|Command|Purpose|
|---|---|
|`npm test`|Runs the Playwright test suite locally against `https://hale.docker`. The HTML report opens when the tests complete.|
|`npm run test:headed`|Runs the tests locally with the browser visible.|
|`npm run test:ui`|Opens Playwright UI mode for running and debugging tests interactively.|
|`npm run test:debug`|Runs Playwright in debug mode - allows tests to be stepped through.|
|`npm run test:report`|Opens the HTML report from the last Playwright test run.|
|`npm run test:browserstack:desktop`|Runs desktop tests through BrowserStack using Chrome on macOS Sequoia.|
|`npm run test:browserstack:mobile`|Runs mobile tests through BrowserStack using Chrome on a Samsung Galaxy S25 Ultra.|

## Current test suite coverage

## Current BrowserStack testing status

The GovWind mobile navigation tests have successfully run on the Samsung Galaxy S25 Ultra.

Separate desktop and mobile npm scripts have been added to select the relevant BrowserStack projects.

The Playwright test suite has been structured into separate directories by themes:

- **Hale:** Tests against the Hale Platform website.
- **Justice:** Tests against the Justice theme.
- **GovWind:** Tests against the CJSM homepage using the GovWind theme.
    
The tests provide automated checks of page content, navigation and key front-end functionality.

For the GovWind theme, the tests include checking that:

- The CJSM homepage loads and displays the expected content.
- The appropriate desktop or mobile navigation is displayed.
- The mobile navigation menu can be opened and closed.
- Navigation links work correctly.

These tests provide initial coverage to confirm that Playwright can interact with the locally running Hale Platform and that the same tests can be run through BrowserStack.

### Running Playwright tests locally

To run the full Playwright test suite against `https://hale.docker`:

```
npm test
```

The tests run using the following browser configurations:

|Platform|Browser|
|---|---|
|Desktop|Chromium|
|Desktop|Firefox|
|Desktop|WebKit (Safari browser engine)|
|Mobile emulation – Pixel 5|Mobile Chrome|
|Mobile emulation – iPhone 12|Mobile Safari|

Mobile tests use Playwright's device emulation to simulate mobile browser behaviour and viewport sizes. These are not tests running on physical mobile devices.

An HTML report is generated and opens automatically when the test run completes.

Screenshots are captured only when tests fail. Video recordings and traces are retained for failed tests to help investigate issues.

To run tests with the browser visible:

```
npm run test:headed
```

To open Playwright UI mode:

```
npm run test:ui
```

To debug tests using the Playwright Inspector:

```
npm run test:debug
```

To reopen the most recent HTML report:

```
npm run test:report
```

### Running Browserstack tests

The BrowserStack test platforms are configured in `browserstack.yml`.

|Platform|Browser|Operating system|
|---|---|---|
|Desktop|Chrome (latest)|macOS Sequoia|
|Samsung Galaxy S25 Ultra|Chrome|Android 15|

 BrowserStack mobile tests run on a real Samsung device.

### Running desktop tests

To run the desktop tests through BrowserStack:

```
npm run test:browserstack:desktop
```

This selects the desktop BrowserStack project, configured to use Chrome on macOS Sequoia.

Desktop tests exclude mobile-specific test files.

### Running mobile tests

To run the mobile tests through BrowserStack:

```
npm run test:browserstack:mobile
```

This selects the mobile BrowserStack project, configured to use Chrome on a Samsung Galaxy S25 Ultra.

Mobile test files follow the naming convention:

```
mobile-*.spec.js
```

This allows mobile tests to be organised within the individual theme directories and selected together for execution.

### BrowserStack results

Test results, session recordings and debugging information can be found in the BrowserStack dashboard.

