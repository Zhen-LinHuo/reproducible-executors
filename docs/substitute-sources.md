# Guix substitute sources

The CI daemon and the `time-machine` layer consult the same ordered list, kept
identical in two places: the daemon drop-in / flags, and the `time-machine`
invocation. A private cache, when one is configured, arrives through the
`GUIX_CACHE_URL` secret and is placed second; when the secret is unset the entry
is simply absent, so the workflow carries no dependency on it.

## Order

```text
1. https://hydra-guix-129.guix.gnu.org                # official domain, mirrors bordeaux
2. https://bordeaux.guix.gnu.org                      # official build farm
3. https://ci.guix.gnu.org                            # official build farm
4. https://mirrors.sjtug.sjtu.edu.cn/guix-bordeaux    # SJTUG, mirrors bordeaux
5. https://mirrors.sjtug.sjtu.edu.cn/guix             # SJTUG, mirrors ci.guix
6. https://mirror.sjtu.edu.cn/guix                    # third-party mirror
7. ${GUIX_CACHE_URL}                                  # optional private cache (secret)
```

Bordeaux leads the farms because it is the most reliable public farm for a
freshly pinned revision. The nar service of ci.guix keeps working while its
search endpoint is returning 502. The SJTUG pair mirrors bordeaux and ci.guix
respectively — keep both.

## Official farms and mirrors

`bordeaux.guix.gnu.org` and `ci.guix.gnu.org` are the official build farms
(Guix manual §5.3.1). Volunteer mirrors do not build anything: they copy
substitutes from the official farms, and the nar signatures come from the
original builders, so a mirror cannot substitute different content (§5.3.2).

The current QA-built revision is published at `qa.guix.gnu.org/branch/master`.
narinfo lives at `<base>/<32-character-hash>.narinfo` — not under `/nar/`.

## Failure modes worth knowing

- `ci.guix` returns 502 intermittently on `/search` and its home page while its
  static nar endpoints keep serving. An installer that fetches a nightly tarball
  through that endpoint fails; installing the stable ftp.gnu.org tarball avoids
  it.
- bordeaux serves only revisions it has built. As QA moves forward, older
  revisions age out of the farm and must be built locally.
- `guix substitute: warning: ACL for archive imports seems to be uninitialized`
  means the client trusts no substitute and refuses every source even when the
  nar exists. Fix it with `guix archive --authorize` for each farm key plus a
  daemon signing keypair (`guix archive --generate-key`).
