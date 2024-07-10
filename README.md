<div align="center">
  <img src="https://camo.githubusercontent.com/eec89a711423634860ccdce3337ba8f922c424d921650684c69fc12d051e2a39/68747470733a2f2f692e696d6775722e636f6d2f676476426b4e452e706e67" align="center" width="144px" height="144px"/>
</div>

<div align="center">
<br/>
</div>

<div align="center">

[![Talos](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.devbu.io%2Fquery%3Fformat%3Dendpoint%26metric%3Dtalos_version&style=for-the-badge&logo=talos&logoColor=white&color=blue&label=%20)](https://www.talos.dev/)&nbsp;&nbsp;
[![Kubernetes](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.devbu.io%2Fquery%3Fformat%3Dendpoint%26metric%3Dkubernetes_version&style=for-the-badge&logo=kubernetes&logoColor=white&color=blue&label=%20)](https://www.talos.dev/)&nbsp;&nbsp;
</div>

<div align="center">


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
| --- | --- | --- | --- | --- |
| Intel NUC11PAHi7 | 1   | 64GB |  Control Plane / Worker |
| Intel NUC8i5BEH | 1   | 32GB |  Control Plane / Worker |
| Alienware Aurora | 1   | 24GB |  Kubernetes Worker |
| Alienware X51  | 1   | 16GB |  Control Plane / Worker |
| Raspberry Pi 4 | 4   | 8GB |  Kubernetes Workers |
| Synology 1513+ | 1   | 8GB | NAS |
| Firewalla Gold | 1   | - | Router |
| Zyxel GS1900-24E Switch | 1   | -   | Network Switch |
| APC SMT1500C | 1   | -   | UPS |

---

Based on the fantastic [flux template](https://github.com/onedr0p/cluster-template) created by [onedr0p](https://github.com/onedr0p) 
