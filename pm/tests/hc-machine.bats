#!/usr/bin/env bats
# stub tests for the hc machine of a pm run --hc container (pm v9, owner
# decisions D15 to D22): a fake podman and a fake host hc (stub/hc) log
# every call, and HOME is a per-test folder; no real podman or hc runs
# run: bats pm/tests/hc-machine.bats

load test_helper

setup() { stub_setup; }

IMG=example.org/img:1

# machines <object>...: a machine ls --json answer with these machines
machines() { local IFS=,; printf '{"machines":[%s]}' "$*"; }

# ------------------------------------------------------------------ D15

@test "D15: after hc serve, pm adds the container as an hc machine, without stdin and --install" {
  run --separate-stderr pm run --hc --mount "$P" "$IMG" <<<'y'
  expect_status 0
  hc_serve_call pm-proj
  hc_find -x machine ls --json || { hc_show; fail 'no hc machine ls --json'; }
  hc_find -x machine add --name pm-proj --via "$(pm_via pm-proj)" || { hc_show; fail 'no hc machine add'; }
  [ "$(<"$HC_LOG.stdin")" = devnull ]
  has_line "$output" 'ok    hc machine pm-proj added'
}

@test "D15: a podman path with a space or quote is quoted for sh in the via command" {
  local odd="$T/odd dir'q" via
  mkdir -p "$odd"
  cp -- "$STUB_BIN/podman" "$odd/podman"
  PM_PATH=$odd:$PM_PATH
  run --separate-stderr pm run --hc --mount "$P" "$IMG"
  expect_status 0
  hc_find machine add --name pm-proj --via || { hc_show; fail 'no hc machine add'; }
  via=${CALL[5]}
  [[ $via == *' exec -i pm-proj sh -c' ]] || fail "via: $via"
  # sh must read the path back as one word
  [ "$(sh -c "set -- ${via% exec -i pm-proj sh -c}; printf '%s' \"\$1\"")" = "$odd/podman" ]
}

@test "D15: no hc machine calls when hc serve fails" {
  export STUB_EXEC_RC=127 STUB_EXEC_ERR='Error: crun: executable file `hc` not found'
  run --separate-stderr pm run --hc --mount "$P" "$IMG"
  expect_status 1
  [ ! -s "$HC_LOG" ] || { hc_show; fail 'hc was called'; }
}

# ------------------------------------------------------------------ D16

@test "D16: with --hc, a name hc would refuse is a usage error before anything happens" {
  local name
  for name in Upper a23456789012345678901234567890123 t7 t1b _x; do
    run --separate-stderr pm run --hc --mount "$P" "$IMG" "$name"
    expect_status 2
    [[ $stderr == *"$name"* && $stderr == *'<container-name>'* ]] || fail "stderr: $stderr"
  done
  # a name made from the folder counts as well
  mkdir "$T/MyApp"
  run --separate-stderr pm run --hc --mount "$T/MyApp" "$IMG"
  expect_status 2
  [[ $stderr == *pm-MyApp* ]] || fail "stderr: $stderr"
  [ ! -s "$PODMAN_LOG" ] || { podman_show; fail 'podman was called'; }
  [ ! -s "$HC_LOG" ] || { hc_show; fail 'hc was called'; }
  [ -z "$(ls -A "$P")" ] && [ -z "$(ls -A "$T/MyApp")" ]
}

@test "D16: names hc accepts pass, and without --hc any podman name does" {
  local name i=0
  for name in t0 t1a a a2345678901234567890123456789012 my_app.1-x; do
    i=$((i + 1))
    mkdir "$T/n$i"
    run --separate-stderr pm run --hc --mount "$T/n$i" "$IMG" "$name"
    expect_status 0
  done
  mkdir "$T/MyApp"
  run --separate-stderr pm run --mount "$T/MyApp" "$IMG"
  expect_status 0
  run_args
  has_opt --name pm-MyApp
}

# ------------------------------------------------------------------ D17

@test "D17: pm run --hc labels the container pm-hc=<name>; without --hc there is no such label" {
  run --separate-stderr pm run --hc --mount "$P" "$IMG"
  expect_status 0
  run_args
  has_opt --label pm-hc=pm-proj
  forget_containers
  run --separate-stderr pm run --mount "$P" "$IMG" c2
  expect_status 0
  run_args
  [[ " ${RUN[*]} " != *' pm-hc='* ]] || fail "label in: ${RUN[*]}"
}

# ------------------------------------------------------------------ D18

@test "D18: an hc machine of that name with pm's connection is kept, with a note" {
  FAKE_HC_LS=$(machines "$(hc_machine pm-proj "$(pm_via pm-proj)")")
  export FAKE_HC_LS
  run --separate-stderr pm run --hc --mount "$P" "$IMG"
  expect_status 0
  has_line "$stderr" 'pm run: note: hc machine pm-proj already connects to this container; kept'
  if hc_find machine add; then hc_show; fail 'pm added the machine again'; fi
}

@test "D18: an hc machine of that name with another connection is an error; the container stays" {
  local ls
  for ls in "$(machines "$(hc_machine pm-proj 'ssh box' false)")" \
    "$(machines "$(hc_machine pm-proj "$(pm_via pm-other)")")" \
    "$(machines "$(hc_machine pm-proj "$(pm_via pm-proj)" false)")"; do
    forget_containers
    : >"$PODMAN_LOG"
    : >"$HC_LOG"
    FAKE_HC_LS=$ls run --separate-stderr pm run --hc --mount "$P" "$IMG"
    expect_status 1
    has_line "$stderr" 'error pm-proj: hc already has a machine pm-proj with another connection; see hc machine ls'
    if hc_find machine add; then hc_show; fail 'pm added the machine'; fi
    if podman_find rm; then podman_show; fail 'pm removed the container'; fi
    [[ -e $STUB_STATE/containers/pm-proj ]]
  done
}

@test "D18: other machines and look-alike text in hc's list do not count" {
  local tricky
  # a host string that holds the name, as JSON escapes it
  tricky='{"host":"\"name\":\"pm-proj\",}","id":"9","name":"x","target":"y","via":false}'
  FAKE_HC_LS=$(machines "$(hc_machine pm-proj2 "$(pm_via pm-proj2)")" "$tricky")
  export FAKE_HC_LS
  run --separate-stderr pm run --hc --mount "$P" "$IMG"
  expect_status 0
  hc_find -x machine add --name pm-proj --via "$(pm_via pm-proj)" || { hc_show; fail 'no hc machine add'; }
}

# ------------------------------------------------------------------ D19, D20

@test "D19: without hc on PATH, pm notes it and adds no machine; container and core stay" {
  rm -- "$STUB_BIN/hc"
  use_min_path
  fake_hash sha256sum
  run --separate-stderr pm run --hc --mount "$P" "$IMG"
  expect_status 0
  has_line "$stderr" 'pm run: note: no hc on PATH, so pm-proj is not added as an hc machine'
  hc_serve_call pm-proj
  if podman_find rm; then podman_show; fail 'pm removed the container'; fi
}

@test "D20: a failing hc machine add is an error with hc's output; the container stays" {
  export FAKE_HC_ADD_RC=1
  export FAKE_HC_ADD_OUT='{"error":{"hint":"check it","kind":"unreachable","message":"cannot reach it"}}'
  run --separate-stderr pm run --hc --mount "$P" "$IMG"
  expect_status 1
  has_line "$stderr" "error pm-proj: hc machine add: $FAKE_HC_ADD_OUT"
  if podman_find rm; then podman_show; fail 'pm removed the container'; fi
  [[ -e $STUB_STATE/containers/pm-proj ]]
}

@test "D20: a failing hc machine ls is an error too, and pm adds nothing" {
  export FAKE_HC_LS_RC=1 FAKE_HC_LS='{"error":{"kind":"unavailable","message":"no core"}}'
  run --separate-stderr pm run --hc --mount "$P" "$IMG"
  expect_status 1
  has_line "$stderr" "error pm-proj: hc machine ls: $FAKE_HC_LS"
  if hc_find machine add; then hc_show; fail 'pm added the machine'; fi
}

# ------------------------------------------------------------------ D21

@test "D21: pm rm removes the hc machine of a labeled container that still has pm's connection" {
  fake_container pm-x pm-x
  FAKE_HC_LS=$(machines "$(hc_machine pm-x "$(pm_via pm-x)")")
  export FAKE_HC_LS
  run --separate-stderr pm rm --force pm-x
  expect_status 0
  hc_find -x machine rm pm-x || { hc_show; fail 'no hc machine rm'; }
  [ "$(grep -n -e 'container pm-x removed' -e 'hc machine pm-x removed' <<<"$output" | cut -d: -f1 | tr '\n' ' ')" = '1 2 ' ] \
    || fail "order: $output"
}

@test "D21: an entry that is gone or not pm's, or no hc, gives a skip line" {
  fake_container pm-x pm-x
  run --separate-stderr pm rm --force pm-x
  expect_status 0
  has_line "$output" 'skip  hc machine pm-x: not in hc machine ls'

  fake_container pm-x pm-x
  FAKE_HC_LS=$(machines "$(hc_machine pm-x 'ssh box' false)") run --separate-stderr pm rm --force pm-x
  expect_status 0
  has_line "$output" 'skip  hc machine pm-x: another connection; kept'
  if hc_find machine rm; then hc_show; fail 'pm removed the machine'; fi

  fake_container pm-x pm-x
  rm -- "$STUB_BIN/hc"
  use_min_path
  run --separate-stderr pm rm --force pm-x
  expect_status 0
  has_line "$output" 'skip  hc machine pm-x: no hc on PATH'
}

@test "D21: a failing hc machine rm is a red error and exit 1, after the container is gone" {
  fake_container pm-x pm-x
  FAKE_HC_LS=$(machines "$(hc_machine pm-x "$(pm_via pm-x)")")
  export FAKE_HC_LS FAKE_HC_RM_RC=4 FAKE_HC_RM_OUT='{"error":{"kind":"machine_unknown"}}'
  run --separate-stderr pm rm --force pm-x
  expect_status 1
  has_line "$output" 'ok    container pm-x removed'
  has_line "$stderr" "error hc machine pm-x: $FAKE_HC_RM_OUT"
  [[ ! -e $STUB_STATE/containers/pm-x ]]
}

@test "D21: containers without the pm-hc label get no hc calls from pm rm" {
  fake_container pm-y
  run --separate-stderr pm rm --force pm-y
  expect_status 0
  [ ! -s "$HC_LOG" ] || { hc_show; fail 'hc was called'; }
}

# ------------------------------------------------------------------ D22

@test "D22: pm start starts hc serve in a labeled container after podman start" {
  fake_container pm-x pm-x
  run --separate-stderr pm start pm-x
  expect_status 0
  local s
  podman_find -x start -- pm-x
  s=$FOUND
  hc_serve_call pm-x || { podman_show; fail 'no hc serve'; }
  (( FOUND > s ))
  has_line "$output" 'ok    hc serve started in pm-x'
}

@test "D22: no hc serve for an unlabeled container or after a failed podman start" {
  fake_container pm-y
  run --separate-stderr pm start pm-y
  expect_status 0
  if podman_find exec; then podman_show; fail 'hc serve in an unlabeled container'; fi
  fake_container pm-x pm-x
  STUB_START_RC=125 run --separate-stderr pm start pm-x
  [ "$status" -ne 0 ]
  if podman_find exec; then podman_show; fail 'hc serve after a failed start'; fi
}

@test "D25: pm help, pm start --help, and pm rm --help tell about the hc handling" {
  run pm help
  expect_status 0
  has_line "$output" '  start      <container>    and hc serve for a pm run --hc container'
  has_line "$output" '  rm         [--force] <container>  remove it, its pm network once unused, and its hc machine'
  run pm start --help
  expect_status 0
  [[ $output == *'podman exec -d -e SHELL=/bin/bash <container> hc serve'* && $output == *pm-hc* ]] \
    || fail "pm start --help: $output"
  run pm rm --help
  expect_status 0
  [[ $output == *'hc machine rm <container>'* && $output == *pm-hc* ]] || fail "pm rm --help: $output"
}

@test "D22: a failing hc serve after pm start is a red error with its output" {
  fake_container pm-x pm-x
  export STUB_EXEC_RC=127 STUB_EXEC_ERR='Error: crun: executable file `hc` not found'
  run --separate-stderr pm start pm-x
  expect_status 1
  has_line "$stderr" "error pm-x: hc serve: $STUB_EXEC_ERR"
}
