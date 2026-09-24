# extension-publisher

One toolkit to build, check and publish any Chromium extension to the **Chrome Web Store** and **Microsoft Edge Add-ons**, the same way from a terminal, Azure DevOps or GitHub Actions.

| Piece | What it does |
| --- | --- |
| [Publish-Extension.ps1](Publish-Extension.ps1) | Build → zip → check listing → upload and submit. The one entry point everything calls. |
| [New-Extension.ps1](New-Extension.ps1) | Creates a new extension from [templates/extension/](templates/extension/): Vite, React, TypeScript, Tailwind and shadcn/ui, with `store/` ready. |
| [New-StoreListing.ps1](New-StoreListing.ps1) | Adds a `store/` folder to an extension repo. |
| [Test-StoreConnection.ps1](Test-StoreConnection.ps1) | Checks the credentials sign in to both stores and shows Chrome's published and in-review versions. Read-only. |
| [publish-extension.sh](publish-extension.sh) | The same, from bash/sh. |
| [pipelines/azure/publish-extension.yml](pipelines/azure/publish-extension.yml) | Azure DevOps steps template. |
| [action.yml](action.yml) | GitHub Actions composite action. |
| [examples/](examples/) | A complete pipeline for each, to copy into an extension repo. |

## What's reused, and what this adds

The uploading is done by **[publish-browser-extension](https://github.com/aklinker1/publish-browser-extension)** (the publisher behind WXT; run with `npx`, pinned in `Publish-Extension.ps1`). It speaks Chrome Web Store API v2 and Edge Add-ons API v1.1, and deals with async uploads and store errors. We don't reimplement any of that.

It only uploads a zip you give it. This toolkit adds what it doesn't do:

- **Build and package**: runs the repo's build, zips with forward-slash paths, and strips `key` / `update_url` from the zipped manifest (both stores reject them). A repo can keep them for self-hosted builds.
- **A listing kept in the repo**: `store/` holds the description, images, privacy answers and reviewer notes. Neither store's API accepts listing content, so this folder is the source you copy into the dashboards and the record of what's there.
- **Checks before upload**: image sizes, screenshot counts, description length, and manifest limits. Every permission must have a written justification, and anything still marked TODO counts as missing. These are the usual reasons a review bounces, caught in seconds instead of days.
- **CI integration**: errors and warnings show up as Azure DevOps / GitHub annotations, a summary table on the run page, and the zip path and version as step outputs.

## Requirements

- PowerShell 7.2+ (`pwsh`), preinstalled on Azure DevOps and GitHub hosted agents (Windows, Linux, macOS)
- Node.js 18+ (for the extension's build and for `npx`)

## Starting a new extension

```powershell
./New-Extension.ps1 -Path ../TabNotes -Name 'Tab Notes' -Description 'Keep notes next to any page in the side panel.'
```

This creates a Manifest V3 project with **Vite**, **React**, **TypeScript**, **Tailwind CSS v4** and **[shadcn/ui](https://ui.shadcn.com)**, built with [@crxjs/vite-plugin](https://crxjs.dev), and runs `npm install` and `New-StoreListing.ps1` for you. It includes:

- A side panel (`src/sidepanel/`) that opens from the toolbar icon, with a starter UI built from shadcn components and a light/dark toggle.
- A service worker (`src/background/`), and `useStorage`, a `useState` backed by `chrome.storage`.
- `npm run store`, `store:publish` and `store:status` scripts that call this toolkit.
- Placeholder icons in `public/icons/`, which you replace.

Then run `npm run dev` in the new folder and load `dist/` as an unpacked extension. The project's README has the rest. `-Description` is required because it becomes the manifest description, which both stores show; `-SkipInstall` skips `npm install`, e.g. to use pnpm.

The shadcn files in the template come from `npx shadcn@latest init --template vite --preset nova`. To refresh them, generate a new project the same way and copy `src/components/ui/`, `src/index.css` and `components.json` over.

## Using it in an extension repo

```powershell
# 1. Once: add store/ to the extension
./New-StoreListing.ps1 -ProjectPath ../MyExtension

# 2. Fill in the TODOs and add the images (store/README.md says what goes where), then:
./Publish-Extension.ps1 -ProjectPath ../MyExtension                  # build, zip, report problems
./Publish-Extension.ps1 -ProjectPath ../MyExtension -Mode Validate   # just the checks; exit 1 on errors

# 3. Publish
./Publish-Extension.ps1 -ProjectPath ../MyExtension -Mode Publish -DryRun      # check credentials
./Publish-Extension.ps1 -ProjectPath ../MyExtension -Mode Publish              # submit to both stores
./Publish-Extension.ps1 -ProjectPath ../MyExtension -Mode Publish -Stores edge -NoSubmit   # Edge draft only
./Publish-Extension.ps1 -ProjectPath ../MyExtension -Mode Status               # Chrome review state
```

| Switch | |
| --- | --- |
| `-Stores chrome,edge` | Limit to some stores (default: those enabled in store.json) |
| `-ZipPath <zip>` | Publish an existing zip, e.g. the one a pipeline's build stage made |
| `-SkipBuild` | Zip the existing build output |
| `-NoSubmit` | Upload as a draft; submit from the dashboard |
| `-Staged` | Chrome: after approval, wait for a manual Publish |
| `-DryRun` | Check Chrome credentials, upload nothing. The engine's Edge dry run doesn't sign in at all, so Edge keys are only tested by a real upload (`-NoSubmit` is the safe one). |

### The store/ folder

```text
store/
├── store.json            build command + output, package options, store IDs (no secrets)
├── listing/en/           description.txt, search-terms.txt
├── images/               icon-128, logo-300, promo tiles, screenshots/
├── privacy/              single-purpose, permissions, data-usage, remote-code, privacy-policy
└── review/               reviewer-notes (test instructions for both stores' reviewers)
```

`store/README.md` in each repo maps every file to its dashboard field.

`store.json`:

```jsonc
{
  "name": "my-extension",                       // zip name: releases/<name>-<version>.zip
  "build":   { "command": "npm run build", "output": "dist" },
  "package": { "outDir": "releases", "exclude": ["*.map"], "stripManifestKeys": ["key", "update_url"] },
  "listing": { "defaultLocale": "en", "privacyPolicyUrl": "https://…" },
  "stores": {
    "chrome": { "enabled": true, "extensionId": "…32 letters…", "publisherId": "…uuid…", "publishType": "DEFAULT_PUBLISH" },
    "edge":   { "enabled": true, "productId": "…uuid…" }
  }
}
```

IDs aren't secret, so they live here. `CHROME_EXTENSION_ID`, `CHROME_PUBLISHER_ID` and `EDGE_PRODUCT_ID` override them, e.g. to point one pipeline at a test listing.

## One-time store setup

Neither API can create a store item. **Upload the first version of each extension by hand**, as described in [First release of a new extension](#first-release-of-a-new-extension). After that, the script handles every update.

### Chrome Web Store: service account (API v2)

API v1.1 and its OAuth refresh tokens are **shut down on 15 October 2026**, so this toolkit only uses v2 with a service account. That's better anyway, because nothing expires after 7 days.

1. [Google Cloud console](https://console.cloud.google.com): pick or create a project, then enable **Chrome Web Store API**.
2. IAM → Service accounts → **Create service account** (no roles needed) → Keys → **Add key → JSON**. Keep the file safe.
3. [Developer Dashboard](https://chrome.google.com/webstore/devconsole) → **Account**: add the service account's email. One service account per publisher.
4. Note the **Publisher ID** (Account page) and each item's **extension ID** (in its dashboard URL), and put them in `store.json`.

Secret: `CHROME_SERVICE_ACCOUNT_JSON` = the key file's contents. Pipeline secret variables are single-line, so compact it first:

```powershell
Get-Content key.json -Raw | ConvertFrom-Json | ConvertTo-Json -Compress | Set-Clipboard
```

### Edge Add-ons: API key (API v1.1)

1. [Partner Center](https://partner.microsoft.com/dashboard/microsoftedge/overview) → Microsoft Edge → **Publish API** → enable the new experience → **Create API credentials**.
2. Copy the **Client ID** and **API key**. The key expires (the page shows when), so note the date.
3. Each extension's **Product ID** is on its Overview page. Put it in `store.json`.

Secrets: `EDGE_CLIENT_ID`, `EDGE_API_KEY`.

### Where secrets go

| Where | How |
| --- | --- |
| Local, all extensions | `.env.store` in this toolkit's folder, for the publisher account's credentials shared by every extension you publish from here. Copy [.env.store.example](.env.store.example). |
| Local, one extension | `.env.store` in the extension repo (git-ignored by `New-StoreListing.ps1`; template in `store/.env.store.example`). |
| Azure DevOps | Variable group `extension-store-secrets` (ideally linked to Key Vault), all three marked secret. The template maps them into the script's environment. |
| GitHub | Environment `extension-stores` with required reviewers, holding the three secrets. |

`CHROME_SERVICE_ACCOUNT_KEY_FILE=` can point at the JSON key instead of pasting it; a relative path is relative to the folder of the `.env.store` that sets it. Real environment variables win over the extension's `.env.store`, which wins over the toolkit's.

### Checking the connection

```powershell
./Test-StoreConnection.ps1                          # the shared credentials sign in
./Test-StoreConnection.ps1 -ProjectPath ../*        # ...and every extension next to the toolkit
```

It reads, never uploads. Chrome: signs in with the service account, then shows each extension's published and in-review versions and any takedown or warning. Edge: checks the API key and client ID are accepted. Neither API can list a publisher's items, so it checks the IDs in each `store.json`, and Edge's API has no read call for a product at all, so a product ID is only proven by the first upload (`-Mode Publish -Stores edge -NoSubmit`). Exits 1 if anything fails.

### Keeping keys safe

Keys are kept out of git and out of the package:

- This repo ignores every `*.json` except the plugin manifests, since Google names a key `<project>-<hex>.json`. `New-StoreListing.ps1` adds `.env.store`, `*.service-account.json` and that key-name pattern to an extension's `.gitignore`.
- [.githooks/pre-commit](.githooks/pre-commit) blocks any commit that stages a private key, whatever the file is called. Turn it on once per clone: `git config core.hooksPath .githooks`
- Packaging refuses to zip a service account key found in the build output, so one can't be shipped to the store.

## First release of a new extension

Neither store's API can create an item. Both can only upload to one that already exists. So each extension's first version is created by hand in each dashboard, once. The toolkit prepares everything for it:

1. **Build the package and check the listing**

   ```powershell
   ./New-StoreListing.ps1 -ProjectPath ../MyExtension          # if it has no store/ yet
   ./Publish-Extension.ps1 -ProjectPath ../MyExtension         # zip in releases/, plus anything either store would reject
   ```

   Fix every error, and don't leave TODOs in `review/reviewer-notes.md` either, although the checks don't cover that file.

2. **Chrome Web Store**: in the [Developer Dashboard](https://chrome.google.com/webstore/devconsole), choose **New item** and upload the zip from `releases/`. Then fill in the tabs from `store/` (`store/README.md` maps each file to its field): **Store listing**, **Privacy** and **Distribution**. Submit for review, or save a draft.
   Copy the **extension ID**, the 32 letters in the item's dashboard URL, into `store.json` → `stores.chrome.extensionId`.

3. **Edge Add-ons**: in [Partner Center](https://partner.microsoft.com/dashboard/microsoftedge/overview), under Microsoft Edge, choose **Create new extension** and upload the **same zip**. Then fill in **Availability**, **Properties**, **Privacy** and **Store listings** from `store/`, add the reviewer notes, and submit.
   Copy the **Product ID** from the extension's Overview page into `store.json` → `stores.edge.productId`.

4. **Check the IDs**: run `./Test-StoreConnection.ps1 -ProjectPath ../MyExtension`. Chrome should show the item. Edge's API can't read a product, so the Edge ID is only proven by the next upload.

5. **Every release after that**: bump the version, then run `./Publish-Extension.ps1 -ProjectPath ../MyExtension -Mode Publish`, or push a `v*` tag if the pipeline is set up.

The listing text and images are **not** uploaded by the API, on either the first release or later ones. If they change, update them in the dashboards by hand. `store/` stays the record of what should be there.

## Pipelines

Both examples do the same thing. Every push and PR builds, checks, and keeps the zip as an artifact. A `v*` tag publishes **that same zip** to both stores after an approval.

### Azure DevOps

Push this toolkit to a repo in the same Azure DevOps organisation (e.g. `extension-publisher`), then copy [examples/azure-pipelines.yml](examples/azure-pipelines.yml) into the extension repo and set the repository resource's `name`. The first run asks you to permit access to the toolkit repo. Create:

- the variable group `extension-store-secrets`
- the environment `extension-stores`, with an **Approvals** check

The template sets `extension.extensionZip` and `extension.extensionVersion` as output variables.

### GitHub Actions

Push this toolkit to GitHub and tag it (`v1`), then copy [examples/github-workflow.yml](examples/github-workflow.yml) to `.github/workflows/` in the extension repo and replace `YOUR-ORG`. The action's outputs are `zip` and `version`.

A repo in one system can't use the other's copy of the toolkit, so if you have extensions in both, keep the toolkit in both (mirror it, or push to two remotes).

### Versioning

Both stores only accept a version higher than the last one uploaded. Bump `version` in the manifest (or package.json, if the build copies it from there) before tagging.

## AI skills (Claude Code)

The repo is also a Claude Code plugin with three skills, so an agent can do the parts that need reading the extension's code:

| Skill | What it does |
| --- | --- |
| [store-listing](skills/store-listing/SKILL.md) | Reads the extension and writes `store/`: the description, single purpose, a justification per permission, data usage, privacy policy, search terms and reviewer notes. Then runs the checks. |
| [publish-extension](skills/publish-extension/SKILL.md) | Fixes validation findings, bumps the version, checks credentials, and publishes (always confirming before the upload), locally or by tagging for CI. |
| [store-setup](skills/store-setup/SKILL.md) | One-time setup: store IDs, the Chrome service account, the Edge API key, `.env.store`, and GitHub or Azure DevOps pipeline secrets. |

Install it from Claude Code:

```text
/plugin marketplace add garethcheyne/extension-publisher
/plugin install extension-publisher@extension-publisher
```

Then, in an extension repo, ask it things like "write the store listing for this extension" or "publish 1.4.0 to Edge as a draft". The skills run the scripts from the plugin's own copy of the toolkit.

## Tests

```powershell
Invoke-Pester ./tests
```

## Store rules checked

From [Chrome's image guidelines](https://developer.chrome.com/docs/webstore/images) and [Edge's publishing guide](https://learn.microsoft.com/microsoft-edge/extensions/publish/publish-extension), as of September 2026. They're kept in one table at the top of [lib/StoreKit.psm1](lib/StoreKit.psm1).

| | Chrome | Edge |
| --- | --- | --- |
| Manifest | MV3 · name ≤ 75 · description ≤ 132 · version 1-4 integers ≤ 65535 | same |
| Description | required | 250-10,000 characters |
| Icon / logo | 128x128 | square, ≥ 128 (300x300 recommended) |
| Small promo | 440x280, **required** | 440x280, optional |
| Marquee / large promo | 1400x560, optional | 1400x560, optional |
| Screenshots | 1280x800 or 640x400, 1-5 | 1280x800 or 640x480, up to 6 |
| Privacy | single purpose, a justification per permission, data usage, policy URL | policy URL |
