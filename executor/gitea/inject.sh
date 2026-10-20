#!/usr/bin/env bash
# inject.sh — turn a raw `guix system image -t docker` tarball into a
# fully-injected GuixSD executor image, tagged localhost/guix:latest.
#
# WHY THIS EXISTS: `guix system image -t docker` never boots the OS, so every
# activation-time artifact is missing from the image — /bin and /lib64 (created
# by special-files at activation), /run/current-system, /root (home dir), and the
# WHOLE /etc (etc-service-type writes it at activation: passwd, group,
# nsswitch.conf, hosts, CA bundle, /etc/services). A GitHub runner starts the
# container with `--entrypoint tail`, so activation never runs and those gaps are
# exactly what killed every early bootstrap run (UID-0 lookup → SSL error, the
# clone(2) EPERM chain, getaddrinfo "https" → EAI_SERVICE, missing CA/gnutls).
# The fix is to materialise all of it at build time via podman run+exec+commit.
#
# This is the SINGLE SOURCE for that pipeline. BOTH stages call it:
#   - bootstrap-executor.yml    runs on the runner HOST: PODMAN=podman
#   - build-executor-guixsd.yml runs INSIDE the executor image (regular path):
#     PODMAN=/run/current-system/profile/bin/podman
# Keeping it in one file is what makes the bootstrap faithful: stage 2 cannot
# produce a different (or broken/uninjected) image than stage 1 did, because it
# runs the identical script against the identical config.
#
# INPUTS (written by the caller, produced identically by both workflows):
#   /tmp/executor.tar.gz      raw `guix system image -t docker` tarball
#   /tmp/special-files.tsv     extracted from config.scm (target<TAB>pkg<TAB>suffix)
# OUTPUT:
#   localhost/guix:latest     injected image (in the caller's podman storage)
#
# Environment:
#   PODMAN   path to the podman binary (default: podman on PATH)
#
# Discipline notes (learned the hard way — do not "tidy" these away):
#   * Store paths are resolved from the IMAGE's own layer listing, NEVER from the
#     host `guix build`: the host guix revision may differ from the time-machine
#     pin, so host paths could be dangling inside the image.
#   * The inject container's entrypoint is the store ABSOLUTE path to tail
#     ($CU_DIR/bin/tail) because /bin is still empty at that point. After the
#     first commit, /bin/tail exists, so the /etc container uses bare `tail`.
#   * /etc/hosts, /etc/resolv.conf, /etc/hostname are runtime bind-mounts; writing
#     them through `cat >` (not podman cp) avoids unlinkat "device or resource busy".
#   * passwd/group/nsswitch.conf/services/CA are real files written through cat,
#     asserted by CONTENT (grep -c BEGIN CERTIFICATE, wc -l), not existence.
# NOTE: deliberately `set -eu`, NOT pipefail. The SP/SPG resolvers do
# `tar -tf … | grep -m1 …` — `grep -m1` closes the pipe the instant it matches,
# so tar dies on SIGPIPE (141). Under pipefail that 141 makes the whole pipeline
# look failed and the `|| FATAL` fires on a SUCCESSFUL match (caught locally:
# inject.sh aborted with "coreutils/tail not in image store" while the same
# grep succeeds in a plain shell). Stage 1's original inline ran under GH's
# default `sh -e` (no pipefail), so matching that here is the correct semantic.
set -eu

PODMAN="${PODMAN:-podman}"
TARBALL=/tmp/executor.tar.gz
TSV=/tmp/special-files.tsv
[ -f "$TARBALL" ] || { echo "FATAL: $TARBALL missing" >&2; exit 1; }
[ -f "$TSV" ]     || { echo "FATAL: $TSV missing (run the Extract step first)" >&2; exit 1; }

echo "=== inject.sh: load raw image ==="
# These /etc/containers files matter only in the NESTED case — stage 2, where
# podman runs inside the GuixSD container as root and the image has no
# /etc/containers (activation never runs). There, missing policy.json breaks
# `podman load` ("no policy.json file found") and overlay-on-overlayfs breaks
# the storage driver. On the stage-1 HOST the runner is unprivileged and the
# system podman already works with its defaults; writing there fails with EACCES
# (run 39395042104). So provision only when we are root, and otherwise leave the
# host config untouched.
if [ "$(id -u)" = "0" ]; then
  if [ ! -f /etc/containers/policy.json ]; then
    mkdir -p /etc/containers
    printf '%s\n' '{ "default": [{"type": "insecureAcceptAnything"}], "transports": {"docker": {"*": [{"type": "insecureAcceptAnything"}]}, "docker-daemon": {"*": [{"type": "insecureAcceptAnything"}]}} }' > /etc/containers/policy.json
    echo "wrote /etc/containers/policy.json (insecureAcceptAnything)"
  else
    echo "/etc/containers/policy.json already present"
  fi
  # vfs has no mount_program dependency and works on any backing filesystem; it
  # copies full layers (heavier on disk) which is fine for one ~3 GB image.
  if [ ! -f /etc/containers/storage.conf ]; then
    mkdir -p /etc/containers
    printf '%s\n' '[storage]' 'driver = "vfs"' 'runroot = "/run/containers/storage"' 'graphroot = "/var/lib/containers/storage"' > /etc/containers/storage.conf
    echo "wrote /etc/containers/storage.conf (driver=vfs)"
  else
    echo "/etc/containers/storage.conf already present: $(grep -m1 driver /etc/containers/storage.conf 2>/dev/null || echo 'no driver line')"
  fi
else
  echo "not root (host build) — keeping the system podman policy/storage"
fi
"$PODMAN" load < "$TARBALL"

# 1. Resolve store paths from the image layer (guaranteed to exist inside the image).
LAYER=$(tar -tf "$TARBALL" | grep 'layer.tar$' | head -1)
tar -xOf "$TARBALL" "$LAYER" > /tmp/layer.tar

SP() {  # SP <pkg-glob> <bin-tool> -> /gnu/store/<hash>-<pkg>/bin/<tool>
  tar -tf /tmp/layer.tar | grep -m1 -E "gnu/store/[^/]*$1[^/]*/bin/$2$" \
    | sed 's|^gnu/store|/gnu/store|' \
    || { echo "FATAL: $1/$2 not in image store" >&2; exit 1; }
}
SP_CORE=$(SP 'coreutils' 'tail')
CU_BIN=$(dirname "$SP_CORE")
CU_DIR=$(dirname "$CU_BIN")        # /bin/tail -> /bin -> package root
# glibc ld-linux lives under lib/ not bin/ — SP's hardcoded /bin/ does not apply.
GL_PATH=$(tar -tf /tmp/layer.tar | grep -m1 -E 'gnu/store/[^/]*glibc-2[^/]*/lib/ld-linux-x86-64\.so\.2$' \
  | sed 's|^gnu/store|/gnu/store|') \
  || { echo "FATAL: glibc ld-linux not in image store" >&2; exit 1; }
GL_DIR=$(dirname "$(dirname "$GL_PATH")")
CL=$(tar -tf /tmp/layer.tar | grep -m1 -E 'gnu/store/[^/]*gcc-[0-9][^/]*/lib/libstdc\+\+\.so\.6' \
  | sed 's|^gnu/store|/gnu/store|') \
  || { echo "FATAL: libstdc++ not in image store" >&2; exit 1; }
CL_DIR=$(dirname "$(dirname "$CL")")
# OS profile (bin/{guix,python3,git,bash,node}) — the /run/current-system target.
SYS=$(tar -tf /tmp/layer.tar | grep -m1 -E 'gnu/store/[^/]+-profile/bin/guix$' \
  | sed -E 's|gnu/store/([^/]+)/bin/guix$|gnu/store/\1|' \
  | sed 's|^gnu/store|/gnu/store|') \
  || { echo "FATAL: OS profile (bin/guix) not in image store" >&2; exit 1; }
[ -n "$CU_DIR" ] && [ -n "$GL_DIR" ] && [ -n "$CL_DIR" ] && [ -n "$SYS" ] \
  || { echo "FATAL: path resolution failed (CU_DIR='$CU_DIR' GL_DIR='$GL_DIR' CL_DIR='$CL_DIR' SYS='$SYS')"; exit 1; }

# 2. Start the inject container with the store-absolute tail (bypasses empty /bin).
echo "entrypoint tail: $CU_DIR/bin/tail"
"$PODMAN" rm -f inject 2>/dev/null || true
"$PODMAN" run -d --name inject --entrypoint "$CU_DIR/bin/tail" localhost/guix:latest -f /dev/null
sleep 2
CID=$("$PODMAN" inspect --format '{{.State.Pid}}' inject)
[ "$CID" != "0" ] && [ -n "$CID" ] || { echo "FATAL: inject container not running"; "$PODMAN" logs inject; exit 1; }
MK="$CU_DIR/bin/mkdir"; LN="$CU_DIR/bin/ln"
"$PODMAN" exec inject "$MK" -p /bin /lib64

# 3. special-files from config.scm — SINGLE SOURCE. target<TAB>pkg<TAB>suffix.
SPG() {  # SPG <pkg-glob> <rel-path> -> /gnu/store/<hash>-<pkg>/<rel>
  tar -tf /tmp/layer.tar | grep -m1 -E "gnu/store/[^/]*$1[^/]*/$2$" \
    | sed 's|^gnu/store|/gnu/store|' \
    || { echo "FATAL: $1/$2 not in image store" >&2; return 1; }
}
LINKED=0
while IFS="$(printf '\t')" read -r target pkg suffix; do
  case "$target" in ''|'#'*) continue ;; esac
  rel="${suffix#/}"
  store=$(SPG "${pkg}-" "$rel" 2>/dev/null) || store=$(SPG "${pkg}" "$rel")
  [ -n "$store" ] || { echo "FATAL: no store item for $target ($pkg/$rel)" >&2; exit 1; }
  tdir=$(dirname "$target")
  [ "$tdir" = "/bin" ] || "$PODMAN" exec inject "$MK" -p "$tdir"
  "$PODMAN" exec inject "$LN" -sf "$store" "$target"
  LINKED=$((LINKED + 1))
done < "$TSV"
[ "$LINKED" -ge 30 ] || { echo "FATAL: linked only $LINKED special-files (expected 35)" >&2; exit 1; }
echo "special-files linked: $LINKED"

# 4. /lib64/ld-linux + libstdc++/libgcc_s (ELF interp + loader search path).
"$PODMAN" exec inject "$LN" -sf "$GL_DIR/lib/ld-linux-x86-64.so.2" /lib64/ld-linux-x86-64.so.2
"$PODMAN" exec inject "$LN" -sf "$CL_DIR/lib/libstdc++.so.6" /lib64/libstdc++.so.6
"$PODMAN" exec inject "$LN" -sf "$CL_DIR/lib/libgcc_s.so.1" /lib64/libgcc_s.so.1

# 5. /run/current-system/profile -> OS profile (bootstrap's 13 dependencies).
"$PODMAN" exec inject "$MK" -p /run/current-system
"$PODMAN" exec inject "$LN" -s "$SYS" /run/current-system/profile
echo "run/current-system/profile -> $SYS"

# 6. /root — root's home (activation-time make-home-directory gap).
"$PODMAN" exec inject "$MK" -p /root
echo "/root created (root home)"

# 7. commit + LD_LIBRARY_PATH (Guix loader searches store lib/, not /lib64).
"$PODMAN" commit --change "ENV LD_LIBRARY_PATH=$CL_DIR/lib" inject localhost/guix:latest
"$PODMAN" rm -f inject
echo "=== injected: $(tar -tf /tmp/layer.tar | grep -c 'gnu/store') store items available ==="

# ── /etc injection (activation-time etc-service-type) ──
# Now /bin/tail exists (from the commit above) so the container uses bare `tail`.
echo "=== /etc injection ==="
"$PODMAN" rm -f etc-inject 2>/dev/null || true
"$PODMAN" run -d --name etc-inject --entrypoint tail localhost/guix:latest -f /dev/null
sleep 2
RUN=$("$PODMAN" inspect --format '{{.State.Running}}' etc-inject 2>/dev/null || echo dead)
[ "$RUN" = "true" ] || { echo "FATAL: etc-inject container not running"; "$PODMAN" logs etc-inject; exit 1; }
"$PODMAN" exec etc-inject "$MK" -p /etc /etc/ssl/certs

# Build users: guixbuilder01-10 + group guixbuild. uids 441..432 / gid 441 copied
# verbatim from a working stage-1 host. Without them the hand-started bootstrap
# daemon runs builds as root and chowns store entries to uids that don't exist,
# surfacing as the clone(2) EPERM chain.
printf '%b' 'root:x:0:0:root:/root:/bin/bash\nnobody:x:65534:65534:nobody:/var/empty:/usr/sbin/nologin\nguixbuilder01:x:441:441:Guix build user 01:/var/empty:/usr/sbin/nologin\nguixbuilder02:x:440:441:Guix build user 02:/var/empty:/usr/sbin/nologin\nguixbuilder03:x:439:441:Guix build user 03:/var/empty:/usr/sbin/nologin\nguixbuilder04:x:438:441:Guix build user 04:/var/empty:/usr/sbin/nologin\nguixbuilder05:x:437:441:Guix build user 05:/var/empty:/usr/sbin/nologin\nguixbuilder06:x:436:441:Guix build user 06:/var/empty:/usr/sbin/nologin\nguixbuilder07:x:435:441:Guix build user 07:/var/empty:/usr/sbin/nologin\nguixbuilder08:x:434:441:Guix build user 08:/var/empty:/usr/sbin/nologin\nguixbuilder09:x:433:441:Guix build user 09:/var/empty:/usr/sbin/nologin\nguixbuilder10:x:432:441:Guix build user 10:/var/empty:/usr/sbin/nologin\n' > /tmp/etc-passwd
printf '%b' 'root:x:0:\nnogroup:x:65534:\nguixbuild:x:441:guixbuilder01,guixbuilder02,guixbuilder03,guixbuilder04,guixbuilder05,guixbuilder06,guixbuilder07,guixbuilder08,guixbuilder09,guixbuilder10\n' > /tmp/etc-group
printf '%b' 'passwd: files\ngroup: files\nhosts: files dns\n' > /tmp/etc-nsswitch.conf
printf '%b' '127.0.0.1 localhost\n::1       localhost ip6-localhost ip6-loopback\n' > /tmp/etc-hosts

for f in passwd group nsswitch.conf; do
  "$PODMAN" exec -i etc-inject /bin/sh -c "cat > /etc/$f" < "/tmp/etc-$f"
done
rm -f /tmp/etc-*

# CA bundle (a separate store item; nss-certs ships individual certs but no merged file).
BUNDLE=$(tar -tf /tmp/layer.tar | grep -m1 -E 'gnu/store/[^/]*-ca-certificate-bundle/etc/ssl/certs/ca-certificates\.crt$' \
  | sed 's|^gnu/store|/gnu/store|') \
  || { echo "FATAL: CA bundle not in image store" >&2; exit 1; }
[ -n "$BUNDLE" ] || { echo "FATAL: CA bundle resolution empty" >&2; exit 1; }
"$PODMAN" exec -i etc-inject /bin/sh -c 'cat > /etc/ssl/certs/ca-certificates.crt' < "$BUNDLE"
"$PODMAN" exec etc-inject /bin/sh -c '[ "$(grep -c "BEGIN CERTIFICATE" /etc/ssl/certs/ca-certificates.crt)" -gt 100 ]' \
  || { echo "FATAL: CA bundle incomplete"; "$PODMAN" exec etc-inject /bin/sh -c 'wc -c /etc/ssl/certs/ca-certificates.crt' 2>&1; "$PODMAN" rm -f etc-inject; exit 1; }
echo "CA bundle injected: $("$PODMAN" exec etc-inject /bin/sh -c 'grep -c "BEGIN CERTIFICATE" /etc/ssl/certs/ca-certificates.crt') certs"

# /etc/services — glibc getaddrinfo() needs it to map "https" -> 443 (EAI_SERVICE
# otherwise on every substitute source). Source: net-base, already in the closure.
SERVICES=$(tar -tf /tmp/layer.tar | grep -m1 -E 'gnu/store/[^/]*/etc/services$' \
  | sed 's|^gnu/store|/gnu/store|') \
  || { echo "FATAL: /etc/services not in image store" >&2; exit 1; }
[ -n "$SERVICES" ] || { echo "FATAL: SERVICES resolution empty" >&2; exit 1; }
"$PODMAN" exec -i etc-inject /bin/sh -c 'cat > /etc/services' < "$SERVICES"
"$PODMAN" exec etc-inject /bin/sh -c '[ "$(wc -l < /etc/services)" -gt 100 ]' \
  || { echo "FATAL: /etc/services incomplete"; "$PODMAN" exec etc-inject /bin/sh -c 'wc -l /etc/services' 2>&1; "$PODMAN" rm -f etc-inject; exit 1; }
echo "/etc/services injected: $("$PODMAN" exec etc-inject /bin/sh -c 'wc -l < /etc/services') lines"

# assert root line + nsswitch + hosts
"$PODMAN" exec etc-inject /bin/sh -c 'grep -q "^root:x:0:0:" /etc/passwd' \
  && "$PODMAN" exec etc-inject /bin/sh -c 'grep -q "^guixbuilder01:x:441:441:" /etc/passwd' \
  && "$PODMAN" exec etc-inject /bin/sh -c 'grep -q "^passwd: files" /etc/nsswitch.conf' \
  && "$PODMAN" exec etc-inject /bin/sh -c 'grep -q "localhost" /etc/hosts' \
  && echo "etc files injected: OK" \
  || { echo "FATAL: /etc injection failed"; "$PODMAN" exec etc-inject /bin/cat /etc/passwd 2>&1 | head -5; "$PODMAN" rm -f etc-inject; exit 1; }

"$PODMAN" commit etc-inject localhost/guix:latest
"$PODMAN" rm -f etc-inject
echo "=== /etc injected into localhost/guix:latest ==="
echo "=== inject.sh DONE: localhost/guix:latest is fully injected ==="
