#!/usr/bin/env bash
# Execute exclusively in the named, public, disposable GitHub-hosted VM.
set -euo pipefail
test "${GITHUB_ACTIONS:-}" = true
test "${RUNNER_ENVIRONMENT:-}" = github-hosted
test "${RUNNER_OS:-}" = Linux
test "${RUNNER_ARCH:-}" = X64
test "${GITHUB_RUN_ATTEMPT:-}" = 1
test "${GITHUB_REPOSITORY#*/}" = crimson-cp-provenance-builder
test "$(uname -m)" = x86_64
umask 077
TASK_DIR=$(mktemp -d "${RUNNER_TEMP}/cp-build.XXXXXXXX")
ARTIFACTS="${GITHUB_WORKSPACE}/artifacts"
mkdir -p "$ARTIFACTS" "$TASK_DIR/inputs" "$TASK_DIR/bin"
export ARTIFACTS TASK_DIR
SOURCE_COMMIT=b3187ae53a1b95a201f855a59024a12ca8f5b51a
SOURCE_ARCHIVE_SHA=be3bf9662b56425d7ae3dbbc487bcb2f703aa298a914173afc66edbcf1f1112a
SOURCE_TREE=1de2d7ad967775748ef6917209ec777ded753c33
LOCK_SHA=9fd6ae76c394140ed7f2840b29ee4af0fbd857bc8bd7099fc6c35adbd6b1e183
VERIFIER_COMMIT=8470dd1fe5dd93209bbfdacaebe444349affe71b
BUILDER_IMAGE=solanafoundation/solana-verifiable-build@sha256:f71be5ca7620b7e40933b7f1294fa44e01d08c1fc5ba1f375a2478f5a01580d3
DOCKER_REAL=$(command -v docker)
export SOURCE_COMMIT SOURCE_TREE LOCK_SHA VERIFIER_COMMIT BUILDER_IMAGE DOCKER_REAL
export SVB_DOCKER_MEMORY_LIMIT=10g SVB_DOCKER_CPU_LIMIT=2
BUILD_COMPLETE=false
STAGE=initialization
PREFETCH_CONTAINER=''
cleanup() {
  code=$?
  trap - EXIT
  if [ -n "$PREFETCH_CONTAINER" ]; then "$DOCKER_REAL" rm -f "$PREFETCH_CONTAINER" >/dev/null 2>&1 || true; fi
  # This dedicated VM belongs only to this one job; record and stop build containers.
  "$DOCKER_REAL" ps -a --no-trunc --format '{{json .}}' > "$ARTIFACTS/containers-before-disposal.jsonl" || true
  ids=$("$DOCKER_REAL" ps -aq)
  if [ -n "$ids" ]; then "$DOCKER_REAL" rm -f $ids >/dev/null 2>&1 || true; fi
  "$DOCKER_REAL" ps -a --no-trunc --format '{{json .}}' > "$ARTIFACTS/containers-after-disposal.jsonl" || true
  if [ "$BUILD_COMPLETE" != true ]; then
    printf '{"result":"REPRODUCIBLE_BUILD_NOT_ACHIEVED","exitCode":%s,"stage":"%s","financialAuthority":false}\n' "$code" "$STAGE" > "$ARTIFACTS/RESULT.json"
  fi
  (cd "$ARTIFACTS" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS) || true
  exit "$code"
}
trap cleanup EXIT
exec > >(tee -a "$ARTIFACTS/orchestration.log") 2>&1
printf 'STARTED %s\n' "$(date -u +%FT%TZ)"
printf 'workflow=%s run=%s attempt=%s image=%s runnerOS=%s architecture=%s\n' "$GITHUB_SHA" "$GITHUB_RUN_ID" "$GITHUB_RUN_ATTEMPT" "${ImageVersion:-unknown}" "$RUNNER_OS" "$RUNNER_ARCH"
# Public, unauthenticated source input. No checkout credential or personal secret.
curl --fail --silent --show-error --max-time 120 --proto '=https' --tlsv1.2 \
  "https://codeload.github.com/raydium-io/raydium-cp-swap/tar.gz/$SOURCE_COMMIT" -o "$TASK_DIR/inputs/source.tar.gz"
printf '%s  %s\n' "$SOURCE_ARCHIVE_SHA" "$TASK_DIR/inputs/source.tar.gz" | sha256sum --check
python3 - <<'PY'
import os,tarfile,pathlib,hashlib,json
base=pathlib.Path(os.environ['TASK_DIR']); source=base/'source';source.mkdir()
with tarfile.open(base/'inputs/source.tar.gz','r:gz') as tar:
    entries=tar.getmembers()
    for x in entries:
        p=pathlib.PurePosixPath(x.name)
        assert not p.is_absolute() and '..' not in p.parts and (x.isdir() or x.isfile())
        assert p.parts[0]=='raydium-cp-swap-'+os.environ['SOURCE_COMMIT']
        target=source.joinpath(*p.parts[1:])
        if x.isdir():target.mkdir(parents=True,exist_ok=True)
        else:
            target.parent.mkdir(parents=True,exist_ok=True); target.write_bytes(tar.extractfile(x).read());target.chmod(x.mode&0o777)
files={str(p.relative_to(source)):hashlib.sha256(p.read_bytes()).hexdigest() for p in source.rglob('*') if p.is_file()}
assert len(files)==76 and files['Cargo.lock']==os.environ['LOCK_SHA']
pathlib.Path(os.environ['ARTIFACTS'],'source-manifest.json').write_text(json.dumps(files,indent=2))
PY
# Reconstruct Git identity without running hooks, source scripts or dependency builds.
git -C "$TASK_DIR/source" -c core.hooksPath=/dev/null init -q
git -C "$TASK_DIR/source" -c core.hooksPath=/dev/null add --force -- .
test "$(git -C "$TASK_DIR/source" write-tree)" = "$SOURCE_TREE"
# Fetch only the already selected public commit, without changing extracted files.
git -C "$TASK_DIR/source" -c core.hooksPath=/dev/null fetch --no-tags --depth=1 https://github.com/raydium-io/raydium-cp-swap "$SOURCE_COMMIT"
test "$(git -C "$TASK_DIR/source" rev-parse FETCH_HEAD)" = "$SOURCE_COMMIT"
test "$(git -C "$TASK_DIR/source" rev-parse 'FETCH_HEAD^{tree}')" = "$SOURCE_TREE"
git -C "$TASK_DIR/source" update-ref HEAD "$SOURCE_COMMIT"
test -z "$(git -C "$TASK_DIR/source" status --porcelain)"
printf '%s\n' "$SOURCE_COMMIT" "$SOURCE_TREE" "$SOURCE_ARCHIVE_SHA" > "$ARTIFACTS/source-identity.txt"
cp "$TASK_DIR/source/Cargo.lock" "$ARTIFACTS/Cargo.lock"
cp "$TASK_DIR/source/Cargo.toml" "$ARTIFACTS/Cargo.toml"
cp "$TASK_DIR/source/Anchor.toml" "$ARTIFACTS/Anchor.toml"
# Only the build CLI is installed on the disposable runner, never on CRIMSON.
STAGE=verifier_install
rustup toolchain install 1.91.0 --profile minimal
rustc +1.91.0 -vV > "$ARTIFACTS/verifier-host-rust.txt"
cargo +1.91.0 install solana-verify --git https://github.com/solana-foundation/solana-verifiable-build \
  --rev "$VERIFIER_COMMIT" --locked --root "$TASK_DIR/verifier" 2>&1 | tee "$ARTIFACTS/verifier-install.log"
"$TASK_DIR/verifier/bin/solana-verify" --version > "$ARTIFACTS/verifier-version.txt"
grep -Fx 'solana-verify 0.5.1' "$ARTIFACTS/verifier-version.txt"
sha256sum "$TASK_DIR/verifier/bin/solana-verify" > "$ARTIFACTS/verifier-binary.sha256"
"$DOCKER_REAL" pull --platform linux/amd64 "$BUILDER_IMAGE" 2>&1 | tee "$ARTIFACTS/image-pull.log"
"$DOCKER_REAL" image inspect "$BUILDER_IMAGE" --format '{{json .}}' > "$ARTIFACTS/base-image.json"
STAGE=source_visibility_diagnosis
(
  cd "$TASK_DIR/source"
  pwd; id; git rev-parse HEAD; git status --porcelain
  ls -lad . programs programs/cp-swap .git
  find . -maxdepth 2 -not -path './.git/*' -printf '%M %u:%g %p\n' | sort
  test -f programs/cp-swap/Cargo.toml
  sha256sum Cargo.toml Cargo.lock programs/cp-swap/Cargo.toml
) > "$ARTIFACTS/host-source-diagnostics.log"
# Reproduce visibility with the old permissions and unchanged dropped capabilities.
"$DOCKER_REAL" run --rm --network none --cap-drop ALL --security-opt no-new-privileges \
  --mount "type=bind,src=$TASK_DIR/source,dst=/buildsrc,readonly" -w /buildsrc "$BUILDER_IMAGE" \
  bash -c 'pwd; id; grep CapEff /proc/self/status; ls -ld /buildsrc; ls -la /buildsrc; stat /buildsrc/programs/cp-swap/Cargo.toml; test -f programs/cp-swap/Cargo.toml; printf "OLD_MANIFEST_VISIBLE=%s\n" "$?"; exit 0' \
  > "$ARTIFACTS/old-permissions-probe.log" 2>&1
# These are exclusively public source/Git metadata in the disposable VM.
# Enable traversal/read by the container UID, not DAC bypass or broader capabilities.
chmod -R a+rX "$TASK_DIR/source"
STAGE=dependency_prefetch
# Acquisition stage: fetch locked crates only. Do not compile the CP program with network.
PREFETCH_CONTAINER=$("$DOCKER_REAL" create --platform linux/amd64 --memory 10g --cpus 2 --pids-limit 512 \
  --cap-drop ALL --security-opt no-new-privileges \
  --mount "type=bind,src=$TASK_DIR/source,dst=/buildsrc,readonly" \
  -e SOURCE_COMMIT="$SOURCE_COMMIT" -e LOCK_SHA="$LOCK_SHA" -e GIT_OPTIONAL_LOCKS=0 \
  -w /buildsrc "$BUILDER_IMAGE" bash -ec '
    pwd; id; grep CapEff /proc/self/status
    ls -la /buildsrc; find /buildsrc -maxdepth 2 -not -path "/buildsrc/.git/*" -type f | sort
    git -c safe.directory=/buildsrc rev-parse HEAD
    test "$(git -c safe.directory=/buildsrc rev-parse HEAD)" = "$SOURCE_COMMIT"
    git -c safe.directory=/buildsrc status --porcelain
    test -z "$(git -c safe.directory=/buildsrc status --porcelain)"
    test -f programs/cp-swap/Cargo.toml
    sha256sum Cargo.toml Cargo.lock programs/cp-swap/Cargo.toml
    printf "%s  Cargo.lock\n" "$LOCK_SHA" | sha256sum --check
    printf "%s  programs/cp-swap/Cargo.toml\n" 0781abe35c722bcab6153ee002622c63b6fbdca5d0494cc7d68a78e6459022bf | sha256sum --check
    solana --version; rustc -vV; cargo --version; cargo-build-sbf --version
    pwd; test -f /buildsrc/programs/cp-swap/Cargo.toml
    cargo fetch --locked --manifest-path /buildsrc/programs/cp-swap/Cargo.toml')
"$DOCKER_REAL" inspect "$PREFETCH_CONTAINER" --format '{{json .}}' > "$ARTIFACTS/prefetch-container-inspect.json"
"$DOCKER_REAL" start -a "$PREFETCH_CONTAINER" 2>&1 | tee "$ARTIFACTS/dependency-prefetch.log"
prefetch_exit=$("$DOCKER_REAL" inspect -f '{{.State.ExitCode}}' "$PREFETCH_CONTAINER")
printf 'PREFETCH_EXIT=%s\n' "$prefetch_exit"
if [ "$prefetch_exit" != 0 ]; then exit "$prefetch_exit"; fi
# Capture compiler/dependency metadata from this same cache image before compilation.
PREPARED_IMAGE=$("$DOCKER_REAL" commit --change 'ENV CARGO_NET_OFFLINE=true' --change 'WORKDIR /build' "$PREFETCH_CONTAINER")
export PREPARED_IMAGE
"$DOCKER_REAL" image inspect "$PREPARED_IMAGE" --format '{{json .}}' > "$ARTIFACTS/prepared-image.json"
"$DOCKER_REAL" run --rm --network none --cap-drop ALL --security-opt no-new-privileges "$PREPARED_IMAGE" \
  bash -ec 'solana --version; rustc -vV; cargo --version; cargo-build-sbf --version; for x in solana rustc cargo cargo-build-sbf; do p=$(command -v "$x"); sha256sum "$p"; done; find "${CARGO_HOME}/registry/cache" -type f -name "*.crate" -print0 | sort -z | xargs -0 -r sha256sum' \
  > "$ARTIFACTS/toolchain-dependencies.txt"
grep -E '^solana-cli 3\.1\.10([ (]|$)' "$ARTIFACTS/toolchain-dependencies.txt"
"$DOCKER_REAL" rm "$PREFETCH_CONTAINER" >/dev/null
PREFETCH_CONTAINER=''
# The verified CLI starts build containers through this small policy wrapper.
# Mount the entire clean source read-only, with only target output writable.
cat > "$TASK_DIR/bin/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = run ]; then
  shift
  args=(); source_mount=''; output_mount=''
  while [ "$#" -gt 0 ]; do
    if [ "$1" = -v ]; then
      shift; source_mount=${1%:*}; mount_dest=${1##*:}
      test "$mount_dest" = /build
      test "$source_mount" = "$TASK_DIR/build-$BUILD_INDEX"
      args+=(-v "$source_mount:$mount_dest:ro")
      output_mount="type=bind,src=$source_mount/target,dst=/build/target"
    else args+=("$1"); fi
    shift
  done
  if [ -z "$source_mount" ]; then
    exec "$DOCKER_REAL" run --network none --cap-drop ALL --security-opt no-new-privileges --pids-limit 512 "${args[@]}"
  fi
  cid=$("$DOCKER_REAL" run --network none --cap-drop ALL --security-opt no-new-privileges --pids-limit 512 --mount "$output_mount" "${args[@]}")
  "$DOCKER_REAL" inspect "$cid" --format '{{json .}}' > "$ARTIFACTS/build-$BUILD_INDEX-container-inspect.json"
  "$DOCKER_REAL" exec -e GIT_OPTIONAL_LOCKS=0 -e SOURCE_COMMIT="$SOURCE_COMMIT" -w /build "$cid" bash -ec '
    pwd; id; git -c safe.directory=/build rev-parse HEAD; git -c safe.directory=/build status --porcelain
    test "$(git -c safe.directory=/build rev-parse HEAD)" = "$SOURCE_COMMIT"
    test -z "$(git -c safe.directory=/build status --porcelain)"
    ls -la /build; find /build -maxdepth 2 -not -path "/build/.git/*" -type f | sort
    test -f programs/cp-swap/Cargo.toml; sha256sum Cargo.toml Cargo.lock programs/cp-swap/Cargo.toml
    grep " /build" /proc/self/mountinfo
  ' > "$ARTIFACTS/build-$BUILD_INDEX-source-diagnostics.log" 2>&1
  printf '%s\n' "$cid"
  exit 0
fi
exec "$DOCKER_REAL" "$@"
SH
chmod 700 "$TASK_DIR/bin/docker"
export PATH="$TASK_DIR/bin:$PATH"
for n in 1 2; do
  STAGE="cp_build_$n"
  export BUILD_INDEX="$n"
  run="$TASK_DIR/build-$n"; mkdir "$run"
  cp -a "$TASK_DIR/source/." "$run/"
  chmod a+rx "$run"
  mkdir "$run/target"; chmod 0777 "$run/target"
  printf 'solana-verify build <source> --library-name raydium_cp_swap --base-image %s\n' "$PREPARED_IMAGE" > "$ARTIFACTS/build-$n-command.txt"
  timeout --signal=TERM --kill-after=30s 900 "$TASK_DIR/verifier/bin/solana-verify" build "$run" \
    --library-name raydium_cp_swap --base-image "$PREPARED_IMAGE" 2>&1 | tee "$ARTIFACTS/build-$n.log"
  cp "$run/target/deploy/raydium_cp_swap.so" "$ARTIFACTS/build-$n.so"
  export CHECK_SOURCE="$run"
  python3 - <<'PY'
import pathlib,os,json,hashlib
expected=json.loads(pathlib.Path(os.environ['ARTIFACTS'],'source-manifest.json').read_text())
root=pathlib.Path(os.environ['CHECK_SOURCE'])
for name,want in expected.items():assert hashlib.sha256((root/name).read_bytes()).hexdigest()==want, name
PY
done
python3 - <<'PY'
import pathlib,os,hashlib,json,struct
d=pathlib.Path(os.environ['ARTIFACTS']);a=(d/'build-1.so').read_bytes();b=(d/'build-2.so').read_bytes()
h=lambda x:hashlib.sha256(x).hexdigest()
target='b6dbea8cefc2e7d490775ce6115e34a2ba480c0853c359e0bb4043b9381ef09a'
target_trim='93cad2458ac72435c94b8ac89faa686987f4e29d2f0e862d546fbc5aa814a0d2';target_size=793824
valid=len(a)>=64 and a[:4]==b'\x7fELF' and a[4:6]==b'\x02\x01' and struct.unpack_from('<H',a,18)[0]==247
reproducible=valid and a==b
zero_padded=h(a+b'\0'*(target_size-len(a))) if len(a)<=target_size else None
match=reproducible and zero_padded==target and h(a.rstrip(b'\0'))==target_trim
result='EXACT_SOURCE_ELF_MATCH' if match else ('REPRODUCIBLE_BUILD_MISMATCH' if reproducible else 'REPRODUCIBLE_BUILD_NOT_ACHIEVED')
summary={'result':result,'candidateCommit':os.environ['SOURCE_COMMIT'],'sourceTree':os.environ['SOURCE_TREE'],'sourceUnchanged':True,'runs':2,'identicalIndependentOutputs':reproducible,'elfValidSbf':valid,'fullSha256':h(a),'secondFullSha256':h(b),'bytes':len(a),'trimmedSha256':h(a.rstrip(b'\0')),'trimmedBytes':len(a.rstrip(b'\0')),'expectedAllocatedPayloadBytes':target_size,'zeroPaddingOnlyExpandedSha256':zero_padded,'expectedFullSha256':target,'expectedTrimmedSha256':target_trim,'baseImage':os.environ['BUILDER_IMAGE'],'preparedImage':os.environ['PREPARED_IMAGE'],'financialAuthority':False,'freshChainCheck':'NOT_RUN','liveReady':False}
(d/'RESULT.json').write_text(json.dumps(summary,indent=2));print(json.dumps(summary))
PY
BUILD_COMPLETE=true
printf 'FINISHED %s\n' "$(date -u +%FT%TZ)"
