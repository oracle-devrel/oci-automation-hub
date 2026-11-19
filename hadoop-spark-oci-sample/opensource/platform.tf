# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

###############################################################################
# In-cluster platform manifests + operator bootstrap
#
# Single-apply one-click in Resource Manager requires the platform to be
# installed from INSIDE the VCN (the RM/CLI runner cannot reach a private API
# endpoint). So instead of the kubernetes/helm Terraform providers, the platform
# is rendered here as Kubernetes manifests (yamlencode of HCL objects) and a
# helm command, then handed to the module operator's cloud-init (see oke.tf).
# The operator applies them with kubectl/helm using its instance-principal
# kubeconfig - no runner-to-API connectivity needed.
#
# Toggle-driven: HDFS+KDC when deploy_hdfs, Spark Operator when deploy_spark,
# Object Storage wiring when deploy_object_storage.
###############################################################################

locals {
  # ---- Shared Kerberos config ---------------------------------------------
  krb5_conf = <<-EOT
    [libdefaults]
      default_realm = ${local.realm}
      dns_lookup_realm = false
      dns_lookup_kdc = false
      rdns = false
      udp_preference_limit = 1
      ticket_lifetime = 24h
      renew_lifetime = 7d
      forwardable = true
      default_tkt_enctypes = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96
      default_tgs_enctypes = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96
      permitted_enctypes   = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96

    [realms]
      ${local.realm} = {
        kdc = ${local.kdc_host}
        admin_server = ${local.kdc_host}
      }

    [domain_realm]
      .svc.cluster.local = ${local.realm}
      svc.cluster.local = ${local.realm}
  EOT

  kdc_conf = <<-EOT
    [kdcdefaults]
      kdc_ports = 88
      kdc_tcp_ports = 88

    [realms]
      ${local.realm} = {
        acl_file = /var/kerberos/krb5kdc/kadm5.acl
        supported_enctypes = aes256-cts-hmac-sha1-96:normal aes128-cts-hmac-sha1-96:normal
        max_life = 24h 0m 0s
        max_renewable_life = 7d 0h 0m 0s
      }
  EOT

  core_site_xml = <<-EOT
    <?xml version="1.0"?>
    <configuration>
      <property><name>fs.defaultFS</name><value>${local.hdfs_default}</value></property>
      <property><name>hadoop.security.authentication</name><value>kerberos</value></property>
      <property><name>hadoop.security.authorization</name><value>true</value></property>
      <property><name>hadoop.rpc.protection</name><value>privacy</value></property>
      <property><name>hadoop.security.auth_to_local</name><value>DEFAULT</value></property>
    </configuration>
  EOT

  hdfs_site_xml = <<-EOT
    <?xml version="1.0"?>
    <configuration>
      <property><name>dfs.replication</name><value>${local.effective_replication}</value></property>
      <property><name>dfs.namenode.name.dir</name><value>file:///hadoop/dfs/name</value></property>
      <property><name>dfs.datanode.data.dir</name><value>file:///hadoop/dfs/data</value></property>
      <property><name>dfs.namenode.rpc-bind-host</name><value>0.0.0.0</value></property>
      <property><name>dfs.namenode.servicerpc-bind-host</name><value>0.0.0.0</value></property>
      <property><name>dfs.namenode.http-bind-host</name><value>0.0.0.0</value></property>
      <property><name>dfs.namenode.datanode.registration.ip-hostname-check</name><value>false</value></property>
      <property><name>dfs.permissions.enabled</name><value>true</value></property>
      <property><name>dfs.block.access.token.enable</name><value>true</value></property>
      <property><name>dfs.data.transfer.protection</name><value>privacy</value></property>
      <property><name>dfs.http.policy</name><value>HTTP_ONLY</value></property>
      <!-- Kerberos + SASL data transfer (privacy) still authenticate & encrypt
           block transfer. This waives the secure-DataNode requirement to use
           privileged ports (<1024, needs jsvc/root) OR HTTPS for the web UI -
           unnecessary here: private cluster, ClusterIP-only, NetworkPolicy-
           isolated, SPNEGO-authenticated web UI. Avoids a full TLS layer. -->
      <property><name>ignore.secure.ports.for.testing</name><value>true</value></property>
      <property><name>dfs.datanode.address</name><value>0.0.0.0:9866</value></property>
      <property><name>dfs.datanode.http.address</name><value>0.0.0.0:9864</value></property>
      <property><name>dfs.datanode.ipc.address</name><value>0.0.0.0:9867</value></property>
      <property><name>dfs.namenode.kerberos.principal</name><value>hdfs/_HOST@${local.realm}</value></property>
      <property><name>dfs.namenode.keytab.file</name><value>/keytabs/hdfs.keytab</value></property>
      <property><name>dfs.namenode.kerberos.internal.spnego.principal</name><value>HTTP/_HOST@${local.realm}</value></property>
      <property><name>dfs.datanode.kerberos.principal</name><value>hdfs/_HOST@${local.realm}</value></property>
      <property><name>dfs.datanode.keytab.file</name><value>/keytabs/hdfs.keytab</value></property>
      <property><name>dfs.web.authentication.kerberos.principal</name><value>HTTP/_HOST@${local.realm}</value></property>
      <property><name>dfs.web.authentication.kerberos.keytab</name><value>/keytabs/hdfs.keytab</value></property>
    </configuration>
  EOT

  # ---- Namespace ----------------------------------------------------------
  m_namespace = {
    apiVersion = "v1"
    kind       = "Namespace"
    metadata = {
      name = local.namespace
      labels = merge(local.common_labels, {
        "pod-security.kubernetes.io/enforce" = "baseline"
        "pod-security.kubernetes.io/audit"   = "restricted"
        "pod-security.kubernetes.io/warn"    = "restricted"
      })
    }
  }

  # ---- Spark RBAC ---------------------------------------------------------
  m_spark_sa = {
    apiVersion = "v1"
    kind       = "ServiceAccount"
    metadata   = { name = "spark", namespace = local.namespace, labels = local.common_labels }
  }
  m_spark_role = {
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "Role"
    metadata   = { name = "spark-driver", namespace = local.namespace, labels = local.common_labels }
    rules = [{
      apiGroups = [""]
      resources = ["pods", "services", "configmaps", "persistentvolumeclaims"]
      verbs     = ["create", "get", "list", "watch", "delete", "deletecollection", "update", "patch"]
    }]
  }
  m_spark_rb = {
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "RoleBinding"
    metadata   = { name = "spark-driver", namespace = local.namespace, labels = local.common_labels }
    roleRef    = { apiGroup = "rbac.authorization.k8s.io", kind = "Role", name = "spark-driver" }
    subjects   = [{ kind = "ServiceAccount", name = "spark", namespace = local.namespace }]
  }

  # ---- NetworkPolicies (need a policy engine - see README) ----------------
  m_np_deny_ingress = {
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata   = { name = "default-deny-ingress", namespace = local.namespace, labels = local.common_labels }
    spec       = { podSelector = {}, policyTypes = ["Ingress"] }
  }
  m_np_allow_intra = {
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata   = { name = "allow-intra-namespace", namespace = local.namespace, labels = local.common_labels }
    spec = {
      podSelector = {}
      policyTypes = ["Ingress"]
      ingress     = [{ from = [{ podSelector = {} }] }]
    }
  }
  m_np_deny_egress = {
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata   = { name = "default-deny-egress", namespace = local.namespace, labels = local.common_labels }
    spec       = { podSelector = {}, policyTypes = ["Egress"] }
  }
  m_np_allow_egress = {
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata   = { name = "allow-egress-platform", namespace = local.namespace, labels = local.common_labels }
    spec = {
      podSelector = {}
      policyTypes = ["Egress"]
      egress = [
        # Cluster DNS
        { ports = [{ port = 53, protocol = "UDP" }, { port = 53, protocol = "TCP" }] },
        # In-cluster / VCN (pods, services, nodes + API endpoint)
        { to = [
          { ipBlock = { cidr = "10.244.0.0/16" } },
          { ipBlock = { cidr = "10.96.0.0/16" } },
          { ipBlock = { cidr = var.vcn_cidr } },
        ] },
        # OKE Workload Identity's node-local proxymux/metadata endpoint
        { to = [{ ipBlock = { cidr = "169.254.169.254/32" } }], ports = [{ port = 80, protocol = "TCP" }] },
        # OCI Service Network (Object Storage + Workload Identity) over HTTPS.
        # The service gateway uses an OCI CIDR label, while Kubernetes ipBlock
        # requires the corresponding numeric, region-specific OSN CIDRs.
        { to = [for cidr in local.regional_osn_cidrs : { ipBlock = { cidr = cidr } }], ports = [{ port = 443, protocol = "TCP" }] },
      ]
    }
  }

  # ---- KDC ----------------------------------------------------------------
  m_kdc_secret = {
    apiVersion = "v1"
    kind       = "Secret"
    type       = "Opaque"
    metadata   = { name = "kerberos-creds", namespace = local.namespace, labels = local.common_labels }
    stringData = {
      KDC_DB_PASSWORD      = try(one(random_password.kdc_db[*].result), "")
      KADMIN_PASSWORD      = try(one(random_password.kadmin[*].result), "")
      HADOOP_USER_PASSWORD = try(one(random_password.hadoop_user[*].result), "")
    }
  }
  m_kdc_config = {
    apiVersion = "v1"
    kind       = "ConfigMap"
    metadata   = { name = "kdc-config", namespace = local.namespace, labels = local.common_labels }
    data = {
      "kdc-entrypoint.sh" = file("${path.module}/scripts/kdc-entrypoint.sh")
      "keytab-init.sh"    = file("${path.module}/scripts/keytab-init.sh")
      "kadm5.acl"         = "admin/admin@${local.realm}  *\n"
      "krb5.conf"         = local.krb5_conf
      "kdc.conf"          = local.kdc_conf
    }
  }
  m_kdc_svc = {
    apiVersion = "v1"
    kind       = "Service"
    metadata   = { name = "kdc", namespace = local.namespace, labels = local.common_labels }
    spec = {
      clusterIP = "None"
      selector  = { app = "kdc" }
      ports = [
        { name = "kerberos-tcp", port = 88, protocol = "TCP", targetPort = 88 },
        { name = "kerberos-udp", port = 88, protocol = "UDP", targetPort = 88 },
        { name = "kadmin", port = 749, protocol = "TCP", targetPort = 749 },
      ]
    }
  }
  m_kdc_sts = {
    apiVersion = "apps/v1"
    kind       = "StatefulSet"
    metadata   = { name = "kdc", namespace = local.namespace, labels = merge(local.common_labels, { app = "kdc" }) }
    spec = {
      replicas    = 1
      serviceName = "kdc"
      selector    = { matchLabels = { app = "kdc" } }
      template = {
        metadata = { labels = merge(local.common_labels, { app = "kdc" }) }
        spec = {
          containers = [{
            name    = "kdc"
            image   = var.kdc_image
            command = ["/bin/bash", "/kdc-config/kdc-entrypoint.sh"]
            env = [
              { name = "REALM", value = local.realm },
              { name = "KDC_DB_PASSWORD", valueFrom = { secretKeyRef = { name = "kerberos-creds", key = "KDC_DB_PASSWORD" } } },
              { name = "KADMIN_PASSWORD", valueFrom = { secretKeyRef = { name = "kerberos-creds", key = "KADMIN_PASSWORD" } } },
              { name = "HADOOP_USER_PASSWORD", valueFrom = { secretKeyRef = { name = "kerberos-creds", key = "HADOOP_USER_PASSWORD" } } },
            ]
            ports = [
              { containerPort = 88, protocol = "TCP" },
              { containerPort = 88, protocol = "UDP" },
              { containerPort = 749, protocol = "TCP" },
            ]
            volumeMounts = [
              { name = "kdc-config", mountPath = "/kdc-config" },
              { name = "realm-db", mountPath = "/var/kerberos/krb5kdc" },
            ]
            securityContext = { runAsUser = 0 }
            readinessProbe  = { tcpSocket = { port = 88 }, initialDelaySeconds = 20, periodSeconds = 10 }
          }]
          volumes = [{ name = "kdc-config", configMap = { name = "kdc-config" } }]
        }
      }
      volumeClaimTemplates = [{
        metadata = { name = "realm-db" }
        spec = {
          accessModes      = ["ReadWriteOnce"]
          storageClassName = var.storage_class
          resources        = { requests = { storage = "5Gi" } }
        }
      }]
    }
  }

  # ---- Hadoop config + NameNode/DataNode ----------------------------------
  m_hadoop_config = {
    apiVersion = "v1"
    kind       = "ConfigMap"
    metadata   = { name = "hadoop-config", namespace = local.namespace, labels = local.common_labels }
    data = {
      "namenode-entrypoint.sh" = file("${path.module}/scripts/namenode-entrypoint.sh")
      "datanode-entrypoint.sh" = file("${path.module}/scripts/datanode-entrypoint.sh")
      "krb5.conf"              = local.krb5_conf
      "core-site.xml"          = local.core_site_xml
      "hdfs-site.xml"          = local.hdfs_site_xml
    }
  }
  m_nn_svc = {
    apiVersion = "v1"
    kind       = "Service"
    metadata   = { name = "hdfs-nn", namespace = local.namespace, labels = local.common_labels }
    spec = {
      clusterIP = "None"
      selector  = { app = "namenode" }
      ports     = [{ name = "rpc", port = 9000 }, { name = "http", port = 9870 }]
    }
  }
  m_nn_sts = {
    apiVersion = "apps/v1"
    kind       = "StatefulSet"
    metadata   = { name = "namenode", namespace = local.namespace, labels = merge(local.common_labels, { app = "namenode" }) }
    spec = {
      replicas    = 1
      serviceName = "hdfs-nn"
      selector    = { matchLabels = { app = "namenode" } }
      template = {
        metadata = { labels = merge(local.common_labels, { app = "namenode" }) }
        spec = {
          initContainers = [local.keytab_init_container["hdfs-nn"]]
          containers = [{
            name            = "namenode"
            image           = var.hadoop_image
            command         = ["/bin/bash", "/hadoop-config/namenode-entrypoint.sh"]
            securityContext = { runAsUser = 0 }
            ports           = [{ containerPort = 9000 }, { containerPort = 9870 }]
            volumeMounts = [
              { name = "hadoop-config", mountPath = "/hadoop-config" },
              { name = "keytabs", mountPath = "/keytabs" },
              { name = "name", mountPath = "/hadoop/dfs/name" },
            ]
            readinessProbe = { tcpSocket = { port = 9000 }, initialDelaySeconds = 30, periodSeconds = 15 }
          }]
          volumes = local.hdfs_pod_volumes
        }
      }
      volumeClaimTemplates = [{
        metadata = { name = "name" }
        spec = {
          accessModes      = ["ReadWriteOnce"]
          storageClassName = var.storage_class
          resources        = { requests = { storage = "${var.hdfs_namenode_storage_gbs}Gi" } }
        }
      }]
    }
  }
  m_dn_svc = {
    apiVersion = "v1"
    kind       = "Service"
    metadata   = { name = "hdfs-dn", namespace = local.namespace, labels = local.common_labels }
    spec = {
      clusterIP = "None"
      selector  = { app = "datanode" }
      ports     = [{ name = "data", port = 9866 }, { name = "http", port = 9864 }, { name = "ipc", port = 9867 }]
    }
  }
  m_dn_sts = {
    apiVersion = "apps/v1"
    kind       = "StatefulSet"
    metadata   = { name = "datanode", namespace = local.namespace, labels = merge(local.common_labels, { app = "datanode" }) }
    spec = {
      replicas    = var.hdfs_datanode_count
      serviceName = "hdfs-dn"
      selector    = { matchLabels = { app = "datanode" } }
      template = {
        metadata = { labels = merge(local.common_labels, { app = "datanode" }) }
        spec = {
          initContainers = [local.keytab_init_container["hdfs-dn"]]
          containers = [{
            name            = "datanode"
            image           = var.hadoop_image
            command         = ["/bin/bash", "/hadoop-config/datanode-entrypoint.sh"]
            securityContext = { runAsUser = 0 }
            ports           = [{ containerPort = 9866 }, { containerPort = 9864 }, { containerPort = 9867 }]
            volumeMounts = [
              { name = "hadoop-config", mountPath = "/hadoop-config" },
              { name = "keytabs", mountPath = "/keytabs" },
              { name = "data", mountPath = "/hadoop/dfs/data" },
            ]
          }]
          volumes = local.hdfs_pod_volumes
        }
      }
      volumeClaimTemplates = [{
        metadata = { name = "data" }
        spec = {
          accessModes      = ["ReadWriteOnce"]
          storageClassName = var.storage_class
          resources        = { requests = { storage = "${var.hdfs_datanode_storage_gbs}Gi" } }
        }
      }]
    }
  }

  # Keytab init-container per governing service (hdfs-nn for the NameNode,
  # hdfs-dn for the DataNodes). POD_SERVICE + POD_NAMESPACE let keytab-init.sh
  # build the pod FQDN deterministically, matching HDFS's _HOST resolution.
  keytab_init_container = {
    for svc in ["hdfs-nn", "hdfs-dn"] : svc => {
      name    = "keytab-init"
      image   = var.kdc_image
      command = ["/bin/bash", "/kdc-config/keytab-init.sh"]
      env = [
        { name = "REALM", value = local.realm },
        { name = "KADMIN_PASSWORD", valueFrom = { secretKeyRef = { name = "kerberos-creds", key = "KADMIN_PASSWORD" } } },
        { name = "POD_NAME", valueFrom = { fieldRef = { fieldPath = "metadata.name" } } },
        { name = "POD_SERVICE", value = svc },
        { name = "POD_NAMESPACE", value = local.namespace },
      ]
      securityContext = { runAsUser = 0 }
      volumeMounts = [
        { name = "kdc-config", mountPath = "/kdc-config" },
        { name = "keytabs", mountPath = "/keytabs" },
      ]
    }
  }
  hdfs_pod_volumes = [
    { name = "kdc-config", configMap = { name = "kdc-config" } },
    { name = "hadoop-config", configMap = { name = "hadoop-config" } },
    { name = "keytabs", emptyDir = {} },
  ]

  # ---- Spark examples + Object Storage hints ------------------------------
  m_spark_examples = {
    apiVersion = "v1"
    kind       = "ConfigMap"
    metadata   = { name = "spark-examples", namespace = local.namespace, labels = local.common_labels }
    data = {
      "sparkpi.yaml" = <<-EOT
        apiVersion: sparkoperator.k8s.io/v1beta2
        kind: SparkApplication
        metadata:
          name: spark-pi
          namespace: ${local.namespace}
        spec:
          type: Scala
          mode: cluster
          image: ${var.spark_image}
          imagePullPolicy: IfNotPresent
          mainClass: org.apache.spark.examples.SparkPi
          mainApplicationFile: "local:///opt/spark/examples/jars/spark-examples_2.12-${var.spark_version}.jar"
          sparkVersion: "${var.spark_version}"
          restartPolicy:
            type: Never
          driver:
            cores: 1
            memory: "1g"
            serviceAccount: spark
          executor:
            cores: 1
            instances: 2
            memory: "1g"
      EOT
    }
  }
  m_object_storage = {
    apiVersion = "v1"
    kind       = "ConfigMap"
    metadata   = { name = "object-storage-config", namespace = local.namespace, labels = local.common_labels }
    data = {
      "README" = <<-EOT
        OCI Object Storage access for Spark
        ===================================
        Bucket    : ${local.bucket_name}
        Namespace : ${local.os_namespace}
        Path      : oci://${local.bucket_name}@${local.os_namespace}/

        Authentication uses OKE Workload Identity (iam.tf) - the 'spark' service
        account is matched by that policy, so no API keys are needed. The Spark
        image must include the OCI HDFS connector (oci-hdfs-connector).

        SECURITY: Spark runs on Kubernetes (not YARN, not a standalone master),
        so the YARN ResourceManager and Spark master REST RCE vectors do not
        exist. Keep the driver UI ClusterIP; do not enable spark.acls + doAs
        (CVE-2022-33891).
      EOT
    }
  }

  # ---- Assemble manifests (toggle-gated) ----------------------------------
  # Each object is yamlencode'd to a string here so every list element has a
  # uniform type (string) - the manifest objects have different shapes and could
  # not be unified inside a conditional/concat otherwise.
  manifests_yaml = concat(
    [yamlencode(local.m_namespace)],
    var.deploy_spark ? [yamlencode(local.m_spark_sa), yamlencode(local.m_spark_role), yamlencode(local.m_spark_rb)] : [],
    [yamlencode(local.m_np_deny_ingress), yamlencode(local.m_np_allow_intra), yamlencode(local.m_np_deny_egress), yamlencode(local.m_np_allow_egress)],
    var.deploy_hdfs ? [
      yamlencode(local.m_kdc_secret), yamlencode(local.m_kdc_config), yamlencode(local.m_kdc_svc), yamlencode(local.m_kdc_sts),
      yamlencode(local.m_hadoop_config), yamlencode(local.m_nn_svc), yamlencode(local.m_nn_sts), yamlencode(local.m_dn_svc), yamlencode(local.m_dn_sts),
    ] : [],
    var.deploy_spark ? [yamlencode(local.m_spark_examples)] : [],
    var.deploy_object_storage ? [yamlencode(local.m_object_storage)] : [],
  )

  platform_yaml = join("\n---\n", local.manifests_yaml)

  # ---- Spark Operator via helm (run on the operator) ----------------------
  spark_helm = var.deploy_spark ? join(" ", [
    "helm repo add spark-operator https://kubeflow.github.io/spark-operator --force-update &&",
    "helm repo update &&",
    "helm upgrade --install spark-operator spark-operator/spark-operator",
    "--version ${var.spark_operator_chart_version}",
    "--namespace ${local.namespace}",
    "--set sparkJobNamespace=${local.namespace}",
    "--set webhook.enable=true",
    "--set service.type=ClusterIP",
    "--set webhook.serviceType=ClusterIP",
    "--set uiService.enable=false",
  ]) : "echo 'Spark not enabled; skipping spark-operator'"

  # ---- Use-case demos written to /home/opc/use-cases ----------------------
  # Bundle and compress the files before embedding them in cloud-init. Encoding
  # each file in a separate shell command pushed the operator's OCI metadata over
  # the 32 KB LaunchInstance limit.
  use_case_manifest = {
    "README.md"                = "use-cases/README.md"
    "lib/common.sh"            = "use-cases/lib/common.sh"
    "01-spark-only/run.sh"     = "use-cases/01-spark-only/run.sh"
    "01-spark-only/job.py"     = "use-cases/01-spark-only/job.py"
    "02-hdfs-spark/run.sh"     = "use-cases/02-hdfs-spark/run.sh"
    "02-hdfs-spark/job.py"     = "use-cases/02-hdfs-spark/job.py"
    "03-objstore-spark/run.sh" = "use-cases/03-objstore-spark/run.sh"
    "03-objstore-spark/job.py" = "use-cases/03-objstore-spark/job.py"
  }
  use_case_bundle = base64gzip(jsonencode({
    for dest, src in local.use_case_manifest :
    dest => file("${path.module}/${src}")
  }))

  # ---- Operator bootstrap cloud-init --------------------------------------
  operator_bootstrap = <<-EOT
    #!/bin/bash
    set -uo pipefail
    export OCI_CLI_AUTH=instance_principal
    export KUBECONFIG=/home/opc/.kube/config
    log() { echo "[platform-bootstrap] $*"; }

    log "installing use-case demos to /home/opc/use-cases"
    echo '${local.use_case_bundle}' | base64 -d | gzip -d | python3 -c '
    import json
    import pathlib
    import sys

    root = pathlib.Path("/home/opc/use-cases")
    for relative_path, content in json.load(sys.stdin).items():
        path = root / relative_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
    '
    chmod +x /home/opc/use-cases/lib/common.sh /home/opc/use-cases/*/run.sh
    chown -R opc:opc /home/opc/use-cases

    # Give every use case the actual deployment context. This removes the
    # hard-coded `bigdata` namespace assumption when cluster_name is customized.
    cat > /home/opc/use-cases/deployment.env <<'DEPLOYMENT_EOF'
    export NS="$${NS:-${local.namespace}}"
    export CLUSTER_NAME="$${CLUSTER_NAME:-${var.cluster_name}}"
    export COMPARTMENT_OCID="$${COMPARTMENT_OCID:-${var.compartment_ocid}}"
    export REGION="$${REGION:-${var.region}}"
    DEPLOYMENT_EOF
    chown opc:opc /home/opc/use-cases/deployment.env
    chmod 600 /home/opc/use-cases/deployment.env

    # Make instance-principal auth the default in every interactive shell, so the
    # kubeconfig exec plugin (oci ce cluster generate-token) never falls back to
    # looking for ~/.oci/config and hanging in a fresh session.
    grep -q 'OCI_CLI_AUTH' /home/opc/.bashrc 2>/dev/null || \
      echo 'export OCI_CLI_AUTH=instance_principal' >> /home/opc/.bashrc

    # Generate our own kubeconfig with the operator's instance principal, rather
    # than depend on the module's runcmd ordering (which can place opc's
    # kubeconfig AFTER this script runs). Discover the cluster by name to avoid a
    # dependency cycle on module.oke outputs.
    log "discovering cluster and generating kubeconfig"
    mkdir -p /home/opc/.kube
    KUBECONFIG_READY=false
    for i in $(seq 1 180); do
      CID=$(oci ce cluster list --compartment-id '${var.compartment_ocid}' --name '${var.cluster_name}' --lifecycle-state ACTIVE --query 'data[0].id' --raw-output 2>/tmp/oke-cluster-list.err || true)
      if [ -n "$CID" ] && [ "$CID" != "null" ]; then
        if oci ce cluster create-kubeconfig --cluster-id "$CID" --file "$KUBECONFIG" --region '${var.region}' --token-version 2.0.0 --kube-endpoint PRIVATE_ENDPOINT --overwrite >/tmp/oke-kubeconfig.out 2>/tmp/oke-kubeconfig.err; then
          KUBECONFIG_READY=true
          log "kubeconfig ready (cluster $CID)"
          break
        fi
        log "kubeconfig download failed ($i): $(tail -1 /tmp/oke-kubeconfig.err)"
      else
        log "cluster discovery failed ($i): $(tail -1 /tmp/oke-cluster-list.err)"
      fi
      sleep 10
    done
    if [ "$KUBECONFIG_READY" != true ] || [ ! -s "$KUBECONFIG" ]; then
      log "ERROR: kubeconfig generation failed after 30 minutes"
      cat /tmp/oke-cluster-list.err /tmp/oke-kubeconfig.err 2>/dev/null || true
      exit 1
    fi
    # Bake the auth mode into the token exec so kubectl works regardless of
    # whether OCI_CLI_AUTH is set in the caller's shell (the generated exec block
    # otherwise relies on that env var).
    sed -i 's|^\( *\)- generate-token|\1- generate-token\n\1- --auth\n\1- instance_principal|' "$KUBECONFIG" 2>/dev/null || true
    chown -R opc:opc /home/opc/.kube

    log "waiting for at least one Ready node"
    NODE_READY=false
    for i in $(seq 1 120); do
      if kubectl get nodes --no-headers 2>/tmp/kubectl-nodes.err | grep -q ' Ready '; then
        NODE_READY=true
        log "node Ready"
        break
      fi
      sleep 10
    done
    if [ "$NODE_READY" != true ]; then
      log "ERROR: Kubernetes API or workers did not become ready after 20 minutes"
      cat /tmp/kubectl-nodes.err 2>/dev/null || true
      exit 1
    fi

    log "applying platform manifests"
    cat > /tmp/platform.yaml <<'PLATFORM_EOF'
    ${local.platform_yaml}
    PLATFORM_EOF
    kubectl apply -f /tmp/platform.yaml || exit 1

    log "installing Spark Operator (if enabled)"
    ${local.spark_helm} || exit 1

    log "done"
  EOT

  operator_cloud_init = [
    {
      content_type = "text/x-shellscript"
      filename     = "50-platform-bootstrap.sh"
      content      = local.operator_bootstrap
    },
  ]
}
