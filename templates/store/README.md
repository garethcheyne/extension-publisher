# Store listing

Everything the Chrome Web Store and Edge Add-ons ask for, kept with the code.
The store APIs only accept the package, so the listing text and images are entered
in each dashboard by hand. This folder is the record of what's there, and the
publish script checks it against both stores' rules before every upload.

```
store/
├── store.json                   build, package and store IDs (no secrets)
├── .env.store.example           copy to ../.env.store for local publishing
├── listing/<locale>/
│   ├── description.txt          full description, plain text
│   └── search-terms.txt         Edge only
├── images/
│   ├── icon-128.png             Chrome: store icon, 128x128
│   ├── logo-300.png             Edge: extension logo, square, 300x300
│   ├── promo-small-440x280.png  Chrome: required · Edge: optional
│   ├── promo-marquee-1400x560.png   both optional
│   └── screenshots/             1280x800 fits both stores; named 01-…, 02-… in display order
├── privacy/
│   ├── single-purpose.md        Chrome → Privacy → Single purpose
│   ├── permissions.md           a "## <permission>" justification per manifest permission
│   ├── data-usage.md            Chrome → Privacy → Data usage (and Edge's questions)
│   └── privacy-policy.md        publish it, then set listing.privacyPolicyUrl
└── review/
    └── reviewer-notes.md        Chrome test instructions · Edge notes for certification
```

## Where each thing goes

| File | Chrome Web Store (Developer Dashboard) | Edge Add-ons (Partner Center) |
| --- | --- | --- |
| manifest `name` / `description` | Title and summary - from the package | Name and short description - from the package |
| listing/…/description.txt | Store listing → Description | Store listings → Description (250-10,000 chars) |
| images/icon-128.png | Store listing → Store icon | - |
| images/logo-300.png | - | Store listings → Extension logo |
| images/promo-small-440x280.png | Store listing → Small promo tile | Store listings → Small promotional tile |
| images/promo-marquee-1400x560.png | Store listing → Marquee promo tile | Store listings → Large promotional tile |
| images/screenshots/ | Store listing → Screenshots (up to 5) | Store listings → Screenshots (up to 6) |
| listing/…/search-terms.txt | - | Store listings → Search terms |
| privacy/single-purpose.md | Privacy → Single purpose | Privacy → Purpose |
| privacy/permissions.md | Privacy → Permission justification | Privacy → Permission justifications |
| privacy/data-usage.md | Privacy → Data usage | Privacy → Data usage certification |
| store.json listing.privacyPolicyUrl | Privacy → Privacy policy URL | Privacy → Privacy policy |
| review/reviewer-notes.md | Package → Test instructions | Availability → Notes for certification |

Anything still reading **TODO** counts as missing, so a half-written listing can't be published.

## Publishing

```powershell
# from the toolkit, or via the pipeline
./Publish-Extension.ps1 -ProjectPath <this repo>                     # build, zip, check
./Publish-Extension.ps1 -ProjectPath <this repo> -Mode Publish      # …and submit to both stores
```

The first version of each store item is uploaded by hand; the APIs only update existing items.
