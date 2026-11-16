# Mac boxes

A Mac can't be a box for now. Every environment runs in a VM of its own
([architecture.md](../architecture.md#environment-vms)), and a Mac box
was a Flatcar VM under vfkit, so its environments would run nested on
Apple's hypervisor, where nested virtualization is poor. Mac boxes went
with shared Docker, and come back with
[#180](https://github.com/ntodd/foreman/issues/180): the agent on macOS,
with environment VMs on Apple's hypervisor directly.

Until then:

- **Use a Linux machine as the box**: Debian or Ubuntu on amd64 with KVM
  ([personal.md](personal.md#5-add-the-desktop-as-a-box)), or a Flatcar
  VM on one ([flatcar.md](flatcar.md)). Your Mac reaches its
  environments over the tailnet as before.
- **If you had a Mac box**, move its work off before upgrading: push
  every environment's work, then destroy its environments and remove the
  box ([upgrading.md](upgrading.md#moving-to-environment-vms) has the
  steps).
