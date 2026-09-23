---
name: store-setup
description: One-time setup for publishing a Chromium extension with the extension-publisher toolkit, covering the Chrome Web Store service account, the Edge Add-ons API key, store IDs in store.json, local .env.store secrets, and GitHub Actions or Azure DevOps pipeline wiring. Use when the user needs to connect an extension to the stores, add or rotate store credentials, fix "Missing settings" errors, or set up a release pipeline.
---

# Store setup

Connect an extension repo to the Chrome Web Store and Edge Add-ons so
`Publish-Extension.ps1` can upload to them, locally and from CI. The toolkit
README's "One-time store setup" section is the reference; this skill is the order
to do it in and the traps to avoid.

**Toolkit root**: two directories above this skill's base directory. **Project**: the
extension repo with `store/store.json` (create it with the `store-listing` skill if
missing).

## Rules for secrets

- Never print, echo, log or commit a secret, and never paste one into a command line where it lands in shell history. Read it from a file or stdin.
- Before writing a `.env.store`, run `git check-ignore .env.store` in that folder. The toolkit's `.gitignore` covers it, and `New-StoreListing.ps1` adds `.env.store` and `*.service-account.json` to the extension's.
- Don't ask the user to paste secrets into the chat. Tell them where to put them, then check that they're present without showing the values.

## 1. Store items exist

Neither API can create an item. For each store with no item yet, the user uploads
the first zip by hand. Build it with `pwsh <toolkit>/Publish-Extension.ps1 -ProjectPath <project>`
and give them the path it prints.

## 2. IDs in store.json (not secret)

- `stores.chrome.extensionId`: 32 letters, from the item's Developer Dashboard URL
- `stores.chrome.publisherId`: a UUID, from Developer Dashboard → Account
- `stores.edge.productId`: a UUID, from the Edge item's Partner Center Overview page

Set `enabled: false` for a store the extension isn't published to. The environment
variables `CHROME_EXTENSION_ID`, `CHROME_PUBLISHER_ID` and `EDGE_PRODUCT_ID` override
these, for example to point one pipeline at a test listing.

## 3. Credentials

Walk the user through the dashboard steps; you can't do them for them.

**Chrome (API v2, service account; v1.1 OAuth tokens stop working on 15 October 2026)**
1. Google Cloud console: enable the **Chrome Web Store API** in a project.
2. IAM → Service accounts → create one (no roles) → Keys → Add key → JSON.
3. Chrome Developer Dashboard → Account → add the service account's email. One service account per publisher account.

**Edge (API v1.1)**
1. Partner Center → Microsoft Edge → Publish API → enable the new experience → Create API credentials.
2. Keep the Client ID and API key. **The key expires**, so have the user note the date.

## 4. Local secrets

Copy `<toolkit>/.env.store.example` to `.env.store` in one of two places, then have
the user fill it in:

- **The toolkit's folder**: shared by every extension published from it. This is the usual choice, since one publisher account covers all of a user's extensions.
- **The extension repo's root**: for that extension only (a different publisher account, or a test listing's IDs). Wins over the toolkit's file.

The values:

- `CHROME_SERVICE_ACCOUNT_KEY_FILE=` the JSON key's path, absolute or relative to the folder of that `.env.store`. Keep the key file outside any repo, or name it `*.service-account.json` so it's ignored.
- `EDGE_CLIENT_ID=` and `EDGE_API_KEY=`

Real environment variables win over both files.

## 5. Verify

Run `pwsh <toolkit>/Test-StoreConnection.ps1 -ProjectPath <project>`. It's read-only,
so it's safe to run any time. It signs in to both stores and shows Chrome's published and
in-review versions for the IDs in store.json. Without `-ProjectPath` it checks only
the toolkit's shared credentials. It exits 1 if any check fails, and each FAIL line
says what to fix:

- Google refused the service account: the key file is wrong or its key was deleted in the Cloud console.
- Chrome 403 or 404: wrong `extensionId` or `publisherId`, or the service account isn't added under Developer Dashboard → Account.
- Edge rejected (401): wrong client ID or key, or the key has expired.

It can't confirm Edge's product ID, because Edge's API has no read call for a product.
The first real upload proves it: `-Mode Publish -Stores edge -NoSubmit`. That replaces
any pending Edge draft and needs a higher version than the last upload, so confirm
with the user first.

## 6. CI (if wanted)

Both example pipelines package on every push and PR, and publish the same zip when a
`v*` tag is pushed, after an approval.

**GitHub Actions**
1. The toolkit repo must be on GitHub with a `v1` tag. Check with `gh api repos/<owner>/extension-publisher/git/refs/tags/v1`.
2. Copy `<toolkit>/examples/github-workflow.yml` to `.github/workflows/extension.yml` and replace `YOUR-ORG` with the toolkit's owner.
3. Create the `extension-stores` environment with required reviewers (repo Settings → Environments; `gh` can't set reviewers without the API).
4. Set the secrets from files or stdin, never as arguments:
   `gh secret set CHROME_SERVICE_ACCOUNT_JSON --env extension-stores < key.json`, and the same for `EDGE_CLIENT_ID` and `EDGE_API_KEY` (`gh secret set NAME --env extension-stores` prompts for the value).

**Azure DevOps**
1. The toolkit must be a repo in the same organisation.
2. Copy `<toolkit>/examples/azure-pipelines.yml` to the project root and set the `publisher` repository's `name` to `<project>/<repo>`.
3. Create the variable group `extension-store-secrets` (ideally linked to Key Vault) with the three secrets marked secret. The JSON must be one line: `Get-Content key.json -Raw | ConvertFrom-Json | ConvertTo-Json -Compress | Set-Clipboard`.
4. Create the environment `extension-stores` with an Approvals check. The first run asks for permission to use the toolkit repo.

Creating environments, secrets and workflows changes shared settings, so confirm
before running `gh` commands that write.

## Report

Tell the user what's configured, what they still have to do in a dashboard, and the
Edge API key's expiry date if they gave it, so they can plan to rotate it.
