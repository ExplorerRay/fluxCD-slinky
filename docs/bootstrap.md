# Bootstrap

Create the Kubernetes cluster before installing Flux. Flux should start only
after the target cluster can run normal pods.

## Where to look

- [stack-overview.md](stack-overview.md) — architecture: components,
  dependency order, identity design.
- [runtime-requirements.md](runtime-requirements.md) — container-runtime and
  kernel prerequisites behind FreeIPA's systemd-in-container, and why.
- [verification.md](verification.md) — prove the cluster and identity stack
  actually work, layer by layer.
- [troubleshooting.md](troubleshooting.md) — symptom-keyed index of observed
  failures.
- [../bootstrap/kind/README.md](../bootstrap/kind/README.md) /
  [../bootstrap/kubespray/README.md](../bootstrap/kubespray/README.md) — the
  platform runbooks: prerequisites, sizing, exact commands, teardown.

## kind

See [bootstrap/kind/README.md](../bootstrap/kind/README.md) for
prerequisites, resource sizing, and the exact setup/teardown commands.

kind allows you to run Kubernetes clusters in Docker containers, useful for
local development. The cluster name is always fixed to `kind` regardless of
variant, so node hostnames stay deterministic.

After cluster creation, confirm it is ready — see
[verification.md](verification.md).

### Flux path

Deploy Flux with the entrypoint matching the variant you created:

```yaml
path: ./clusters/kind-single   # single-node kind cluster
path: ./clusters/kind-multi    # multi-node kind cluster
```

## kubeadm

See [bootstrap/kubespray/README.md](../bootstrap/kubespray/README.md) for
prerequisites, inventory setup, and the exact provisioning commands.

kubeadm with Kubespray is used to provision Kubernetes clusters on bare metal
or VMs. `clusters/kubeadm-single` and `clusters/kubeadm-multi` are the Flux
entrypoints for the kubeadm-based cluster variants. Kubespray provisions the
cluster and installs Calico before Flux starts.

The non-privileged FreeIPA StatefulSet (`infrastructure/freeipa`) needs a
containerd runtime handler with `cgroup_writable = true`, selected via a
RuntimeClass. Kubespray and Flux configure this with no manual step —
but get it wrong and the pod hangs at `0/1` with an empty log. See
[runtime-requirements.md](runtime-requirements.md).

Kubespray clusters range from single-node (control-plane, etcd, and worker
roles on one machine) to multi-node (separate control-plane and worker
nodes) — see
[bootstrap/kubespray/README.md](../bootstrap/kubespray/README.md) for the
example inventories. `inventory/single.yml` maps to Flux path
`./clusters/kubeadm-single` (OSD host `node1`); `inventory/multi.yml` maps to
`./clusters/kubeadm-multi` (OSD host `node2`).

### Calico network plugin

In the Kubespray inventory, use Calico as the network plugin:

```yaml
kube_network_plugin: calico
container_manager: containerd
```

For a simple on-premises cluster, start with VXLAN unless you intentionally want
BGP-routed pod networks:

```yaml
calico_datastore: "kdd"
calico_network_backend: vxlan
calico_vxlan_mode: "Always"
calico_ipip_mode: "Never"
nat_outgoing: true
```

After Kubespray completes, confirm the cluster is ready — see
[verification.md](verification.md).

### Flux path

Deploy Flux with the entrypoint matching the inventory you provisioned:

```yaml
path: ./clusters/kubeadm-single   # inventory/single.yml
path: ./clusters/kubeadm-multi    # inventory/multi.yml
```

## Rook-Ceph loop device preparation

The dev-grade single-node Ceph cluster (`infrastructure/rook-ceph`) has no spare
disk, partition, or LV. Its single OSD is backed by a **loopback device over a
sparse file**: `/dev/loop100` backed by `/var/lib/rook/osd0.img` (200G sparse,
allocated on demand). Loop attachments do **not** survive a reboot, so the
device must be (re)created on every boot **before** kubelet — and therefore Rook
and Ceph — start.

### Kernel modules

The host kernel must provide the `rbd` and `ceph` modules. Load and persist
them:

```sh
sudo modprobe rbd ceph
echo -e "rbd\nceph" | sudo tee /etc/modules-load.d/rook-ceph.conf
```

### kubeadm: systemd unit

Install the boot-time systemd unit and helper script from
`bootstrap/rook-ceph/`:

```sh
sudo install -m 0755 bootstrap/rook-ceph/rook-osd-loop.sh /usr/local/sbin/rook-osd-loop.sh
sudo install -m 0644 bootstrap/rook-ceph/rook-osd-loop.service /etc/systemd/system/rook-osd-loop.service
sudo systemctl daemon-reload
sudo systemctl enable --now rook-osd-loop.service
```

The unit creates the sparse file with `truncate` if missing and attaches it
with `losetup`, ordered `Before=kubelet.service`. See
[bootstrap/rook-ceph/README.md](../bootstrap/rook-ceph/README.md).

### kind: setup step

`bootstrap/kind/setup.sh <single|multi>` creates the sparse file and runs
`losetup /dev/loop100` on the host before `kind create cluster`. The loop
device and its backing image are mounted into the node that hosts the OSD via
`extraMounts` in `bootstrap/kind/kind-config-single.yaml` (the sole
control-plane node) or `bootstrap/kind/kind-config-multi.yaml` (a worker
node). Re-running `setup.sh` after a reboot re-attaches the device
idempotently.

### Node hostname

Each cluster entrypoint variant already bakes in a deterministic OSD node
hostname, so no manual edit is normally required:

| Variant           | OSD node hostname   |
| ----------------- | -------------------- |
| `kind-single`      | `kind-control-plane` |
| `kind-multi`       | `kind-worker`         |
| `kubeadm-single`   | `node1`               |
| `kubeadm-multi`    | `node2`               |

These come from `infrastructure/rook-ceph/overlays/<variant>/node-values.yaml`,
which is layered on top of the shared `overlays/kind` or `overlays/kubeadm`
values via a second HelmRelease `valuesFrom` entry. Only custom setups —
a kubespray inventory that uses different hostnames than `node1`/`node2`, or a
kind cluster created under a different `--name` — need to edit the relevant
`node-values.yaml` to match the real node hostname:

```sh
kubectl get nodes -o name
```

## FreeIPA

The in-cluster FreeIPA identity server (`infrastructure/freeipa`) is a
hand-rolled StatefulSet reachable at `ipa.freeipa.svc.cluster.local` (realm
`FREEIPA.SVC.CLUSTER.LOCAL`). Slurm's login and compute pods authenticate
against it over LDAPS via SSSD.

Flux brings the components up on its own (FreeIPA, then slurm, by dependency
order). Only the manual actions Flux cannot perform are listed below. The dev
credentials are already committed (plaintext) in the per-cluster `secret.yaml`
files — change them there if desired before deploying.

The FreeIPA image runs systemd as PID 1, which needs cgroup and mount access
that Kubernetes does not grant by default — and getting this wrong fails
silently. On kubeadm, the non-privileged FreeIPA pod specifically needs a
containerd runtime handler with `cgroup_writable = true` selected via a
RuntimeClass; without it the pod hangs at `0/1 Running` with an empty log,
because systemd can never write `cgroup.subtree_control`, dbus never starts,
and `ipa-server-install` never runs. It reads like a hang, not a
misconfiguration, so it is easy to miss. See
[runtime-requirements.md](runtime-requirements.md) for both platform
accommodations (kind and kubeadm), the privileged-vs-user-namespace choice
and its kernel-version floor, and the hardening options that look reasonable
but break the deployment.

Once FreeIPA and Slurm are otherwise up, two manual steps remain — Flux
cannot perform either:

1. **Extract the FreeIPA CA into the slurm namespace.** Once FreeIPA is healthy
   (`kubectl -n freeipa exec sts/ipa -- ipactl status`; the first install takes
   several minutes), copy its CA into the `freeipa-ca` ConfigMap. SSSD validates
   the LDAPS certificate against this CA (`ldap_tls_reqcert = demand`), and the
   ConfigMap is not a git manifest, so it must be created by hand. It MUST exist
   before the slurm pods start, or the CA volume mount leaves them Pending:

   ```sh
   kubectl -n freeipa exec sts/ipa -- cat /etc/ipa/ca.crt \
     | kubectl -n slurm create configmap freeipa-ca --from-file=ca.crt=/dev/stdin
   ```

2. **Create users and groups.** FreeIPA starts empty, so Slurm cannot
   resolve anyone yet. Two ways to do this: the web UI, or a CLI path that
   works headlessly (no browser, scriptable, works on a bare server).

   **Web UI.** The management console is exposed (DEV ONLY) via
   the `ipa-web` NodePort on **30443**. FreeIPA enforces a referer/host check
   against its FQDN, so browse it by that name rather than the raw node IP — add
   to your client `/etc/hosts`:

   ```
   <node-ip>  ipa.freeipa.svc.cluster.local
   ```

   then open `https://ipa.freeipa.svc.cluster.local:30443/ipa/ui`, log in as
   `admin` (dev password from the FreeIPA secret), and add users/groups under
   **Identity**. Trust the FreeIPA CA (`ca.crt`) to avoid the TLS warning. On
   kind (where NodePorts aren't host-mapped by default) use `kubectl -n freeipa
   port-forward sts/ipa 30443:443` and browse `https://…:30443/ipa/ui` instead.

   **CLI.** No NodePort or browser needed — exec straight into the IPA pod:

   ```sh
   kubectl -n freeipa exec sts/ipa -- bash -c '
     echo "<admin-password>" | kinit admin
     ipa user-add slurmuser --first=Slurm --last=User --shell=/bin/bash
     printf "<password>\n<password>\n" | ipa passwd slurmuser
     ipa user-mod slurmuser --setattr=krbpasswordexpiration=20301231000000Z'
   ```

   Both passwords are inline above, which puts them in your shell history
   and in the pod's process arguments, readable by anything that can `ps` in
   that container. That is acceptable only because these are DEV ONLY
   credentials; for anything real, drop the literals and let `kinit` and
   `ipa passwd` prompt interactively (`kubectl exec -it`).

   The last line matters: `ipa passwd` sets the password but leaves it
   **expired**, which forces a password change at the next login. That
   interactive prompt blocks non-interactive SSH entirely (e.g. `sbatch`
   invoked from a script, or any automated test), so push the Kerberos
   password-expiration attribute out past it as shown.

   Groups work the same way from the CLI (`ipa group-add`,
   `ipa group-add-member --users=<user>`). SSSD caches aggressively, so a
   membership change may not be visible in a login pod until the cache is
   flushed (`sss_cache -E; pkill -HUP sssd` in the login pod) or its TTL
   expires on its own — and the Rocky login image ships no `sss_cache`
   binary, see
   [troubleshooting.md](troubleshooting.md#sss_cache-is-not-found-when-trying-to-flush-the-sssd-cache-rocky-login-image).

<!-- vim: set ft=markdown ff=unix fenc=utf-8 et sw=2 ts=2 sts=2 tw=79: -->
