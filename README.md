# Publish to BrewPage: CircleCI orb

Publish a test report, HTML or Markdown page, file or static site from a CircleCI job to [BrewPage](https://brewpage.app) and get a shareable link. Free, fast, no sign-up and no API key; agent-friendly REST API.

Orb: `brewpage/publish`. Source of the orb in this repository; examples in [src/examples](src/examples).

## Usage

Publish an HTML test report after the tests, even when they fail:

```yaml
version: 2.1
orbs:
  brewpage: brewpage/publish@1.0.0
jobs:
  test:
    docker:
      - image: cimg/node:24.22.2-browsers
    steps:
      - checkout
      - run: npm ci && npx playwright test
      - brewpage/publish:
          path: playwright-report
      - run: echo "Report at $BREWPAGE_LINK"
```

The `publish` command prints the link and exports `BREWPAGE_LINK`, `BREWPAGE_ID`, `BREWPAGE_NAMESPACE` and `BREWPAGE_EXPIRES_AT` to later steps. The `publish` job attaches the workspace first, so a separate job can publish what an earlier job persisted.

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `path` | required | File, directory (static site) or `.zip` (with `kind: site`). `.html` and `.md` files become pages. |
| `kind` | `auto` | `auto` (directory = site, else file), `file` or `site`. |
| `namespace` | empty | Empty: private, unlisted, link-only. `public`: listed in the gallery and sitemap; anyone can find it, never publish secrets there. |
| `ttl` | empty | Days the publication stays; empty = server default. Up to 30 days without an account, up to 90 with a free profile. |
| `tags` | empty | Comma-separated tags. |
| `entry` | empty | Site entry file (default `index.html`). |
| `owner_token` | `BREWPAGE_OWNER_TOKEN` | Name of the env var with your owner token (optional): keeps all publications under one owner you can manage at [account.brewpage.app](https://account.brewpage.app). Mint one with `curl -fsS https://brewpage.app/api/owner-token` and store it in a context or project env var. |
| `password` | `BREWPAGE_PASSWORD` | Name of the env var with an access password (optional, at least 4 characters). |
| `show_manage_url` | `true` | Print the private manage link (anyone who has it can edit or delete). Set `false` for public projects. |
| `api_url` | `https://brewpage.app` | BrewPage base URL. |
| `when` | `always` | `always`, `on_success` or `on_fail` (command only). |

## Developing

`src/scripts/publish.sh` is a copy of the shared publish script. Pack and validate:

```bash
circleci orb pack src > orb.yml
circleci orb validate orb.yml
```

## Links

- [brewpage.app](https://brewpage.app), [API guide for agents](https://brewpage.app/llms.txt), [OpenAPI docs](https://kochetkov-ma.github.io/brewpage-openapi/)
- [Publish to BrewPage GitHub Action](https://github.com/kochetkov-ma/brewpage-action)

## License

MIT
