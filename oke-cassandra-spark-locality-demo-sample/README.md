<!--
Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
-->

# Cassandra and Spark Data Locality Demo on OCI OKE

This automation deploys a complete environment on Oracle Kubernetes
Engine (OKE) to demonstrate data locality between Apache Cassandra and
Apache Spark using pod affinity and node labeling. The setup ensures
Spark reads data from colocated Cassandra pods, reducing cross-node
traffic.

# What it deploys

Using Terraform, the stack provisions a fully automated infrastructure
and Kubernetes environment on OCI.

## Network Module

-   Virtual Cloud Network (VCN)
-   Internet Gateway
-   NAT Gateway
-   Service Gateway
-   Subnets
    -   Public subnet (bastion host)
    -   Private subnet (OKE worker nodes)
-   Route Tables
-   Security Lists

## OKE Module

-   OKE Cluster
    -   Kubernetes version: v1.34.1
-   Node Pool
    -   3 worker nodes

## Bastion Module

-   Compute instance with public IP for SSH access
-   Instance Principal authentication enabled
-   Automatically installs:
    -   kubectl
    -   helm
    -   OCI CLI
    -   Python 
  
The bastion executes the full demo automatically via cloud-init:

1.  Configures kubectl access to the OKE cluster
2.  Labels 2 of the 3 worker nodes for data locality
3.  Installs cert-manager
4.  Installs K8ssandra Operator (Helm chart v1.13.0)
5.  Deploys a 2-node Cassandra cluster (Cassandra 4.0.6)
6.  Applies node affinity (`spark-locality`) to colocate Cassandra pods
7.  Initializes keyspace, table, and test data in Cassandra
8.  Creates the `spark` namespace
9.  Creates a ConfigMap containing the Spark read script
10. Deploys Spark master and 2 Spark workers
    (docker.io/apache/spark:3.5.1)
11. Runs a Spark Job (`spark-read-cassandra`) using:
    -   Apache Spark 3.5.1
    -   Cassandra connector
        `com.datastax.spark:spark-cassandra-connector_2.12:3.3.0`

# Pre-Requisites

-   OCI tenancy
-   Target compartment
-   Dynamic group for the bastion instance
-   IAM policies allowing:
    -   OKE management
    -   Network access
    -   Block volume usage
    -   Instance principal authentication

# Deployment

## Deploy via OCI Resource Manager

1.  Upload the Terraform code to OCI Resource Manager.
2.  Create a new stack in the desired compartment.
3.  Provide required input variables.
4.  Apply the stack.
   
The infrastructure and Kubernetes workloads are deployed automatically.

# Post-Deployment: What to Expect

After deployment completes, it takes more time for the cloud-init actions to complete (~ 30 minutes). Monitor this in `/var/log/oke-automation.log`.

1.  SSH into the bastion (public IP available in OCI Console):

        ssh opc@<bastion-public-ip>

2.  Validate node and pod placement:

        kubectl get nodes
        kubectl get pods -A -o wide

Expected:

-   2 Cassandra pods scheduled on 2 labeled nodes
-   2 Spark workers colocated on the same nodes as Cassandra
-   The 3rd OKE node remains unused for Spark/Cassandra workloads

3.  View Spark job output:

        kubectl logs job/spark-read-cassandra -n spark

You should see successful reads from Cassandra.

# Monitoring Data Locality

To confirm that the demo is working as expected:

## VCN Flow Logs

1.  Enable Flow Logs on the worker subnet.
2.  Inspect traffic patterns between nodes.
   
Spark primarily reads from Cassandra pods running on the same nodes.

## Kubernetes Validation

Check pod placement and labels:

    kubectl get pods -A -o wide
    kubectl get nodes --show-labels

Verify that:

-   Two nodes are labeled with `spark-locality=true`
-   Cassandra and Spark workers share the same node IPs

# Implementation Details

-   Kubernetes: OKE v1.34.1
-   Cassandra:
    -   Deployed via K8ssandra Operator Helm chart v1.13.0
-   Spark:
    -   Apache Spark container image: docker.io/apache/spark:3.5.1
    -   Spark master and workers deployed as Kubernetes Pods
    -   Spark read workload deployed as Kubernetes Job

# Destroying the Stack

Before destroying the stack, it's recommended to clean up Kubernetes resources to ensure no pods or CRDs block the node pool or namespace deletion:

```
# Uninstall Helm releases
helm uninstall k8ssandra-operator -n k8ssandra-operator || true
helm uninstall cert-manager -n cert-manager || true

# Delete namespaces (and wait for resources to terminate)
kubectl delete namespace spark k8ssandra-operator cert-manager --ignore-not-found --wait=true

# Delete CRDs to avoid lingering finalizers
kubectl delete crd k8ssandraclusters.k8ssandra.io --ignore-not-found

```

Once cleanup completes, you can safely destroy the stack. Use the ORM to destroy the stack from the console.


