# Speak Duet support and privacy pages

Prepared locally for the Commerce build. The files are also in the public
[support repository](https://github.com/ahana-roy-builds/speak-duet-support),
with asset placement corrected in commit `52e9910`. GitHub Pages is published:

- Support: https://ahana-roy-builds.github.io/speak-duet-support/
- Privacy: https://ahana-roy-builds.github.io/speak-duet-support/privacy.html

Both pages, the stylesheet, and the icon were verified over public HTTPS and
match the corrected repository files. The live URLs are configured in Commerce.
It is a self-contained static site: `index.html` is support, `privacy.html` is
the policy, and `assets/` holds the existing app icon and shared CSS. No build
step, JavaScript, external fonts, analytics, or contact-form backend is required.

Preview from the repository root:

```sh
python3 -m http.server 8765 --bind 127.0.0.1 --directory distribution/speak-duet
```

Before public App Store release:

- Confirm the dedicated support email or private contact-form URL. Current
  pages use TestFlight's Send Beta Feedback as the beta contact route. Add the
  confirmed private support route before the public App Store release; do not
  publish personal email addresses, phone numbers, or private review contacts.
- Hosting is configured: GitHub Pages under Ahana's account, using
  `ahana-roy-builds/speak-duet-support`, branch `main`, folder `/(root)`.
  The policy includes GitHub's hosting disclosure and privacy-policy link.
  Do not reuse the original LocalLingo site's owner, URL, or no-accounts policy.
- Recheck the policy against the final Commerce archive's aggregated SDK
  privacy report and configured provider behavior. The pinned Google Sign-In
  SDK declares more data types than the app's own manifest; see the
  [TestFlight tracker](../../docs/speak-duet-testflight.md) for the inventory.
- Enter the verified support/privacy URLs into App Store Connect. The ignored
  Commerce override already contains them. Maintain public website files in
  the support repository and keep this app-side copy synchronized when edited.

The pages deliberately have no invented public hostname or contact address.
