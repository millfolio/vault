# Homebrew distribution — `mill` CLI

The `mill` CLI ships as a **prebuilt, Developer-ID-signed universal binary**,
attached to each `millfolio/vault` GitHub Release as `mill-macos.tar.gz` by
the repo-root `.github/workflows/release.yml`.

## Installing (once the tap exists)

```sh
brew install millfolio/tap/mill
mill status
```

## Releasing a new version

1. Tag the repo (`git tag v0.1.0 && git push origin v0.1.0`). CI builds the
   signed universal `mill-macos.tar.gz` and attaches it to the Release. (The
   job log prints the tarball's sha256.)
2. Bump the formula to point at the new asset + checksum:

   ```sh
   cli/dist/homebrew/update-formula.sh v0.1.0
   ```

3. Publish the formula to the tap repo (`millfolio/homebrew-tap`) as
   `Formula/mill.rb`.

## Creating the tap (one-time)

A Homebrew tap is just a repo named `homebrew-<name>`:

```sh
gh repo create millfolio/homebrew-tap --public
git -C homebrew-tap add Formula/mill.rb
git -C homebrew-tap commit -m "mill 0.1.0" && git -C homebrew-tap push
```

`brew install millfolio/tap/mill` resolves `millfolio/homebrew-tap` →
`Formula/mill.rb`.

## Notes

- **Signing, not notarization.** A Developer-ID-signed CLI runs from the
  terminal without a Gatekeeper prompt, and Homebrew doesn't quarantine tap
  downloads, so notarization isn't required.
- **Shared state with millfolio.** `mill` installs into the same tree
  (`~/Library/Application Support/Millfolio`) and drives the same launchd job
  (`me.millfolio.server`) as the `millfolio` CLI — they interoperate on one
  inference server. `mill` adds headgate + the vault on top.
