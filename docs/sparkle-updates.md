# Private unsigned Sparkle updates

This project can ship personal macOS auto-updates through Sparkle without Apple Developer ID signing/notarization.

What this gives:

- Sparkle update checks in Release builds.
- EdDSA-signed update archives and appcast.
- DMG + `appcast.xml` published to GitHub Releases.

What this does **not** give:

- Developer ID code signing.
- Apple notarization.
- A no-warning first launch experience. Gatekeeper can still require right-click → Open.

## Update URL

Release builds use this stable appcast URL:

```text
https://github.com/slava-makeenko/whisp/releases/latest/download/appcast.xml
```

Each release also publishes the matching DMG and appcast as release assets.

## One-time Sparkle key setup

On macOS, download Sparkle tools and generate an EdDSA keypair:

```sh
curl -L -o Sparkle.tar.xz \
  https://github.com/sparkle-project/Sparkle/releases/download/2.9.2/Sparkle-2.9.2.tar.xz
tar -xf Sparkle.tar.xz
./bin/generate_keys
```

Add the generated values to GitHub Actions secrets:

- `SPARKLE_PUBLIC_ED_KEY` — public EdDSA key, embedded into the app's `Info.plist` at build time.
- `SPARKLE_PRIVATE_ED_KEY` — private EdDSA key, used only in GitHub Actions to sign the appcast.

Never commit the private key.

## Publishing an update

1. Commit the release changes.
2. Create and push a version tag:

```sh
git tag v0.1.1
git push origin v0.1.1
```

3. The `Release` workflow builds an unsigned DMG, generates `appcast.xml`, and publishes both to GitHub Releases.
4. Existing Release builds check the stable appcast URL and offer the update.

## Important release rules

- Do **not** compile Release updates with `LOCAL_BUILD`; `LOCAL_BUILD` disables `UpdaterController`.
- Keep `MARKETING_VERSION` increasing for every update.
- Keep `PRODUCT_BUNDLE_IDENTIFIER` stable (`com.slavamakeenko.whisp`) or Sparkle will treat the app as a different product.
- Because the appcast URL points to GitHub's `latest` release, Sparkle update releases should be normal releases, not GitHub prereleases.
