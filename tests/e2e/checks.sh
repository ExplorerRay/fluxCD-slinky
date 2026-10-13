#!/usr/bin/env bash
# End-to-end assertions mirroring docs/verification.md §1-5, run against a
# cluster deployed by tests/e2e/deploy.sh (kind-single topology). Every check
# runs; each prints PASS or FAIL, and the script exits non-zero if any failed.
# Re-runnable against a live cluster without redeploying.
#
# Environment (defaults in brackets), shared with deploy.sh:
#   E2E_USER [e2euser]  E2E_GROUP [e2eteam]  E2E_PASSWORD [E2e-dev-only-1]
# Needs ssh and sshpass: the login checks go through the real sshd on the
# login NodePort (32222), password-authenticated against FreeIPA.

set -uo pipefail

E2E_USER="${E2E_USER:-e2euser}"
E2E_GROUP="${E2E_GROUP:-e2eteam}"
E2E_PASSWORD="${E2E_PASSWORD:-E2e-dev-only-1}"
SSH_PORT=32222

failures=0

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
check "no identity on compute outside a job (no SSSD there)" no_identity_on_compute_outside_job

if ((failures > 0)); then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all checks passed"
