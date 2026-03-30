
# Manage workload on multiple OKE clusters using karmada

## Introduction

Karmada (short for Kubernetes Armada) is a management platform that allows you to run cloud-native applications seamlessly across multiple Kubernetes clusters and cloud environments—without requiring any changes to your applications. By leveraging Kubernetes-native APIs and advanced scheduling features, Karmada delivers an open and truly multi-cloud Kubernetes experience.

Designed for multi-cloud and hybrid cloud use cases, Karmada provides turnkey automation for managing applications across clusters. Its core capabilities include centralized management, high availability, automated failure recovery, and intelligent traffic scheduling.


### Objectives

- Install `karmada` components on a host OKE cluster

- Join 2 OKE member clusters to karmada

- Create deployment with pods spread accross 2 OKE clusters

### Prerequisites

- Active tenancy on OCI

- An user with sufficient privileges to create the resources

  > **Note:** You can only use workload identity for enhanced clusters.

- A compartment already created where to deploy resources


- Dynamic group for all VMs in the compartment

  ```
  All {instance.compartment.id = 'ocid1.compartment.oc1...'}
  ```

- Policy to run oci cli commands using instance principal 

  ```
  allow dynamic-group <dynamic-group-name> to manage cluster-family in compartment <compartment-name>
  ```


## Task 1: Create necessary resources for demo

> **Note:** The following steps show how to deploy 3 OKE clusters and 1 VM that will be used during the demo

1. Clone the terraform files from github.

2. Use Oracle Resource Manager to create and apply the stack

  - using the hamburger menu, go to Oracle Resource Manager
  - choose `Stacks`
  - click `Create stack`
  - select `My configuration` radio button
  - in `My configuration` section make sure `Folder` is selected; choose the folder where you previously cloned the git repo; click `Upload`
  - give the stack a meaningful name
  - click `Next`
  - choose the ssh public key that will be used to connect to VM
  - choose the compartment where the resources will be created
  - click `Next`
  - on the next screen select `Run apply` check-box
  - click `Create`

3. Get the public IP of the VM

  - upon successful run of the job from previous step, the last line in log should depict the public IP of the VM. Record it for later use


## Task 2: Install karmada on host cluster

1. Using the IP previously obtained, connect via ssh to VM, e.g. :
   ```
   ssh -i <private-ssh-key> opc@<public-IP>
   ```

2. Switch to root user

    ```
   sudo su -
   ```

3. Install karmada components on host cluster

   ```
   karmadactl init
   ```

## Task 3: Join OKE cluster members

1. Join cluster member1

      ```
      karmadactl --kubeconfig /etc/karmada/karmada-apiserver.config  join member1 --cluster-kubeconfig=$HOME/.kube/config-k1
      ```

2. Join cluster member2

      ```
      karmadactl --kubeconfig /etc/karmada/karmada-apiserver.config  join member2 --cluster-kubeconfig=$HOME/.kube/config-k2
      ```

3. Display member clusters

   ```
   karmadactl --kubeconfig /etc/karmada/karmada-apiserver.config  get clusters
   ```


## Task 4: Deploy workload on karmada

1. Create a deployment and a propagation policy. You can either upload [deployment.yaml](deployment.yaml "deployment.yaml")  and [propagationpolicy.yaml](propagationpolicy.yaml "propagationpolicy.yaml") or create them manually.


2. set KUBECONFIG to point to the karmada-api server 

   ```
   export KUBECONFIG=/etc/karmada/karmada-apiserver.config
   ```

3. Create the deployment and the corresponding propagation policy

   ```
   kubectl apply -f deployment.yaml
   kubectl apply -f propagationpolicy.yaml
   ```
4. Verify the deployment

   ```
   karmadactl  get deployment --operation-scope all
   ```

   Output should be similar to:
   ```
   # karmadactl  get deployment --operation-scope all
   NAME    CLUSTER   READY   UP-TO-DATE   AVAILABLE   AGE   ADOPTION
   nginx   Karmada   3/3     3            3           22m   -
   nginx   member2   2/2     2            2           22m   Y
   nginx   member1   1/1     1            1           22m   Y
   ```
Notice that out of the 3 pods, 2 are running on member2 and 1 on member1

## Task 5: Clean-up

1. Un-install karmada components from host cluster
```
karmadactl --kubeconfig /root/.kube/config deinit
```

2. Destroy the resources created using terraform stack

- Navigate back to Oracle Resource Manager
- Select the stack you created
- click `Destroy`
