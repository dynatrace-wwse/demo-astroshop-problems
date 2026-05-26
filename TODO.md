# TODO

## GitLab endpoint reachability from dev container

Today `_gitlabInternalEndpoint` in `.devcontainer/util/my_functions.sh` returns the
external sslip.io ingress URL (`http://gitlab.<ip>.sslip.io`) because the
dt-enablement container runs on `--network host` and has no route to the
cluster service CIDR (`10.43.0.0/16`). kube-proxy's DNAT rules live inside the
k3d node's network namespace, not on the host.

This works for the current docker-on-host setup, but the picture changes when
we run inside **sysbox**. In a sysbox container the dev environment is more
isolated from the host network, so even the ingress URL may not resolve the
same way.

Options to revisit:

- **Pass the ingress hostname via the `Host` header** while curling the k3d
  loadbalancer IP directly, e.g.:
  ```
  curl -H "Host: gitlab.<ip>.sslip.io" http://<k3d-serverlb-ip>/api/v4/projects
  ```
  This lets us reach the ingress without depending on external DNS, which is
  the failure mode we expect under sysbox.
- Investigate whether sysbox can join the `k3d-enablement` docker network so
  the bridge IP (172.18.0.x) is routable from inside.
- As a fallback for in-cluster-only operations, run a one-shot pod via
  `kubectl run --image=curlimages/curl` (we already validated this path works
  against the cluster DNS `gitlab-webservice-default.gitlab.svc.cluster.local:8181`).

When migrating to sysbox, test each of the above before changing
`_gitlabInternalEndpoint`.
