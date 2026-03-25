## kyverno usecase

- check helm repo

```
helm repo list
```

-  check installed charts

```
helm list -n kyverno
```

- check the kyverno resources
```
k get all -n kyverno
```

- get the CRD created
```
k get crd
```

- check if any cluster policies
```
k get clusterpolicies
```

- check policy report , always created in the namespace of the evaluated resource
```
kubectl get policyreport -A
```

## usecases
1. Validation
- suppose you need to ensure the deployments has replica greater than a value
2. Muttate
- to update a resource
3. Generate
- The easyest and most common use case is to generate secrets or configmaps for each namespace