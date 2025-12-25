# Resource Quota and LimitRange Testing Guide

## Prerequisites

1. Create namespace:
```bash
kubectl create namespace test-namespace
```

2. Apply LimitRange:
```bash
kubectl apply -f limitrange/limitrange.yaml
```

3. Apply ResourceQuota:
```bash
kubectl apply -f resourcequota/resourcequota.yaml
```

4. Switch to namespace:
```bash
kubectl config set-context --current --namespace=test-namespace
```

---

## Test 1: Create Pod Within Container Limits

### Scenario
Create a pod with resource specifications that are within the LimitRange container limits.

### Test Command
```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: test-pod-1
  namespace: test-namespace
spec:
  containers:
  - name: nginx
    image: nginx
    resources:
      requests:
        cpu: "200m"
        memory: "200Mi"
      limits:
        cpu: "400m"
        memory: "400Mi"
EOF
```

### Expected Result
✅ Pod should be created successfully because:
- CPU limit (400m) < Container max (1 CPU)
- Memory limit (400Mi) < Container max (1Gi)

### Verification
```bash
kubectl get pods -n test-namespace
kubectl describe pod test-pod-1 -n test-namespace
```

---

## Test 2: Pod Without Resource Specifications (Gets Defaults)

### Scenario
Create a pod without specifying any resources to verify default values are applied from LimitRange.

### Test Command
```bash
kubectl run test-pod-defaults -n test-namespace --image=nginx
```

### Expected Result
✅ Pod should be created with default values:
- Requests: cpu=200m, memory=200Mi (from defaultRequest)
- Limits: cpu=300m, memory=300Mi (from default)

### Verification
```bash
kubectl describe pod test-pod-defaults -n test-namespace | grep -A 10 "Limits:"
```

---

## Test 3: Exceed Container Maximum Limits

### Scenario
Attempt to create a pod that exceeds the LimitRange container maximum.

### Test Command
```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: test-pod-exceed-container
  namespace: test-namespace
spec:
  containers:
  - name: nginx
    image: nginx
    resources:
      requests:
        cpu: "300m"
        memory: "300Mi"
      limits:
        cpu: "1500m"
        memory: "1500Mi"
EOF
```

### Expected Result
❌ Should fail with error:
```
Error from server (Forbidden): pods "test-pod-exceed-container" is forbidden: maximum cpu usage per Container is 1, but limit is 1500m
```

### Reason
- CPU limit (1500m = 1.5 cores) > Container max (1 CPU)

---

## Test 4: Exceed Pod Maximum Limits

### Scenario
Create a multi-container pod where total resources exceed the LimitRange pod maximum.

### Test Command
```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: test-pod-exceed-pod-limit
  namespace: test-namespace
spec:
  containers:
  - name: container1
    image: nginx
    resources:
      requests:
        cpu: "1"
        memory: "1Gi"
      limits:
        cpu: "1"
        memory: "1Gi"
  - name: container2
    image: nginx
    resources:
      requests:
        cpu: "1"
        memory: "1Gi"
      limits:
        cpu: "1"
        memory: "1Gi"
  - name: container3
    image: nginx
    resources:
      requests:
        cpu: "500m"
        memory: "500Mi"
      limits:
        cpu: "500m"
        memory: "500Mi"
EOF
```

### Expected Result
❌ Should fail with error:
```
Error from server (Forbidden): pods "test-pod-exceed-pod-limit" is forbidden: maximum cpu usage per Pod is 2, but limit is 2500m
```

### Reason
- Total CPU (1 + 1 + 0.5 = 2.5) > Pod max (2 CPU)

---

## Test 5: Exceed ResourceQuota Pod Count

### Scenario
Attempt to create more pods than allowed by ResourceQuota.

### Test Commands
```bash
# Clean up existing pods
kubectl delete pod --all -n test-namespace

# Create 5 pods (uses a loop for brevity)
for i in 1 2 3 4 5; do
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: quota-test-$i
  namespace: test-namespace
spec:
  containers:
  - name: nginx
    image: nginx
    resources:
      requests:
        cpu: "200m"
        memory: "200Mi"
      limits:
        cpu: "300m"
        memory: "300Mi"
EOF
done

# Try to create 6th pod (should fail)
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: quota-test-6
  namespace: test-namespace
spec:
  containers:
  - name: nginx
    image: nginx
    resources:
      requests:
        cpu: "200m"
        memory: "200Mi"
      limits:
        cpu: "300m"
        memory: "300Mi"
EOF
```

### Expected Result
✅ First 5 pods should be created successfully
❌ 6th pod should fail with error:
```
Error from server (Forbidden): pods "quota-test-6" is forbidden: exceeded quota: namespace-resource-quota, requested: pods=1, used: pods=5, limited: pods=5
```

### Reason
- ResourceQuota limits namespace to 5 pods maximum

---

## Test 6: Exceed ResourceQuota Total CPU Requests

### Scenario
Create pods that collectively exceed the namespace CPU request quota. Using multi-container pods to achieve higher CPU requests while staying within LimitRange container limits.

### Test Commands
```bash
# Clean up
kubectl delete pod --all -n test-namespace

# Create first multi-container pod (2 CPU requests total)
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: big-pod-1
  namespace: test-namespace
spec:
  containers:
  - name: nginx-1
    image: nginx
    resources:
      requests:
        cpu: "1"
        memory: "300Mi"
      limits:
        cpu: "1"
        memory: "500Mi"
  - name: nginx-2
    image: nginx
    resources:
      requests:
        cpu: "1"
        memory: "300Mi"
      limits:
        cpu: "1"
        memory: "500Mi"
EOF

# Create second multi-container pod (total now: 4 CPU requests)
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: big-pod-2
  namespace: test-namespace
spec:
  containers:
  - name: nginx-1
    image: nginx
    resources:
      requests:
        cpu: "1"
        memory: "300Mi"
      limits:
        cpu: "1"
        memory: "500Mi"
  - name: nginx-2
    image: nginx
    resources:
      requests:
        cpu: "1"
        memory: "300Mi"
      limits:
        cpu: "1"
        memory: "500Mi"
EOF

# Try to create third pod (should fail - would exceed 4 CPU quota)
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: big-pod-3
  namespace: test-namespace
spec:
  containers:
  - name: nginx
    image: nginx
    resources:
      requests:
        cpu: "500m"
        memory: "300Mi"
      limits:
        cpu: "500m"
        memory: "500Mi"
EOF
```

### Expected Result
✅ First 2 multi-container pods created (total requests: 4 CPU, exactly at quota limit)
❌ 3rd pod fails with error:
```
Error from server (Forbidden): pods "big-pod-3" is forbidden: exceeded quota: namespace-resource-quota, requested: requests.cpu=500m, used: requests.cpu=4, limited: requests.cpu=4
```

### Reason
- Each container stays within LimitRange (1 CPU max per container)
- Each pod stays within LimitRange (2 CPU max per pod)
- But total CPU requests (2 + 2 + 0.5 = 4.5) > ResourceQuota limit (4 CPU)

---

## Test 7: Exceed ResourceQuota Total Memory Limits

### Scenario
Create pods that collectively exceed the namespace memory limit quota. With 5 pods allowed, we can hit the 8Gi memory limit before hitting pod count limit.

### Test Commands
```bash
# Clean up
kubectl delete pod --all -n test-namespace

# Create 4 pods with maximum memory each (2Gi per pod = 8Gi total)
for i in 1 2 3 4; do
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: mem-pod-$i
  namespace: test-namespace
spec:
  containers:
  - name: nginx-1
    image: nginx
    resources:
      requests:
        cpu: "300m"
        memory: "500Mi"
      limits:
        cpu: "500m"
        memory: "1Gi"
  - name: nginx-2
    image: nginx
    resources:
      requests:
        cpu: "300m"
        memory: "500Mi"
      limits:
        cpu: "500m"
        memory: "1Gi"
EOF
done

# Check quota usage (should show 8Gi used)
kubectl describe resourcequota namespace-resource-quota -n test-namespace

# Try to create 5th pod (should fail on memory)
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: mem-pod-5
  namespace: test-namespace
spec:
  containers:
  - name: nginx
    image: nginx
    resources:
      requests:
        cpu: "200m"
        memory: "200Mi"
      limits:
        cpu: "300m"
        memory: "500Mi"
EOF
```

### Expected Result
✅ First 4 pods created (total memory limits: 4 × 2Gi = 8Gi, exactly at quota)
❌ 5th pod fails with memory quota error:
```
Error from server (Forbidden): pods "mem-pod-5" is forbidden: exceeded quota: namespace-resource-quota, requested: limits.memory=500Mi, used: limits.memory=8Gi, limited: limits.memory=8Gi
```

### Verification
```bash
kubectl describe resourcequota namespace-resource-quota -n test-namespace
```

Output should show:
```
Resource         Used   Hard
--------         ----   ----
limits.memory    8Gi    8Gi    # At limit!
pods             4      5      # Still have room for 1 more pod
```

### Reason
- Each container stays within LimitRange (1Gi max per container)
- Each pod stays within LimitRange (2Gi max per pod)
- 4 pods × 2Gi each = 8Gi (memory quota limit reached)
- 5th pod would exceed memory quota even though pod count allows it (4/5 pods used)
- This demonstrates pure memory quota exhaustion

---

## Test 8: Monitor Quota Usage

### Scenario
Check current quota usage in the namespace.

### Test Command
```bash
kubectl describe resourcequota namespace-resource-quota -n test-namespace
```

### Expected Result
Shows current usage vs limits:
```
Name:            namespace-resource-quota
Namespace:       test-namespace
Resource         Used   Hard
--------         ----   ----
limits.cpu       2      8
limits.memory    6Gi    8Gi
pods             2      5
requests.cpu     2      4
requests.memory  2Gi    4Gi
```

### Verification
```bash
# View all quotas
kubectl get resourcequota -n test-namespace

# View all limit ranges
kubectl get limitrange -n test-namespace
kubectl describe limitrange resource-limit-range -n test-namespace
```

---

## Test 9: Valid Multi-Container Pod Within All Limits

### Scenario
Create a multi-container pod that satisfies both LimitRange and ResourceQuota constraints.

### Test Command
```bash
# Clean up
kubectl delete pod --all -n test-namespace

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: valid-multi-container
  namespace: test-namespace
spec:
  containers:
  - name: app
    image: nginx
    resources:
      requests:
        cpu: "400m"
        memory: "400Mi"
      limits:
        cpu: "800m"
        memory: "800Mi"
  - name: sidecar
    image: busybox
    command: ["sleep", "3600"]
    resources:
      requests:
        cpu: "200m"
        memory: "200Mi"
      limits:
        cpu: "400m"
        memory: "400Mi"
EOF
```

### Expected Result
✅ Pod should be created successfully because:
- Each container is within container limits (< 1 CPU, < 1Gi)
- Total pod resources are within pod limits (1.2 CPU < 2 CPU, 1.2Gi < 2Gi)
- Namespace quota not exceeded

### Verification
```bash
kubectl get pod valid-multi-container -n test-namespace
kubectl describe pod valid-multi-container -n test-namespace
kubectl describe resourcequota namespace-resource-quota -n test-namespace
```

---

## Cleanup

### Remove All Test Resources
```bash
kubectl delete namespace test-namespace
```

This will delete:
- The namespace
- All pods in the namespace
- The LimitRange
- The ResourceQuota

---

## Key Takeaways

1. **LimitRange** enforces per-container and per-pod resource constraints
2. **ResourceQuota** enforces namespace-wide aggregate limits
3. **Default values** from LimitRange are applied when resources aren't specified
4. **Both policies** must be satisfied for pod creation to succeed
5. **Validation happens at creation time**, preventing over-commitment

