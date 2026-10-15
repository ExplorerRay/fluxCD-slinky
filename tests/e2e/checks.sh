#!/usr/bin/env bash
# End-to-end assertions mirroring docs/verification.md §1-5, plus Slurm
# accounting, run against a cluster deployed by tests/e2e/deploy.sh
# (kind-single topology). Every check runs; each prints PASS or FAIL, and the
# script exits non-zero if any failed. Re-runnable against a live cluster
# without redeploying; the accounting checks briefly create e2e-* reservations
# and restrict the default partition's AllowGroups, restoring both.
#
# Environment (defaults in brackets), shared with deploy.sh:
#   E2E_USER [e2euser]  E2E_GROUP [e2eteam]  E2E_PASSWORD [E2e-dev-only-1]
#   E2E_ACCOUNT [e2eteam] (Slurm account E2E_USER is registered under)
# Needs ssh and sshpass: the login checks go through the real sshd on the
# login NodePort (32222), password-authenticated against FreeIPA.

set -uo pipefail

E2E_USER="${E2E_USER:-e2euser}"
E2E_GROUP="${E2E_GROUP:-e2eteam}"
E2E_PASSWORD="${E2E_PASSWORD:-E2e-dev-only-1}"
E2E_ACCOUNT="${E2E_ACCOUNT:-e2eteam}"
SSH_PORT=32222

failures=0

# gha_escape <text>: encode for a GitHub Actions workflow command.
gha_escape() {
  local s=${1//'%'/%25}
  s=${s//$'\r'/%0D}
  printf '%s' "${s//$'\n'/%0A}"
}

# check <description> <command...>: run, record PASS/FAIL, show output on FAIL.
check() {
  local desc=$1 out
  shift
  if out="$("$@" 2>&1)"; then
    echo "PASS  $desc"
  else
    echo "FAIL  $desc"
    printf '      %s\n' "${out//$'\n'/$'\n      '}"
    failures=$((failures + 1))
    # Annotations, unlike job logs, are readable without repository admin
    # rights (the check-runs API), so a failure can be diagnosed from them.
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
      echo "::error title=e2e check failed::$(gha_escape "$desc"$'\n'"$out")"
    fi
  fi
}

login_pod="$(kubectl -n slurm get pod -l app.kubernetes.io/component=login -o jsonpath='{.items[0].metadata.name}')"
worker_pod="$(kubectl -n slurm get pod -l app.kubernetes.io/component=worker -o jsonpath='{.items[0].metadata.name}')"
node_ip="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"
if [[ -z "$login_pod" || -z "$worker_pod" || -z "$node_ip" ]]; then
  echo "ERROR: cannot find login pod ($login_pod), worker pod ($worker_pod) or node IP ($node_ip)" >&2
  exit 1
fi

on_login() { kubectl -n slurm exec "$login_pod" -c login -- "$@"; }
on_worker() { kubectl -n slurm exec "$worker_pod" -c slurmd -- "$@"; }
# as_user <remote command string>: run as E2E_USER over the login NodePort.
as_user() {
  sshpass -p "$E2E_PASSWORD" ssh -p "$SSH_PORT" \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    -o PubkeyAuthentication=no -o PreferredAuthentications=keyboard-interactive,password \
    "$E2E_USER@$node_ip" "$1"
}

# --- 1. Cluster ---------------------------------------------------------------
nodes_ready() {
  kubectl get nodes --no-headers | awk '$2 != "Ready" {bad = 1; print} END {exit bad}'
}

# --- 2. Flux ------------------------------------------------------------------
flux_ready() {
  local all not_ready
  all="$(kubectl get kustomizations.kustomize.toolkit.fluxcd.io,helmreleases.helm.toolkit.fluxcd.io -A \
    -o jsonpath='{range .items[*]}{.kind}/{.metadata.namespace}/{.metadata.name} {.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}')" || return 1
  [[ -n "$all" ]] || { echo "no Kustomizations or HelmReleases found"; return 1; }
  # shellcheck disable=SC2016 # awk program, not shell
  not_ready="$(awk '$2 != "True"' <<<"$all")" || return 1
  [[ -z "$not_ready" ]] || { echo "$not_ready"; return 1; }
}

# --- 3. Storage ---------------------------------------------------------------
ceph_not_error() {
  local health
  health="$(kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph health)" || return 1
  echo "$health"
  [[ "$health" != HEALTH_ERR* ]]
}
pvcs_bound() {
  kubectl get pvc -A --no-headers | awk '$3 != "Bound" {bad = 1; print} END {exit bad}'
}
home_pvc_rwx_cephfs() {
  local got
  got="$(kubectl -n slurm get pvc slurm-home -o jsonpath='{.spec.accessModes[0]} {.spec.storageClassName}')"
  echo "$got"
  [[ "$got" == "ReadWriteMany ceph-filesystem" ]]
}

# --- 4. FreeIPA ---------------------------------------------------------------
ipa_running() {
  local status
  status="$(kubectl -n freeipa exec ipa-0 -- ipactl status)" || { echo "$status"; return 1; }
  echo "$status"
  ! grep -q STOPPED <<<"$status"
}

# --- 5. Slurm, identity and /home ---------------------------------------------
node_idle() {
  local states
  states="$(on_login sinfo -h -o '%t')" || return 1
  echo "$states"
  grep -qx idle <<<"$states"
}
login_resolves_user() { on_login getent passwd "$E2E_USER"; }
group_parity() {
  # SSSD (login) and nss_slurm (job) may list groups in different orders.
  local on_login_node in_job
  on_login_node="$(as_user 'id -Gn' | tr ' ' '\n' | sort | tr '\n' ' ')" || return 1
  in_job="$(as_user 'srun id -Gn' | tr ' ' '\n' | sort | tr '\n' ' ')" || return 1
  echo "login: $on_login_node"
  echo "job:   $in_job"
  [[ " $on_login_node " == *" $E2E_GROUP "* && "$on_login_node" == "$in_job" ]]
}
job_resolves_user() {
  local got
  got="$(as_user "srun id -un; srun getent passwd $E2E_USER")" || { echo "$got"; return 1; }
  echo "$got"
  [[ "$(head -n1 <<<"$got")" == "$E2E_USER" ]] && grep -q "^$E2E_USER:" <<<"$got"
}
home_dir_private() {
  local got
  # shellcheck disable=SC2016 # expanded by the remote shell, not here
  got="$(as_user 'pwd; stat -c "%u:%g %a" "$HOME"; echo "$(id -u):$(id -g) 700"')" || { echo "$got"; return 1; }
  echo "$got"
  [[ "$(sed -n 1p <<<"$got")" == "/home/$E2E_USER" && "$(sed -n 2p <<<"$got")" == "$(sed -n 3p <<<"$got")" ]]
}
home_root_owned() {
  local login_perm worker_perm
  login_perm="$(on_login stat -c '%u:%g %a' /home)" || return 1
  worker_perm="$(on_worker stat -c '%u:%g %a' /home)" || return 1
  echo "login: $login_perm  worker: $worker_perm"
  [[ "$login_perm" == "0:0 755" && "$worker_perm" == "0:0 755" ]]
}
home_same_cephfs() {
  local login_mount worker_mount
  # shellcheck disable=SC2016 # awk program, not shell
  login_mount="$(on_login awk '$2 == "/home" {print $1, $3}' /proc/mounts)" || return 1
  # shellcheck disable=SC2016 # awk program, not shell
  worker_mount="$(on_worker awk '$2 == "/home" {print $1, $3}' /proc/mounts)" || return 1
  echo "login:  $login_mount"
  echo "worker: $worker_mount"
  [[ -n "$login_mount" && "$login_mount" == "$worker_mount" && "$login_mount" == *" ceph" ]]
}
home_shared() {
  # shellcheck disable=SC2016 # expanded by the remote shell, not here
  as_user 'rm -f ~/from-login ~/from-compute && touch ~/from-login &&
    srun sh -c "ls ~/from-login && touch ~/from-compute" && ls -l ~/from-compute'
}
batch_job_accounted() {
  local out
  # shellcheck disable=SC2016 # expanded by the remote shell, not here
  out="$(as_user 'cd ~ && jobid=$(sbatch --parsable --wait --wrap "hostname; pwd; id -Gn") &&
    cat "slurm-$jobid.out" &&
    for _ in $(seq 30); do
      row=$(sacct -n -X -P -j "$jobid" -o User,State,ExitCode)
      case "$row" in
        ""|*PENDING*|*RUNNING*|*COMPLETING*) sleep 2 ;;
        *) break ;;
      esac
    done && echo "$row"')" || { echo "$out"; return 1; }
  echo "$out"
  grep -qx "$E2E_USER|COMPLETED|0:0" <<<"$out" && grep -qx "/home/$E2E_USER" <<<"$out"
}
no_identity_on_compute_outside_job() {
  # nss_slurm answers only for users with a step on the node; rc 2 = not found.
  local rc
  on_worker getent passwd "$E2E_USER"
  rc=$?
  echo "rc=$rc"
  [[ "$rc" -eq 2 ]]
}

# --- 6. Slurm accounting ------------------------------------------------------
# deploy.sh registers E2E_USER under E2E_ACCOUNT (docs/bootstrap.md, FreeIPA
# step 3). slurmctld runs no SSSD, so access control here is by Slurm account.
# The two "known limit" checks pin what that costs: name- and group-based
# access cannot resolve directory users (docs/runtime-requirements.md,
# "Controller identity and Slurm accounting"). If one starts failing,
# slurmctld has gained NSS for directory users and those docs are stale.
# A third pins that accounts are not enforced: AccountingStorageEnforce is
# unset, so a user can name an account they are not in.

# resv_create <name> <args...>: (re)create a 10-minute reservation on every
# node; ignore_jobs so running jobs are not in the way.
resv_create() {
  local name=$1
  shift
  on_login scontrol delete reservationname="$name" >/dev/null 2>&1
  on_login scontrol create reservation reservationname="$name" starttime=now \
    duration=10 nodes=ALL flags=ignore_jobs "$@"
}
resv_delete() { on_login scontrol delete reservationname="$1" >/dev/null 2>&1; }

# Read once, out here: checks run in subshells and cannot hand state back.
default_part="$(on_login sinfo -h -o '%P' | sed -n 's/\*$//p')"
orig_allow_groups="$(on_login scontrol show partition "$default_part" -o 2>/dev/null |
  grep -o 'AllowGroups=[^ ]*')"
# Undo what the accounting checks change on the live cluster however the script
# ends; each check also cleans up after itself, so normally this is a no-op.
cleanup() {
  local r
  for r in e2e-acct-allow e2e-acct-deny e2e-acct-claim e2e-users; do resv_delete "$r"; done
  if [[ -n "$orig_allow_groups" ]]; then
    on_login scontrol update partitionname="$default_part" "$orig_allow_groups" >/dev/null 2>&1
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

job_recorded_under_account() {
  local out
  # shellcheck disable=SC2016 # expanded by the remote shell, not here
  out="$(as_user 'jobid=$(timeout 300 sbatch --parsable --wait -o /dev/null --wrap true) &&
    for _ in $(seq 30); do
      row=$(sacct -n -X -P -j "$jobid" -o User,Account,AssocID,State)
      case "$row" in
        ""|*PENDING*|*RUNNING*|*COMPLETING*) sleep 2 ;;
        *) break ;;
      esac
    done && echo "$row"')" || { echo "$out"; return 1; }
  echo "User|Account|AssocID|State: $out"
  # shellcheck disable=SC2016 # awk program, not shell
  awk -F'|' -v u="$E2E_USER" -v a="$E2E_ACCOUNT" \
    '$1 == u && $2 == a && $3 > 0 && $4 == "COMPLETED" {ok = 1} END {exit !ok}' <<<"$out"
}
reservation_admits_account() {
  local out rc=0
  resv_create e2e-acct-allow accounts="$E2E_ACCOUNT" || return 1
  out="$(as_user "timeout 300 sbatch --parsable --wait -o /dev/null \
    --reservation=e2e-acct-allow -A $E2E_ACCOUNT --wrap true")" || rc=1
  echo "$out"
  resv_delete e2e-acct-allow
  return "$rc"
}
reservation_refuses_other_account() {
  # Every Slurm cluster has the root account; E2E_USER is not in it.
  local out
  resv_create e2e-acct-deny accounts=root || return 1
  if out="$(as_user 'sbatch --parsable -o /dev/null --reservation=e2e-acct-deny --wrap true' 2>&1)"; then
    echo "submitted job $out, expected a refusal"
    on_login scancel "$out"
    resv_delete e2e-acct-deny
    return 1
  fi
  echo "$out"
  resv_delete e2e-acct-deny
  grep -q "Access denied to requested reservation" <<<"$out"
}
account_membership_unenforced() {
  # The same reservation, but E2E_USER names its account with -A. Held, so it
  # only has to pass admission; nothing runs.
  local out
  resv_create e2e-acct-claim accounts=root || return 1
  if ! out="$(as_user 'sbatch --parsable --hold -o /dev/null --reservation=e2e-acct-claim -A root --wrap true' 2>&1)"; then
    echo "$out"
    echo "refused: slurmctld now checks account membership (AccountingStorageEnforce=associations?)"
    resv_delete e2e-acct-claim
    return 1
  fi
  echo "admitted as job $out"
  on_login scancel "$out"
  resv_delete e2e-acct-claim
}
reservation_users_unresolvable() {
  local out
  if out="$(resv_create e2e-users users="$E2E_USER" 2>&1)"; then
    echo "created a Users=$E2E_USER reservation: slurmctld now resolves directory users"
    resv_delete e2e-users
    return 1
  fi
  echo "$out"
  grep -q "Error creating the reservation" <<<"$out"
}
allow_groups_unresolvable() {
  # Temporarily restricts the default partition to E2E_GROUP, then restores it
  # (cleanup restores it too if the script is interrupted). The job is accepted
  # and pends with the denial as its reason.
  local part=$default_part orig=$orig_allow_groups jobid reason=""
  [[ -n "$part" && -n "$orig" ]] ||
    { echo "cannot read the default partition ($part) or its AllowGroups ($orig)"; return 1; }
  echo "partition $part, $orig"
  on_login scontrol update partitionname="$part" AllowGroups="$E2E_GROUP" || return 1
  if jobid="$(as_user "sbatch --parsable -o /dev/null -p $part --wrap true" 2>&1)"; then
    for _ in $(seq 15); do
      reason="$(on_login squeue -h -j "$jobid" -o '%r')"
      [[ "$reason" == *"not in group permitted"* ]] && break
      sleep 2
    done
    on_login scancel "$jobid"
  else
    reason="refused at submission: $jobid"
  fi
  on_login scontrol update partitionname="$part" "$orig" ||
    { echo "FAILED to restore $orig on partition $part"; return 1; }
  echo "reason: $reason"
  [[ "$reason" == *"not in group permitted"* ]]
}

check "all nodes Ready" nodes_ready
check "every Kustomization and HelmRelease Ready" flux_ready
check "ceph health is not HEALTH_ERR" ceph_not_error
check "every PVC Bound" pvcs_bound
check "slurm-home is ReadWriteMany on ceph-filesystem" home_pvc_rwx_cephfs
check "FreeIPA services RUNNING" ipa_running
check "a Slurm node is idle" node_idle
check "login pod resolves $E2E_USER (SSSD)" login_resolves_user
check "groups match on login and in a job, incl. $E2E_GROUP" group_parity
check "identity resolves inside a job (nss_slurm)" job_resolves_user
check "ssh lands in a private /home/$E2E_USER" home_dir_private
check "/home is root-owned 755 on login and compute" home_root_owned
check "login and compute mount the same CephFS /home" home_same_cephfs
check "files are shared between login and compute" home_shared
check "batch job completes and is accounted to $E2E_USER" batch_job_accounted
check "a job is recorded under Slurm account $E2E_ACCOUNT" job_recorded_under_account
check "an Accounts= reservation admits $E2E_ACCOUNT" reservation_admits_account
check "an Accounts= reservation refuses other accounts" reservation_refuses_other_account
check "known limit: -A admits $E2E_USER to an account it is not in (unenforced)" account_membership_unenforced
check "known limit: reservation Users= cannot resolve $E2E_USER" reservation_users_unresolvable
check "known limit: partition AllowGroups denies members of $E2E_GROUP" allow_groups_unresolvable
check "no identity on compute outside a job (no SSSD there)" no_identity_on_compute_outside_job

if ((failures > 0)); then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all checks passed"
