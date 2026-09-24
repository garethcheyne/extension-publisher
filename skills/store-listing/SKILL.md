---
name: store-listing
description: Write or update a Chromium extension's Chrome Web Store and Edge Add-ons listing (the store/ folder) by reading the extension's code, covering the description, single purpose, permission justifications, data usage, privacy policy, search terms and reviewer notes. Use when the user wants to prepare an extension for the stores, fill in store/ TODOs, justify permissions, answer the privacy questions, or after adding a permission to the manifest.
---

# Store listing

Fill in an extension's `store/` folder from what its code actually does. Reviewers
reject listings that claim features the code doesn't have and justifications that
don't match the code, so every sentence here must be backed by something you read.

## Find the toolkit and the project

- **Toolkit root**: two directories above this skill's base directory (`skills/store-listing/` → root). It holds `New-StoreListing.ps1`, `Publish-Extension.ps1` and `templates/store/README.md`. If that folder has no `Publish-Extension.ps1`, look for a clone of `extension-publisher` next to the project, or ask for its path.
- **Project**: the extension repo, normally the current directory. It's the folder that will hold `store/store.json`.

Scripts need PowerShell 7.2+ (`pwsh`).

## 1. Scaffold

Run `pwsh <toolkit>/New-StoreListing.ps1 -ProjectPath <project>`. It never overwrites
anything, so run it even when `store/` exists: it adds a `## <permission>` section for
any permission added to the manifest since. It reads the manifest from the build
output if there is one, so build first when the manifest is generated.

Check `build.command` and `build.output` in `store/store.json` against package.json
and the bundler config.

## 2. Read the extension

Read the manifest (the built one if the source is a template), then every entry
point it names: service worker, content scripts, popup, options, side panel,
offscreen documents. Then search the source (not `node_modules` or the build
output) for where data goes and which APIs are used:

- Network: `fetch(`, `XMLHttpRequest`, `WebSocket`, `EventSource`, `sendBeacon`, `axios`, hard-coded URLs and hostnames, analytics or error-reporting SDKs
- Storage: `chrome.storage`, `browser.storage`, `localStorage`, `indexedDB`
- Each permission's API: `chrome.tabs`, `chrome.scripting`, `chrome.cookies`, `chrome.identity`, `chrome.history`, `chrome.downloads`, `chrome.contextMenus`, `chrome.sidePanel`, and so on
- What content scripts read from the page (DOM text, form fields, selection) and what they send to the service worker

Keep notes on which file and function uses each permission and each network
destination. They are the evidence for everything you write next.

## 3. Write each file

`templates/store/README.md` in the toolkit maps every file to its dashboard field.
Replace each `TODO` and its instruction text with the real content. The publish
script treats any remaining `TODO` as missing.

**`listing/<locale>/description.txt`**: plain text, since neither store renders Markdown. Open with one sentence on what it does and for whom, then the features (short lines or `•` bullets), then what access it needs and why, then a support contact if store.json has one. Edge needs 250 to 10,000 characters; aim for 800 to 2,000. Describe only features that exist. No keyword lists, no other companies' names beyond the site the extension works on (for example "works with ServiceNow"), and no claims of being official or endorsed.

**`privacy/single-purpose.md`**: one or two sentences naming one narrow purpose that every feature serves. If the features don't share one purpose, tell the user. Chrome rejects multi-purpose extensions, and the fix is a product decision, not wording.

**`privacy/permissions.md`**: under each `## <permission>`, 2 to 4 sentences: what the extension does with it, on which user action, and why it can't work without it. Name the feature, not the API ("Saves your column layout between sessions", not "Uses chrome.storage"). Keep the host bullet list under `## host permissions` and give a reason for each pattern. For broad patterns (`<all_urls>`, `*://*/*`), say why narrower ones won't do, or recommend `activeTab` or narrower matches if the code shows they would work. If the code never uses a permission, don't invent a reason: tell the user and suggest removing it from the manifest. Headings must match the manifest exactly, because the publish script checks both ways.

**`privacy/data-usage.md`**: tick `[x]` a category only when the code gives evidence for it, and under "Where does it go?" name every server from your network notes and what is sent there. If the extension sends nothing anywhere, say so plainly. Where it's unclear whether something counts (for example page text that is read but never leaves the browser), ask the user rather than guess, since a wrong answer here is a policy violation. Leave the three **certifications** unticked and ask the user to confirm them: they are the developer's declarations, not facts you can check.

**`privacy/remote-code.md`**: answer "No" only if every script is in the package: no remote `<script>` tags, no `eval()` or `new Function()`, no code fetched and run at runtime. Fetching JSON or HTML to display is data, not code. If you find remote code, say where, and tell the user it has to be bundled, because Manifest V3 doesn't allow it.

**`privacy/privacy-policy.md`**: write the policy under the explanatory header, based on data-usage.md: what is collected, why, where it's stored, who it's shared with, how long it's kept, and how to contact the developer. Don't make up a contact address or company name; ask, or leave a `TODO:` on that line. Remind the user that the stores need it at a public URL, set as `listing.privacyPolicyUrl` in store.json.

**`listing/<locale>/search-terms.txt`** (Edge only): up to 7 terms, one per line, each 30 characters or less and 21 words in total, describing what users would search for. No competitors' trademarks.

**`review/reviewer-notes.md`**: how a reviewer reaches the site the extension works on (a public URL, a free trial, or why it's internal), then numbered steps to see each feature working. Never write a password or token here. Say "test account details are in the dashboard's test-instructions field" and tell the user to enter them there. If it works on any site, write "None needed." plus a one-line way to try it.

Also check the manifest `name` (75 characters or less) and `description` (132 or less). If they're too long or vague, suggest new wording for the user to apply. If they come from `_locales`, the edit goes there.

## 4. Check

Run `pwsh <toolkit>/Publish-Extension.ps1 -ProjectPath <project>` (Package mode builds,
zips and reports; use `-Mode Validate` to check an existing build without rebuilding).
Fix every text finding. The rest usually needs the user:

- **Images**: list each missing or wrong-sized file with its required size. Required: `icon-128.png` 128x128 (Chrome, usually copied from the manifest icon), `promo-small-440x280.png` (Chrome), and at least one screenshot at 1280x800 (fits both stores). If the user supplies images at other sizes and an image tool is available, you can resize or pad them, but never stretch a screenshot to another aspect ratio.
- **Store IDs and privacy policy URL**: the `store-setup` skill covers these.

## 5. Report

Tell the user which files you wrote, anything you couldn't back up from the code
(and what you did about it), the questions you need them to answer (data-usage edge
cases, the certifications, contact details), and what's left before publishing.
The listing text still has to be pasted into each dashboard by hand, because neither
store's API accepts it.
