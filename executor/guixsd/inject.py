#!/usr/bin/env python3
"""Deterministic tar-level injection for the GuixSD executor image.

Turns the archive produced by `guix system image -t docker` into the runnable
executor image WITHOUT podman load/run/commit.

Why this exists
---------------
`guix system image -t docker` is itself reproducible: config.json carries
history.created = 1970-01-01T00:00:00Z, no Env, and every layer entry has
mtime = epoch. The previous pipeline then ran

    podman load && podman run/exec && podman commit

and podman commit is NOT reproducible: it stamps `created` with the wall clock,
merges Env in map order (LD_LIBRARY_PATH lands before or after PATH at random),
rewrites the layer with the commit time as mtime, and recompresses. That is why
every build produced a different digest and slightly different layer sizes.

This script does the same injection at the tar level and normalises everything:

  * entries are emitted sorted by name
  * mtime fixed to SOURCE_DATE_EPOCH (0 unless overridden)
  * uid/gid 0, uname/gname root, numeric owner
  * gzip written with mtime=0 and no embedded filename
  * config.json generated with a fixed `created` and a fixed Env order

Result: identical inputs -> byte-identical archive -> identical image digest.

The activations it performs are the same ones the old podman-based injector did:
/bin and /lib64 symlinks (from the special-files TSV), lib64/ld-linux and the
C++ runtime, /run/current-system/profile, /root, and the /etc files that the
Guix docker image never gets (activation does not run).
"""

from __future__ import annotations

import hashlib
import io
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile

EPOCH = int(os.environ.get("SOURCE_DATE_EPOCH", "0"))
FIXED_DATE = "1970-01-01T00:00:00Z"

PASSWD = (
    "root:x:0:0:root:/root:/bin/bash\n"
    "nobody:x:65534:65534:nobody:/var/empty:/usr/sbin/nologin\n"
    + "".join(
        "guixbuilder%02d:x:%d:441:Guix build user %02d:/var/empty:/usr/sbin/nologin\n"
        % (i, 442 - i, i)
        for i in range(1, 11)
    )
)
GROUP = (
    "root:x:0:\n"
    "nogroup:x:65534:\n"
    "guixbuild:x:441:"
    + ",".join("guixbuilder%02d" % i for i in range(1, 11))
    + "\n"
)
NSSWITCH = "passwd: files\ngroup: files\nhosts: files dns\n"
HOSTS = "127.0.0.1 localhost\n::1       localhost ip6-localhost ip6-loopback\n"
CONTAINERS_POLICY = (
    '{"default":[{"type":"insecureAcceptAnything"}],'
    '"transports":{"docker":{"*":[{"type":"insecureAcceptAnything"}]},'
    '"docker-daemon":{"*":[{"type":"insecureAcceptAnything"}]}}}\n'
)
STORAGE_CONF = (
    '[storage]\ndriver = "vfs"\nrunroot = "/run/containers/storage"\n'
    'graphroot = "/var/lib/containers/storage"\n'
)


def die(msg: str) -> None:
    print("FATAL: " + msg, file=sys.stderr)
    sys.exit(1)


def run(cmd, **kw):
    try:
        return subprocess.run(cmd, check=True, **kw)
    except subprocess.CalledProcessError as e:
        # Surface the child's stderr instead of dying with a bare traceback.
        err = e.stderr
        if isinstance(err, bytes):
            err = err.decode("utf-8", "replace")
        if err:
            print(err.strip(), file=sys.stderr)
        print("FATAL: command failed (%d): %s" % (e.returncode, " ".join(cmd)), file=sys.stderr)
        raise SystemExit(1)


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def read_tar_member(archive: str, member: str, dest: str) -> str:
    """Extract one member; returns the member name that actually matched."""
    with open(dest, "wb") as out:
        run(["tar", "-xOf", archive, member], stdout=out)
    return member


def outer_entries(archive: str) -> list[str]:
    """List the archive's top-level members."""
    return run(["tar", "-tf", archive], capture_output=True, text=True).stdout.splitlines()


def pick_member(entries: list[str], suffix: str) -> str:
    """Find a member by suffix. guix writes './manifest.json' while a plain
    docker save writes 'manifest.json' — matching by suffix covers both."""
    for e in entries:
        if e.rstrip("/").endswith(suffix):
            return e
    return None


def _stream(archive: str, member: str):
    """Start `tar -xOf <archive> <member>` and return the running process so the
    layer can be piped straight into another tar — no multi-GiB temp copy."""
    return subprocess.Popen(["tar", "-xOf", archive, member], stdout=subprocess.PIPE)


def list_layer(archive: str, member: str) -> list[str]:
    src = _stream(archive, member)
    try:
        out = subprocess.run(["tar", "-tf", "-"], stdin=src.stdout,
                             capture_output=True, text=True, check=True).stdout
    finally:
        src.stdout.close()
        src.wait()
    return out.splitlines()


def extract_layer(archive: str, member: str, root: str) -> None:
    src = _stream(archive, member)
    try:
        run(["tar", "-xf", "-", "-C", root, "--numeric-owner"], stdin=src.stdout)
    finally:
        src.stdout.close()
        src.wait()


def resolve(store_paths: list[str], pkg: str, rel: str) -> str | None:
    """Find gnu/store/<hash>-<pkg>-<ver>/<rel> in the layer listing."""
    want_suffix = "/" + rel
    for p in store_paths:
        if not p.startswith("gnu/store/"):
            continue
        rest = p[len("gnu/store/"):]
        if "/" not in rest:
            continue
        item = rest.split("/", 1)[0]
        if pkg not in item:
            continue
        if p.endswith(want_suffix) or p == "gnu/store/" + item:
            if p.endswith(want_suffix):
                return "/" + p
    return None


def store_item_for(store_paths: list[str], pkg: str, rel: str) -> str:
    """Return the absolute store path of <pkg>/<rel> inside the image."""
    hit = resolve(store_paths, pkg, rel)
    if hit is None:
        # fall back: match "…-<pkg>-…/" + rel exactly, preferring -pkg- over pkg
        cands = [
            "/" + p for p in store_paths
            if p.startswith("gnu/store/") and p.endswith("/" + rel) and pkg in p.split("/")[1]
        ]
        if not cands:
            die("no store item for %s/%s" % (pkg, rel))
        cands.sort(key=len)
        hit = cands[0]
    return hit


def write_file(path: str, data: str, mode: int = 0o644) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(data)
    os.chmod(path, mode)


def ensure_dir(path: str) -> None:
    """Make path a real directory. The guix image ships /bin as a SYMLINK into
    the store; writing through it would mutate the store and is wrong."""
    if os.path.islink(path):
        os.remove(path)
    elif os.path.exists(path) and not os.path.isdir(path):
        os.remove(path)
    os.makedirs(path, exist_ok=True)


def symlink(target: str, path: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if os.path.islink(path) or os.path.exists(path):
        os.remove(path)
    os.symlink(target, path)


def emit_runtime_config(target_dir: str) -> None:
    """Write the podman runtime config the BUILD HOST needs to load the image.

    The image itself carries these files (written below), but the container
    running the build is the previous image, which may predate them. Same
    constants, so there is still one source for the contents.
    """
    os.makedirs(target_dir, exist_ok=True)
    for name, body in (("policy.json", CONTAINERS_POLICY),
                       ("storage.conf", STORAGE_CONF)):
        path = os.path.join(target_dir, name)
        if os.path.exists(path):
            print("  keep existing %s" % path)
            continue
        with open(path, "w") as f:
            f.write(body)
        print("  wrote %s" % path)


def main() -> None:
    if len(sys.argv) >= 3 and sys.argv[1] == "--emit-runtime-config":
        emit_runtime_config(sys.argv[2])
        return
    if len(sys.argv) < 3:
        die("usage: inject.py <raw-image.tar[.gz]> <out.tar> [special-files.tsv]")
    src, out = sys.argv[1], sys.argv[2]
    tsv = sys.argv[3] if len(sys.argv) > 3 else "/tmp/special-files.tsv"
    if not os.path.isfile(src):
        die("missing input archive: " + src)
    if not os.path.isfile(tsv):
        die("missing special-files TSV: " + tsv)

    work = tempfile.mkdtemp(prefix="inject-")
    root = os.path.join(work, "root")
    os.makedirs(root)

    print("=== inject.py: unpack %s ===" % src)
    entries = outer_entries(src)
    man_member = pick_member(entries, "manifest.json")
    cfg_member = pick_member(entries, "config.json")
    if man_member is None or cfg_member is None:
        die("no manifest.json/config.json in %s (entries: %s)" % (src, entries[:6]))
    print("  manifest: %s" % man_member)
    manifest = json.loads(
        run(["tar", "-xOf", src, man_member], capture_output=True, text=True).stdout
    )
    layer_member = manifest[0]["Layers"][0]
    if layer_member not in entries:
        # manifest paths may omit the './' the tar actually carries
        alt = [e for e in entries if e.rstrip("/").endswith(layer_member.lstrip("./"))]
        if not alt:
            die("layer %r not in archive" % layer_member)
        layer_member = alt[0]
    cfg_path = os.path.join(work, "config.json")
    read_tar_member(src, cfg_member, cfg_path)

    listing = list_layer(src, layer_member)
    print("  layer entries: %d" % len(listing))

    # Extract straight out of the archive. Ownership is normalised when we
    # re-pack, so the user we run as does not matter.
    extract_layer(src, layer_member, root)

    # ---- injections -------------------------------------------------------
    cu_tail = store_item_for(listing, "coreutils", "bin/tail")
    cu_dir = os.path.dirname(os.path.dirname(cu_tail))
    ld = store_item_for(listing, "glibc-2", "lib/ld-linux-x86-64.so.2")
    glibc_dir = os.path.dirname(os.path.dirname(ld))
    stdcpp = store_item_for(listing, "gcc-", "lib/libstdc++.so.6")
    gcc_dir = os.path.dirname(os.path.dirname(stdcpp))
    sys_profile = store_item_for(listing, "profile", "bin/guix")
    profile_dir = os.path.dirname(os.path.dirname(sys_profile))
    bundle = store_item_for(listing, "ca-certificate-bundle", "etc/ssl/certs/ca-certificates.crt")
    services = store_item_for(listing, "net-base", "etc/services")

    ensure_dir(os.path.join(root, "bin"))
    ensure_dir(os.path.join(root, "lib64"))

    linked = 0
    with open(tsv) as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            target, pkg, suffix = line.split("\t")
            rel = suffix.lstrip("/")
            store = store_item_for(listing, pkg, rel)
            dest = os.path.join(root, target.lstrip("/"))
            symlink(store, dest)
            linked += 1
    if linked < 30:
        die("linked only %d special files" % linked)
    print("  special files linked: %d" % linked)

    symlink(os.path.join(glibc_dir, "lib/ld-linux-x86-64.so.2"), os.path.join(root, "lib64/ld-linux-x86-64.so.2"))
    symlink(os.path.join(gcc_dir, "lib/libstdc++.so.6"), os.path.join(root, "lib64/libstdc++.so.6"))
    symlink(os.path.join(gcc_dir, "lib/libgcc_s.so.1"), os.path.join(root, "lib64/libgcc_s.so.1"))

    ensure_dir(os.path.join(root, "run/current-system"))
    symlink(profile_dir, os.path.join(root, "run/current-system/profile"))
    ensure_dir(os.path.join(root, "root"))

    write_file(os.path.join(root, "etc/passwd"), PASSWD)
    write_file(os.path.join(root, "etc/group"), GROUP)
    write_file(os.path.join(root, "etc/nsswitch.conf"), NSSWITCH)
    write_file(os.path.join(root, "etc/hosts"), HOSTS)
    write_file(os.path.join(root, "etc/containers/policy.json"), CONTAINERS_POLICY)
    write_file(os.path.join(root, "etc/containers/storage.conf"), STORAGE_CONF)
    ensure_dir(os.path.join(root, "etc/ssl/certs"))
    # These store paths were resolved from the LAYER listing, so read the files
    # from the extracted tree (root/) — not from the host's /gnu/store.
    shutil.copyfile(os.path.join(root, bundle.lstrip("/")),
                    os.path.join(root, "etc/ssl/certs/ca-certificates.crt"))
    os.chmod(os.path.join(root, "etc/ssl/certs/ca-certificates.crt"), 0o644)
    shutil.copyfile(os.path.join(root, services.lstrip("/")),
                    os.path.join(root, "etc/services"))
    os.chmod(os.path.join(root, "etc/services"), 0o644)
    print("  /etc, /run/current-system, /root written")

    # ---- deterministic re-pack -------------------------------------------
    print("=== deterministic re-pack (mtime=@%d, sorted, numeric owner) ===" % EPOCH)
    new_layer = os.path.join(work, "layer.new.tar")
    run([
        "tar", "-C", root, "-cf", new_layer,
        "--sort=name", "--mtime=@%d" % EPOCH,
        "--owner=0", "--group=0", "--numeric-owner",
        "--format=gnu", ".",
    ])
    layer_dir_sha = sha256_file(new_layer)
    # Free the extracted tree before writing the archive — peak disk matters on
    # CI runners.
    shutil.rmtree(root, ignore_errors=True)

    cfg = json.load(open(cfg_path))
    cfg["created"] = FIXED_DATE
    cfg["config"] = {
        "Env": [
            "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            "container=podman",
            "LD_LIBRARY_PATH=%s/lib" % gcc_dir,
        ],
        "Entrypoint": ["/run/current-system/profile/bin/tail"],
        "Cmd": ["-f", "/dev/null"],
    }
    cfg["history"] = [{"created": FIXED_DATE}]
    cfg["rootfs"] = {"type": "layers", "diff_ids": ["sha256:" + layer_dir_sha]}
    cfg_bytes = json.dumps(cfg, sort_keys=True, separators=(",", ":")).encode() + b"\n"

    layer_id = layer_dir_sha
    man = [{
        "Config": "config.json",
        "RepoTags": ["localhost/guix:latest"],
        "Layers": ["%s/layer.tar" % layer_id],
    }]
    man_bytes = json.dumps(man, separators=(",", ":")).encode() + b"\n"

    print("=== writing %s ===" % out)
    staging = os.path.join(work, "stage")
    os.makedirs(os.path.join(staging, layer_id))
    # Store the layer UNCOMPRESSED, like guix's own archive, so docker/podman
    # load it without relying on gzip detection.
    shutil.move(new_layer, os.path.join(staging, layer_id, "layer.tar"))
    with open(os.path.join(staging, "manifest.json"), "wb") as f:
        f.write(man_bytes)
    with open(os.path.join(staging, "config.json"), "wb") as f:
        f.write(cfg_bytes)
    run([
        "tar", "-C", staging, "-cf", out,
        "--sort=name", "--mtime=@%d" % EPOCH,
        "--owner=0", "--group=0", "--numeric-owner",
        "--format=gnu", ".",
    ])
    print("  layer=sha256:%s size=%d" % (layer_dir_sha, os.path.getsize(os.path.join(staging, layer_id, "layer.tar"))))
    print("  archive=%s size=%d sha256=%s" % (out, os.path.getsize(out), sha256_file(out)))

    shutil.rmtree(work, ignore_errors=True)
    print("=== inject.py DONE ===")


if __name__ == "__main__":
    main()
