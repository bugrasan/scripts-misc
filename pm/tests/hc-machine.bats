#!/usr/bin/env bats
# stub tests for the hc machine of a pm run --hc container (pm v9, owner
# decisions D15 to D21, Q24, and the exact connection of owner decision
# 4): a fake podman and a fake hc (stub/hc) log every call, and HOME is a
# per-test folder; no real podman or hc runs
# run: bats pm/tests/hc-machine.bats
# shellcheck disable=SC2016,SC2030,SC2031
# SC2016: literal backticks and $ on purpose; SC2030, SC2031: each bats
# test runs in its own subshell, and its exports are meant for it alone

load test_helper

setup() { stub_setup; }

IMG=example.org/img:1

# machines <object>...: a machine ls --json answer with these machines
machines() { local IFS=,; printf '{"machines":[%s]}' "$*"; }

# ------------------------------------------------------------------ D15

@test "D15: pm adds the container as an hc machine, without stdin and --install, and runs no hc serve by exec" {
  run --separate-stderr pm run --hc --mount "$P" "$IMG" <<<'y'
  expect_status 0
  no_hc_serve
  hc_find -x machine ls --json || { hc_show; fail 'no hc machine ls --json'; }
  hc_find -x machine add --name pm-proj --via "$(pm_via pm-proj)" || { hc_show; fail 'no hc machine add'; }
  [ "$(<"$HC_LOG.stdin")" = devnull ]
  has_line "$output" 'ok    hc machine pm-proj added'
}

@test "decision 4: the via command has a bare podman, wherever podman is" {
  local odd="$T/odd dir'q"
  mkdir -p "$odd"
  cp -- "$STUB_BIN/podman" "$odd/podman"
  PM_PATH=$odd:$PM_PATH
  run --separate-stderr pm run --hc --mount "$P" "$IMG"
  expect_status 0
  hc_find -x machine add --name pm-proj --via 'podman exec -i pm-proj sh -c' \
    || { hc_show; fail 'no hc machine add with a bare podman'; }
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

# ------------------------------------------------------------------ exact match

@test "decision 4: only the exact connection is pm's; an absolute podman path and look-alikes are another" {
  local t
  # target|via: absolute podman paths (pm's before decision 4), other
  # commands, no via, more or less around pm's text, another container
  for t in '/usr/local/bin/podman exec -i pm-proj sh -c|true' \
    "'/Applications/Podman Desktop/podman' exec -i pm-proj sh -c|true" \
    'sudo podman exec -i pm-proj sh -c|true' 'ssh box podman exec -i pm-proj sh -c|true' \
    'docker exec -i pm-proj sh -c|true' 'podman exec -i pm-proj sh -c|false' \
    'podman exec -i pm-proj sh -c -x|true' ' podman exec -i pm-proj sh -c|true' \
    'xpodman exec -i pm-proj sh -c|true' 'podman exec -i xpm-proj sh -c|true'; do
    forget_containers
    : >"$HC_LOG"
    FAKE_HC_LS=$(machines "$(hc_machine pm-proj "${t%|*}" "${t##*|}")") \
      run --separate-stderr pm run --hc --mount "$P" "$IMG"
    expect_status 1
    has_line "$stderr" 'error pm-proj: hc already has a machine pm-proj with another connection; see hc machine ls'
    if hc_find machine rm || hc_find machine add; then hc_show; fail "pm run changed hc for: $t"; fi
    # pm rm keeps it, with a skip line
    : >"$HC_LOG"
    FAKE_HC_LS=$(machines "$(hc_machine pm-proj "${t%|*}" "${t##*|}")") \
      run --separate-stderr pm rm --force pm-proj
    expect_status 0
    has_line "$output" 'skip  hc machine pm-proj: another connection; kept'
    if hc_find machine rm; then hc_show; fail "pm rm removed: $t"; fi
  done
  # pm rm removes the exact one
  fake_container pm-proj pm-proj
  : >"$HC_LOG"
  FAKE_HC_LS=$(machines "$(hc_machine pm-proj 'podman exec -i pm-proj sh -c')") \
    run --separate-stderr pm rm --force pm-proj
  expect_status 0
  hc_find -x machine rm -- pm-proj || { hc_show; fail 'no hc machine rm'; }
  has_line "$output" 'ok    hc machine pm-proj removed'
}

# ------------------------------------------------------------------ D19, D20

@test "D19: without hc on PATH, pm notes it and adds no machine; the container stays" {
  rm -- "$STUB_BIN/hc"
  use_min_path
  fake_hash sha256sum
  run --separate-stderr pm run --hc --mount "$P" "$IMG"
  expect_status 0
  has_line "$stderr" 'pm run: note: no hc on PATH, so pm-proj is not added as an hc machine; add it later with: pm hc-add pm-proj'
  no_hc_serve
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
  hc_find -x machine rm -- pm-x || { hc_show; fail 'no hc machine rm'; }
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
  has_line "$stderr" "error hc machine pm-x: $FAKE_HC_RM_OUT; remove it by hand with: hc machine rm pm-x"
  [[ ! -e $STUB_STATE/containers/pm-x ]]
}

@test "D21: containers without the pm-hc label get no hc calls from pm rm" {
  fake_container pm-y
  run --separate-stderr pm rm --force pm-y
  expect_status 0
  [ ! -s "$HC_LOG" ] || { hc_show; fail 'hc was called'; }
}

# ------------------------------------------------------------------ Q24

@test "Q24: pm start runs podman start only, also for a pm-hc container" {
  fake_container pm-x pm-x
  printf 'exited\n' >"$STUB_STATE/status/pm-x"
  run --separate-stderr pm start pm-x
  expect_status 0
  [ "$output" = pm-x ] || fail "output: $output"
  podman_find -x start -- pm-x || { podman_show; fail 'no podman start'; }
  no_hc_serve
  if podman_find exec; then podman_show; fail 'pm start ran podman exec'; fi
  STUB_START_RC=125 run --separate-stderr pm start pm-x
  expect_status 125
}

@test "D25: pm help, pm start --help, and pm rm --help tell about the hc handling" {
  run pm help
  expect_status 0
  has_line "$output" '  start      <container>'
  has_line "$output" '  rm         [--force] <container>  remove it, its pm network once unused, and its hc machine'
  run pm start --help
  expect_status 0
  [[ $output == *'podman start <container>'* && $output == *'hc serve'* ]] \
    || fail "pm start --help: $output"
  run pm rm --help
  expect_status 0
  [[ $output == *'hc machine rm <container>'* && $output == *pm-hc* ]] || fail "pm rm --help: $output"
}
