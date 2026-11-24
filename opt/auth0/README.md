# Auth0 email via GOV.UK Notify

| File | Pasted into |
| --- | --- |
| `main.cjs` | Auth0 > Branding > Email Provider > Custom provider |
| `template.md` | Notify > MoJ Website Builder Auth > Templates |

The script sends `subject` and `body` as personalisation; the template renders them as `((subject))` and `((body))`. Change them together.

Deployment steps are in the header comment of each file.

Tests (Node 24+, no install): `node --test main_test.cjs`
