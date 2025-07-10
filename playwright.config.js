// playwright.config.js
import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
  // …global settings …

  projects: [
    {
      name: 'hale',          
      testDir: './tests/hale',
      use: {
        ...devices['Desktop Chrome'],
        baseURL: 'https://demo.websitebuilder.service.justice.gov.uk/',
        connectOptions: {
          wsEndpoint:
            `wss://cdp.browserstack.com/playwright?caps=${encodeURIComponent(JSON.stringify(caps['Chrome Latest']))}`
        },
        storageState: '' // optional login state
      }
    }
  ]
});

