# README

## Introduction

A virtual cluster is a cluster that runs on top of another cluster. The vCluster implementation adheres to this definition.

Using virtual clusters greatly improves the efficiency of resource usage, simplifies management, speeds up the provisioning time, thus reducing costs.


### Prerequisites

- Active tenancy on OCI

- A user with sufficient privileges to create the resources

- A compartment already created where to deploy resources

- ssh key-pair for connecting to managing VM



## Task 1: Create necessary resources for demo

> **Note:** The following steps show how to deploy 1 OKE cluster and 1 VM

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

  - upon successful run of the job from previous step, the last line in log should depict the public IP of the VM. Record it for later use.


## Task 2: Connect to management VM and verify OKE conectivity

1. Using the IP previously obtained, connect via ssh to VM, e.g. :
   ```
   ssh -i <private-ssh-key> opc@<public-IP>
   ```

2. Verify OKE connectivity

   ```
   kubectl get nodes
   ```
**Note:** If kubectl hangs, logout and re-login after a couple of minutes, to allow cloud-init to finish.

## Task 3: Create your first vCluster

1. Create vCluster

      ```
      [opc@vcluster-vm ~]$ vcluster create my-vcluster --namespace team-x --expose
      07:41:18 info Creating namespace team-x
      07:41:18 info Create vcluster my-vcluster...
      07:41:18 info execute command: helm upgrade my-vcluster /tmp/vcluster-0.30.0.tgz-1320876652 --create-namespace --kubeconfig /tmp/1292545132 --namespace team-x --install --repository-config='' --values /tmp/1638001075
      07:41:19 done Successfully created virtual cluster my-vcluster in namespace team-x
      07:41:31 info Waiting for vcluster to come up...
      07:41:35 info vcluster is waiting, because vcluster pod my-vcluster-0 has status: Init:0/1
      07:41:45 info vcluster is waiting, because vcluster pod my-vcluster-0 has status: Init:0/1
      07:41:56 info vcluster is waiting, because vcluster pod my-vcluster-0 has status: Init:0/1
      07:42:07 info vcluster is waiting, because vcluster pod my-vcluster-0 has status: Init:0/1
      07:42:18 info vcluster is waiting, because vcluster pod my-vcluster-0 has status: Init:0/1
      07:42:28 info vcluster is waiting, because vcluster pod my-vcluster-0 has status: PodInitializing
      07:42:43 done vCluster is up and running
      07:42:43 info Using vcluster my-vcluster load balancer endpoint: 129.80.183.102
      07:42:43 done Switched active kube context to vcluster_my-vcluster_team-x_host-vcluster
      - Use `vcluster disconnect` to return to your previous kube context
      - Use `kubectl get namespaces` to access the vcluster 
      ```

2. List the newly created vCluster 

      ```
      [opc@vcluster-vm ~]$ vcluster list

            NAME     | NAMESPACE | STATUS  | VERSION | CONNECTED |  AGE
       --------------+-----------+---------+---------+-----------+--------
         my-vcluster | team-x    | Running | 0.30.0  | True      | 9m47s
      ```

3. Verify the current context

   ```
   [opc@vcluster-vm ~]$ kubectl config get-contexts
      CURRENT   NAME                                        CLUSTER                                     AUTHINFO                                    NAMESPACE
                host-vcluster                               cluster-cxvtii2rh4a                         user-cxvtii2rh4a
      *         vcluster_my-vcluster_team-x_host-vcluster   vcluster_my-vcluster_team-x_host-vcluster   vcluster_my-vcluster_team-x_host-vcluster
   ```
> **Note:** The current context has been switched to the new vCluster

## Task 4: Deploy workload on vCluster

1. Create a deployment

   ```
   [opc@vcluster-vm ~]$ kubectl create deployment nginx-deployment --image docker.io/nginx:latest --replicas 3
   deployment.apps/nginx-deployment created
   ```

2. list the created resources

   ```
   [opc@vcluster-vm ~]$ kubectl get all
   NAME                                  READY   STATUS    RESTARTS   AGE
   pod/nginx-deployment-76576c8f-872p7   1/1     Running   0          12s
   pod/nginx-deployment-76576c8f-cwn6q   1/1     Running   0          12s
   pod/nginx-deployment-76576c8f-zn9r2   1/1     Running   0          12s

   NAME                 TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)   AGE
   service/kubernetes   ClusterIP   10.96.111.95   <none>        443/TCP   15m

   NAME                               READY   UP-TO-DATE   AVAILABLE   AGE
   deployment.apps/nginx-deployment   3/3     3            3           12s

   NAME                                        DESIRED   CURRENT   READY   AGE
   replicaset.apps/nginx-deployment-76576c8f   3         3         3       12s
   ```

3. Disconnect from vCluster context

   ```
   [opc@vcluster-vm ~]$ vcluster disconnect
   08:01:16 info Successfully disconnected and switched back to the original context: host-vcluster
   ```
4. Confirm the current context

   ```
   [opc@vcluster-vm ~]$ kubectl config get-contexts
   CURRENT   NAME                                        CLUSTER                                     AUTHINFO                                    NAMESPACE
   *         host-vcluster                               cluster-cxvtii2rh4a                         user-cxvtii2rh4a
            vcluster_my-vcluster_team-x_host-vcluster   vcluster_my-vcluster_team-x_host-vcluster   vcluster_my-vcluster_team-x_host-vcluster
   ```

5. List all namespaces

   ```
   [opc@vcluster-vm ~]$ kubectl get ns
   NAME              STATUS   AGE
   default           Active   40m
   kube-node-lease   Active   40m
   kube-public       Active   40m
   kube-system       Active   40m
   team-x            Active   29m
   ```
6. List vcluster's resources from host cluster's perspective

   ```
   [opc@vcluster-vm ~]$ kubectl get all -n team-x
   NAME                                                          READY   STATUS    RESTARTS   AGE
   pod/coredns-75bb76df-l8jjm-x-kube-system-x-my-vcluster        1/1     Running   0          28m
   pod/my-vcluster-0                                             1/1     Running   0          29m
   pod/nginx-deployment-76576c8f-872p7-x-default-x-my-vcluster   1/1     Running   0          13m
   pod/nginx-deployment-76576c8f-cwn6q-x-default-x-my-vcluster   1/1     Running   0          13m
   pod/nginx-deployment-76576c8f-zn9r2-x-default-x-my-vcluster   1/1     Running   0          13m

   NAME                                           TYPE           CLUSTER-IP      EXTERNAL-IP      PORT(S)                  AGE
   service/kube-dns-x-kube-system-x-my-vcluster   ClusterIP      10.96.112.98    <none>           53/UDP,53/TCP,9153/TCP   28m
   service/my-vcluster                            LoadBalancer   10.96.111.95    129.80.183.102   443:30538/TCP            29m
   service/my-vcluster-headless                   ClusterIP      None            <none>           443/TCP                  29m
   service/my-vcluster-node-10-0-3-186            ClusterIP      10.96.144.206   <none>           10250/TCP                13m
   service/my-vcluster-node-10-0-3-83             ClusterIP      10.96.120.108   <none>           10250/TCP                28m

   NAME                           READY   AGE
   statefulset.apps/my-vcluster   1/1     29m
   ```   

## Task 5: Export vCluster kubeconfig

1. View the kubeconfig file of the vCluster

   ```
      [opc@vcluster-vm ~]$ vcluster connect my-vcluster --print
   ```
   Notice the "server" value - it contain the Load Balancer IP used when vCluster was created (via "expose" flag)
   ```
   [opc@vcluster-vm ~]$ kubectl get svc my-vcluster -n team-x
   ```

2. Save the kube config in a file to be distributed and used separately by users
   ```
   [opc@vcluster-vm ~]$ vcluster connect my-vcluster --print > vcluster.config
   ```

3. Use the kubeconfig file to run commands against the vCluster
   ```
   [opc@vcluster-vm ~]$ kubectl --kubeconfig=vcluster.config get ns
   NAME              STATUS   AGE
   default           Active   72m
   kube-node-lease   Active   72m
   kube-public       Active   72m
   kube-system       Active   72m
   ```

## Task 6: Clean-up

1. Delete the vCluster created in previous steps - this will also delete the LoadBalancer (optional)
   ```
   [opc@vcluster-vm ~]$ vcluster delete my-vcluster
   09:50:04 info Delete vcluster my-vcluster...
   09:50:05 done Successfully deleted virtual cluster my-vcluster in namespace team-x
   09:50:05 info Deleting CoreDNS components...
   09:50:05 done Successfully deleted virtual cluster namespace team-x
   09:50:05 info Waiting for virtual cluster to be deleted...
   09:50:30 done Virtual Cluster is deleted
   ```

2. Destroy the resources created using terraform stack

- Navigate back to Oracle Resource Manager
- Select the stack you created
- click `Destroy`


