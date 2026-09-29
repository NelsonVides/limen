# Releasing

The version is not written anywhere in the code: `mix.exs` takes it from the
latest `v*` tag with `git describe`. Between tags it reads like
`0.1.0-3-gab23453`, and with no tags at all it is `0.0.0-dev`.

Pushing a `vMAJOR.MINOR.PATCH` tag runs `.github/workflows/release.yml`, which
waits for CI on the tagged commit, publishes the package and its docs to Hex,
and creates a GitHub release with that version's changelog section as notes.
A tag with a pre-release suffix, such as `v0.2.0-rc.1`, makes a pre-release.

The workflow needs a `HEX_API_KEY` repository secret: a key generated on the
hex.pm dashboard, under Keys, with only the `limen` package permission, which
can publish releases and docs of this package and nothing else. That
permission only lists packages that exist, so the first release used a key
with the API write permission and a one-day expiry, replaced afterwards.

## Release process

`$VERSION` below is the version without the `v`, such as `0.2.0`.

1. In `CHANGELOG.md`, rename `## Unreleased` to `## $VERSION`. The release
   fails before publishing anything if this section is missing.

2. Commit and push:

    ```shell
    git commit -a -m "Release $VERSION"
    git push origin main
    ```

3. Create and push a signed tag:

    ```shell
    git tag -a v$VERSION -s -m "Release $VERSION"
    git push origin v$VERSION
    ```

## Publishing by hand

The workflow writes the tag to a `VERSION` file, which `mix.exs` prefers over
`git describe` and which ships in the package, because a Hex dependency has
no git history to ask. To publish without the workflow, do the same from the
tagged commit, and delete the file afterwards so it does not pin the version
of later builds:

```shell
echo $VERSION > VERSION
mix hex.publish
rm VERSION
```
