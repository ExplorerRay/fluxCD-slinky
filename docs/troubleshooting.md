# Troubleshooting

This stack's defining trait is that it fails *silently*. Slurm schedules jobs
as root, so `sinfo` and Flux Kustomization readiness stay green while identity
underneath is completely broken — a missing CA, an offline SSSD, a randomly
allocated NodePort, none of it shows up as a controller error. Helm silently
drops keys it does not recognize, and CRD regions with
`x-kubernetes-preserve-unknown-fields: true` (see [runtime-requirements.md
](runtime-requirements.md)) accept a misplaced value, pass schema validation,
and then discard it without ever reaching the operator. So "the Kustomization
is Ready" and "Helm applied without error" prove nothing about whether the
thing you actually asked for happened — check the rendered object.

Each entry below is a real, observed failure. Symptoms are grouped by area;
use the index to jump straight to yours.

## Symptom index

| Area | Symptom |
| --- | --- |
| Cluster provisioning | [`ERROR! the role 'dynamic_groups' was not found`](#error-the-role-dynamic_groups-was-not-found) |
| Cluster provisioning | [kube-proxy/calico-node failing on ipset](#kube-proxy-crashloopbackoff-cant-use-the-ipvs-proxier-error-getting-ipset-version-andor-calico-node-stuck-01-with-felixipsetsgo-bad-return-code-from-ipset-list--name) |
| Cluster provisioning | [coredns loop detected on Debian](#coredns-crashloopbackoff-with-fatal-pluginloop-loop-127001nnnnn---53-detected-for-zone-) |
| FreeIPA | [`ipa-0` stuck `Pending`](#ipa-0-stuck-pending-events-mention-insufficient-memory) |
| FreeIPA | [`ipa-0` `0/1 Running`, no restarts, dbus error](#ipa-0-sits-01-running-with-zero-restarts-and-an-empty-or-near-empty-log-readiness-probe-reports-failed-to-connect-to-bus-no-such-file-or-directory) |
| FreeIPA | [StatefulSet spec change never takes effect](#a-change-to-the-freeipa-statefulset-spec-never-takes-effect-eg-it-still-runs-privileged-true-after-the-manifest-changed) |
| Identity and Slurm | [Everything green, no IPA user can log in](#everything-is-green-99-kustomizations-77-helmreleases-sinfo-healthy-but-no-ipa-user-can-log-in-getent-passwd-user-on-the-login-pod-returns-nothing) |
| Identity and Slurm | [Login Service on the wrong NodePort](#the-login-service-is-on-a-random-nodeport-instead-of-the-configured-one-eg-31357-rather-than-32222) |
| Identity and Slurm | [Jobs lose supplementary groups](#jobs-run-fine-but-lose-the-users-supplementary-groups--id--g-on-the-login-node-lists-several-gids-inside-a-job-only-the-primary) |
| Identity and Slurm | [`srun`: no partitions in the system](#srun-fails-with-unable-to-allocate-resources-no-partition-specified-or-system-default-partition-and-scontrol-show-partition-reports-no-partitions-in-the-system) |
| Generic traps | [A values change appears to do nothing](#a-values-change-appears-to-do-nothing) |
| Generic traps | [ConfigMap/Secret change not visible in a pod](#a-configmap-or-secret-change-is-not-visible-inside-a-running-pod) |
| Generic traps | [`sss_cache` not found](#sss_cache-is-not-found-when-trying-to-flush-the-sssd-cache-rocky-login-image) |
| Generic traps | [rook-ceph pods `Error` after reboot](#rook-ceph-exportertools-pods-sitting-in-error-after-a-node-reboot) |
| Generic traps | [`sacct` shows a numeric uid](#sacct-shows-a-numeric-uid-instead-of-a-username) |

## Cluster provisioning

### `ERROR! the role 'dynamic_groups' was not found`

`run.sh` cd's into `$KUBESPRAY_DIR` before invoking `ansible-playbook`, so this
should not occur when the cluster playbook is run through
`bash bootstrap/kubespray/run.sh cluster`.

**Cause:** `ansible-playbook` ran from somewhere other than `$KUBESPRAY_DIR` —
most often by invoking it directly, for instance to re-run a failed play by
hand. Ansible auto-loads an `ansible.cfg` only from the current directory, and
kubespray's sets `roles_path` and `library` to paths relative to itself. From
anywhere else that config never loads, and Ansible looks for kubespray's roles
under this repo instead.

**Check:**

```sh
pwd    # kubespray's playbooks expect this to be $KUBESPRAY_DIR
grep -E '^(roles_path|library)' /opt/kubespray/ansible.cfg
```

**Fix:** run it from the kubespray checkout, exactly as kubespray's own docs
do — or just use `run.sh`, which does this for you:

```sh
cd /opt/kubespray
ansible-playbook -i <repo>/bootstrap/kubespray/inventory/single.yml cluster.yml -b
```

Exporting `ANSIBLE_CONFIG`, `ANSIBLE_ROLES_PATH` and `ANSIBLE_LIBRARY` at
`$KUBESPRAY_DIR` works too, but it enumerates the settings that happen to be
relative today; `cd` covers all of them.

See [bootstrap/kubespray/README.md](../bootstrap/kubespray/README.md).

### kube-proxy CrashLoopBackOff: `can't use the IPVS proxier: error getting ipset version` and/or calico-node stuck `0/1` with `felix/ipsets.go: Bad return code from 'ipset list -name'`

On RHEL-family nodes (Rocky 10).

**Cause:** the Rocky 10 cloud image omits the `kernel-modules-extra` RPM, so
`ip_set.ko`/`xt_set.ko` do not exist on disk even though the running
kernel's config enables them. Every `ipset` call then fails. This is **not**
RHEL dropping ipset support.

**Check:**

```sh
sudo modprobe ip_set     # "Module ip_set not found" confirms it
sudo ipset list           # errors the same way
```

**Fix:**

```sh
sudo dnf install -y kernel-modules-extra-$(uname -r)
sudo modprobe ip_set xt_set
```

Best fixed before it bites: install this on every Rocky 10 node
**before** running kubespray, not after hitting the error. It is now listed
as a prerequisite in
[bootstrap/kubespray/README.md](../bootstrap/kubespray/README.md).

### coredns CrashLoopBackOff with `[FATAL] plugin/loop: Loop (127.0.0.1:NNNNN -> :53) detected for zone "."`

On Debian/systemd-resolved hosts.

**Cause:** kubespray sets kubelet's `resolvConf` to `/etc/resolv.conf`,
which under systemd-resolved is the 127.0.0.53 *stub resolver*, not a real
upstream. coredns forwards to that stub, the stub forwards back to coredns,
and the loop plugin detects it.

**Check:**

```sh
readlink -f /etc/resolv.conf     # points at systemd-resolved's stub
grep resolvConf /etc/kubernetes/kubelet-config.yaml
```

**Fix:**

```sh
# on the affected node
sudo sed -i 's#/etc/resolv.conf#/run/systemd/resolve/resolv.conf#' \
  /etc/kubernetes/kubelet-config.yaml
sudo rm -f /etc/systemd/resolved.conf.d/kubespray.conf
sudo systemctl restart systemd-resolved kubelet
kubectl -n kube-system delete pod -l k8s-app=kube-dns
```

## FreeIPA

### `ipa-0` stuck `Pending`, events mention insufficient memory

**Cause:** FreeIPA requests roughly 2GiB and a 16GiB node is already about
91% allocated by everything else in the stack.

**Check:**

```sh
kubectl -n freeipa describe pod ipa-0 | grep -A5 Events
kubectl describe node <node> | grep -A5 'Allocated resources'
```

**Fix:** give the node 24GiB.

### `ipa-0` sits `0/1 Running` with ZERO restarts and an empty or near-empty log; readiness probe reports `Failed to connect to bus: No such file or directory`

**Cause:** `/sys/fs/cgroup` is mounted read-only inside the pod, so systemd
(PID 1) cannot write `cgroup.subtree_control`, never reaches
`basic.target`, and dbus never starts — so `ipa-server-install` never even
runs. It reads like a hang, but it is a runtime misconfiguration: the pod
must use the `runc-cgroupfs` RuntimeClass with a containerd handler that has
`cgroup_writable = true`.

**Check:**

```sh
kubectl -n freeipa exec ipa-0 -- mount | grep ' /sys/fs/cgroup '   # expect rw
kubectl -n freeipa get pod ipa-0 -o jsonpath='{.spec.runtimeClassName}{"\n"}'
sudo /usr/local/bin/containerd config dump | grep -E 'cgroup_writable|SystemdCgroup'
kubectl get runtimeclass runc-cgroupfs
```

**Fix:** see [runtime-requirements.md](runtime-requirements.md) and
[bootstrap.md#freeipa](bootstrap.md#freeipa) — the pod needs
`runtimeClassName: runc-cgroupfs`
(`infrastructure/freeipa/overlays/kubeadm/runtimeclass.yaml`) and containerd
needs that handler declared with `cgroup_writable = true`
(`bootstrap/kubespray/inventory/group_vars/all/containerd.yml`), separate
from the default `runc` handler.

### A change to the FreeIPA StatefulSet spec never takes effect (e.g. it still runs `privileged: true` after the manifest changed)

**Cause:** a never-Ready pod blocks a StatefulSet rolling update, so the new
generation sits unapplied while the old pod keeps running under the old
spec.

**Check:**

```sh
kubectl -n freeipa get sts ipa \
  -o jsonpath='{.spec.template.spec.containers[0].securityContext}{"\n"}'
kubectl -n freeipa get pod ipa-0 \
  -o jsonpath='{.spec.containers[0].securityContext}{"\n"}'
# a mismatch means the update is stuck, not rejected
```

**Fix:**

```sh
kubectl -n freeipa delete pod ipa-0
```

to force the roll.

## Identity and Slurm

### Everything is green (9/9 Kustomizations, 7/7 HelmReleases, `sinfo` healthy) but no IPA user can log in; `getent passwd <user>` on the login pod returns nothing

**Cause:** SSSD has no CA to validate LDAPS against
(`ldap_tls_reqcert = demand`, `ldap_tls_cacert = /etc/ipa/ca.crt`) — either
the `freeipa-ca` ConfigMap was never created, or the values that were meant
to mount it used keys the chart ignores (see the `loginsetDefaults` trap
below), so the volume never reached the rendered CR.

**Check:**

```sh
kubectl -n slurm get configmap freeipa-ca

# the rendered CR is the authoritative place to look, not the values file
kubectl -n slurm get loginset <name> -o jsonpath='{.spec.template.spec.volumes}'
kubectl -n slurm get loginset <name> -o jsonpath='{.spec.login.volumeMounts}'

kubectl -n slurm exec <login-pod> -- ls -l /etc/ipa/ca.crt
```

**Fix:** create the ConfigMap (see [bootstrap.md](bootstrap.md)):

```sh
kubectl -n freeipa exec sts/ipa -- cat /etc/ipa/ca.crt \
  | kubectl -n slurm create configmap freeipa-ca --from-file=ca.crt=/dev/stdin
```

and set volumes/mounts under `loginsets.<name>.podSpec.volumes` and
`loginsets.<name>.login.volumeMounts` in
`applications/slurm/overlays/{kind,kubeadm}/values.yaml` — **not** under a
top-level `loginsetDefaults`, which does not exist in the chart's templates
and is silently ignored.

### The login Service is on a random NodePort instead of the configured one (e.g. 31357 rather than 32222)

**Cause:** `port`/`nodePort` were placed under `service.spec`, but the
LoginSet CRD models `service.port`/`service.nodePort` directly under
`service`. `service.spec` is a free-form `ServiceSpec` pass-through
(`x-kubernetes-preserve-unknown-fields: true`), so the values validate and
are then discarded — neither `port` nor `nodePort` is actually a
`ServiceSpec` field in Kubernetes (both live on `ServiceSpec.ports[]`).
`type` genuinely IS a `ServiceSpec` field, so it applies normally, which
makes the failure look partial rather than obviously wrong.

**Check:**

```sh
kubectl -n slurm get loginset <name> -o jsonpath='{.spec.service}{"\n"}'
kubectl -n slurm get svc <login-svc> -o jsonpath='{.spec.ports[0].nodePort}{"\n"}'
```

**Fix:** in
`applications/slurm/overlays/{kind,kubeadm}/values.yaml`, put `port`/
`nodePort` directly under `service`, and keep `type` under `service.spec`:

```yaml
loginsets:
  slinky:
    service:
      port: 22
      nodePort: 32222
      spec:
        type: NodePort
```

### Jobs run fine but lose the user's supplementary groups — `id -G` on the login node lists several gids, inside a job only the primary

**Cause:** compute-node identity, including supplementary groups, comes
from `nss_slurm` — the `slurmd` image's stock `nsswitch.conf` lists
`slurm` on `passwd` and `group` by default, no configuration required. If
a job's groups don't match, either that stock file has regressed (a
base-image change), or `LaunchParameters=enable_nss_slurm` — the one
documented switch for the feature — was removed from
`controller.extraConfMap` without `slurmctld` being restarted afterward.

**Check:**

```sh
# on the login node
id -G
# inside a job
srun id -G
```

**Fix:** set `LaunchParameters=enable_nss_slurm` via
`controller.extraConfMap` in
`applications/slurm/overlays/{kind,kubeadm}/values.yaml`, and confirm the
compute image's `/etc/nsswitch.conf` still lists `slurm` on `passwd` and
`group`. See [runtime-requirements.md](runtime-requirements.md) and
[bootstrap.md](bootstrap.md).

### `srun` fails with `Unable to allocate resources: No partition specified or system default partition`, and `scontrol show partition` reports `No partitions in the system`

**Cause:** someone patched the rendered Controller CR's `spec.extraConf`
directly. The chart's controller helper seeds its config list from
`extraConf`/`extraConfMap` and then **appends** the generated
`PartitionName` line — patching the rendered field bypasses that append
entirely and wipes out the partition definition.

**Check:**

```sh
kubectl -n slurm get controller <name> -o jsonpath='{.spec.extraConf}{"\n"}'
scontrol show partition
```

**Fix:** never patch the rendered CR. Set `controller.extraConfMap` in
values instead, then force Flux to reconcile:

```sh
flux reconcile helmrelease slurm -n slurm --force
```

## Generic traps

### A values change appears to do nothing

**Cause:** Helm silently drops unrecognised keys, and CRD regions with
`x-kubernetes-preserve-unknown-fields: true` accept anything and discard
what the operator does not read. Nothing errors, nothing shows up in
`flux get` output.

**Fix/habit:** after any values change, diff the *rendered* CR against your
intent — do not trust that the Kustomization went Ready:

```sh
kubectl get <cr> -o json
helm template ...   # or check locally before pushing
```

### A ConfigMap or Secret change is not visible inside a running pod

**Cause:** kubelet syncs projected volumes on its own period; the update
lands roughly 1-2 minutes **after** `flux reconcile` returns, not
immediately.

**Fix:** wait, or delete the pod to force an immediate remount.

### `sss_cache` is not found when trying to flush the SSSD cache (Rocky login image)

**Fix:** the Rocky login image ships no `sss_cache` binary. Remove the mmap
fast-cache files under `/var/lib/sss/mc/` and the on-disk
`cache_freeipa.ldb`, then restart the `sssd` process:

```sh
rm -f /var/lib/sss/mc/passwd /var/lib/sss/mc/group /var/lib/sss/mc/initgroups
rm -f /var/lib/sss/db/cache_freeipa.ldb
pkill sssd   # or restart via the container's process supervisor
```

### `rook-ceph` exporter/tools pods sitting in `Error` after a node reboot

**Cause:** these are stale pods left over from before the reboot; healthy
replacements are already running alongside them. Not itself a fault.

**Fix:**

```sh
kubectl -n rook-ceph delete pod --field-selector status.phase=Failed
```

### `sacct` shows a numeric uid instead of a username

**Cause:** it was run from a pod with no SSSD — e.g. the controller, which
the chart gives no `sssdConfRef` at all.

**Fix:** run `sacct` from the login pod instead, where SSSD can resolve the
uid.

<!-- vim: set ft=markdown ff=unix fenc=utf-8 et sw=2 ts=2 sts=2 tw=79: -->
