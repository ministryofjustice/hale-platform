// @ts-check
const { defineConfig, devices } = require('@playwright/test');

/**
 * BrowserStack Configuration for Playwright
 * @see https://playwright.dev/docs/test-configuration
 */
module.exports = defineConfig({
  testDir: './tests',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  workers: process.env.CI ? 4 : 2, // Increased workers for BrowserStack
  reporter: [
    ['html'],
    ['junit', { outputFile: 'test-results/junit.xml' }]
  ],
  
  use: {
    baseURL: process.env.BASE_URL || 'https://hale.docker',
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
    video: 'retain-on-failure',
    // Increased timeouts for BrowserStack
    actionTimeout: 30000,
    navigationTimeout: 60000,
  },

  projects: [
    // Desktop browsers
    {
      name: 'chrome-latest',
      use: {
        ...devices['Desktop Chrome'],
        connectOptions: {
          wsEndpoint: `wss://cdp.browserstack.com/playwright?caps=${encodeURIComponent(JSON.stringify({
            'browserstack.username': process.env.BROWSERSTACK_USERNAME,
            'browserstack.accessKey': process.env.BROWSERSTACK_ACCESS_KEY,
            'browser': 'chrome',
            'browser_version': 'latest',
            'os': 'Windows',
            'os_version': '11',
            'project': 'Ministry of Justice Website Builder',
            'build': `Build ${new Date().toISOString()}`,
            'name': 'Chrome Latest Test'
          }))}`
        }
      }
    },
    {
      name: 'firefox-latest',
      use: {
        ...devices['Desktop Firefox'],
        connectOptions: {
          wsEndpoint: `wss://cdp.browserstack.com/playwright?caps=${encodeURIComponent(JSON.stringify({
            'browserstack.username': process.env.BROWSERSTACK_USERNAME,
            'browserstack.accessKey': process.env.BROWSERSTACK_ACCESS_KEY,
            'browser': 'playwright-firefox',
            'browser_version': 'latest',
            'os': 'Windows',
            'os_version': '11',
            'project': 'Ministry of Justice Website Builder',
            'build': `Build ${new Date().toISOString()}`,
            'name': 'Firefox Latest Test'
          }))}`
        }
      }
    },
    {
      name: 'safari-latest',
      use: {
        ...devices['Desktop Safari'],
        connectOptions: {
          wsEndpoint: `wss://cdp.browserstack.com/playwright?caps=${encodeURIComponent(JSON.stringify({
            'browserstack.username': process.env.BROWSERSTACK_USERNAME,
            'browserstack.accessKey': process.env.BROWSERSTACK_ACCESS_KEY,
            'browser': 'playwright-webkit',
            'browser_version': 'latest',
            'os': 'OS X',
            'os_version': 'Monterey',
            'project': 'Ministry of Justice Website Builder',
            'build': `Build ${new Date().toISOString()}`,
            'name': 'Safari Latest Test'
          }))}`
        }
      }
    },

    // Mobile devices
    {
      name: 'iphone-13',
      use: {
        connectOptions: {
          wsEndpoint: `wss://cdp.browserstack.com/playwright?caps=${encodeURIComponent(JSON.stringify({
            'browserstack.username': process.env.BROWSERSTACK_USERNAME,
            'browserstack.accessKey': process.env.BROWSERSTACK_ACCESS_KEY,
            'browser': 'playwright-chromium',
            'os': 'ios',
            'os_version': '15',
            'device': 'iPhone 13',
            'real_mobile': 'true',
            'project': 'Ministry of Justice Website Builder',
            'build': `Build ${new Date().toISOString()}`,
            'name': 'iPhone 13 Test'
          }))}`
        }
      }
    },
    {
      name: 'samsung-galaxy-s22',
      use: {
        connectOptions: {
          wsEndpoint: `wss://cdp.browserstack.com/playwright?caps=${encodeURIComponent(JSON.stringify({
            'browserstack.username': process.env.BROWSERSTACK_USERNAME,
            'browserstack.accessKey': process.env.BROWSERSTACK_ACCESS_KEY,
            'browser': 'playwright-chromium',
            'os': 'android',
            'os_version': '12.0',
            'device': 'Samsung Galaxy S22',
            'real_mobile': 'true',
            'project': 'Ministry of Justice Website Builder',
            'build': `Build ${new Date().toISOString()}`,
            'name': 'Samsung Galaxy S22 Test'
          }))}`
        }
      }
    },

    // Older browser versions for compatibility testing
    {
      name: 'chrome-legacy',
      use: {
        ...devices['Desktop Chrome'],
        connectOptions: {
          wsEndpoint: `wss://cdp.browserstack.com/playwright?caps=${encodeURIComponent(JSON.stringify({
            'browserstack.username': process.env.BROWSERSTACK_USERNAME,
            'browserstack.accessKey': process.env.BROWSERSTACK_ACCESS_KEY,
            'browser': 'chrome',
            'browser_version': '90.0',
            'os': 'Windows',
            'os_version': '10',
            'project': 'Ministry of Justice Website Builder',
            'build': `Build ${new Date().toISOString()}`,
            'name': 'Chrome Legacy Test'
          }))}`
        }
      }
    }
  ],
});
