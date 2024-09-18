<div align="center">
  <img src="https://raw.githubusercontent.com/clarknova99/talos-cluster/main/assets/kube.png" align="center" width="144px" height="144px"/>
</div>

<div align="center">
<br/>
</div>

<div align="center">

[![Talos](https://kromgo.bigwang.org/talos_version?format=badge&style=flat-square)](https://www.talos.dev/)&nbsp;&nbsp;
[![Kubernetes](https://kromgo.bigwang.org/kubernetes_version?format=badge&style=flat-square)](https://www.talos.dev/)&nbsp;&nbsp;
</div>

<div align="center">
<div align="center">

[![Cluster-Age](https://kromgo.bigwang.org/cluster_age_days?format=badge&style=flat-square)]([https://](https://github.com/clarknova99/talos-cluster/))&nbsp;
[![Nodes](https://kromgo.bigwang.org/cluster_node_count?format=badge&style=flat-square)]()&nbsp;
[![CPUs](https://kromgo.bigwang.org/cluster_cpu_core_total?format=badge&style=flat-square)]()&nbsp;
[![Memory](https://kromgo.bigwang.org/cluster_memory_total?format=badge&style=flat-square)]()&nbsp;


</div>

</div>

---

## :book:&nbsp; Overview

The repo is home for the code to automate the provisioning and management of my Kubernetes cluster.

NOTE: Slowly migrating to talos from my [k3s cluster](https://github.com/clarknova99/home-cluster) 

* [flux](https://toolkit.fluxcd.io)  watches this git repo and applies changes to Kubernetes when they are pushed to the repo.
* [renovate](https://github.com/renovatebot/renovate) monitors the repo, creating pull requests when it finds updates to dependencies.


## :gear: Core Components
* [cilium](https://cilium.io/) for networking within the cluster and load balancer for exposed services
* [cert-manager](https://cert-manager.io) to request SSL certificates to store as Kubernetes resources
* [sops](https://github.com/mozilla/sops) with [age](https://github.com/FiloSottile/age) to encrypt secrets before publishing to the repo
* [cloudflared](https://github.com/cloudflare/cloudflared): Enables Cloudflare secure access to ingresses.
* [external-dns](https://github.com/kubernetes-sigs/external-dns): Automatically syncs ingress DNS records to a DNS provider.
* [ingress-nginx](https://github.com/kubernetes/ingress-nginx): Kubernetes ingress controller used for HTTP reverse proxy of service ingresses
* [minio](https://min.io/): Object Storage for PVC & Database backups



## 🔧 Hardware
| Device | Count | Ram |  Purpose |
| --- | --- | --- | --- |
| Beelink EQ13 | 3   | 32GB |  Control Planes |
| Intel NUC11PAHi7 | 1   | 64GB |  Worker |
| Intel NUC8i5BEH | 1   | 32GB |  Worker |
| Synology 1513+ | 1   | 8GB | NAS |
| Firewalla Gold | 1   | - | Router |
| Zyxel GS1900-24E Switch | 1   | -   | Network Switch |
| APC SMT1500C | 1   | -   | UPS |

---

Based on the fantastic [flux template](https://github.com/onedr0p/cluster-template) created by [onedr0p](https://github.com/onedr0p) 
