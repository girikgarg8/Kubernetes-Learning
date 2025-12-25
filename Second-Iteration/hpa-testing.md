# Horizontal Pod Autoscaler (HPA) Testing Guide

## Prerequisites

### 1. Install Metrics Server
```bash
kubectl apply -f metrics-server/metrics-server.yaml
```

Wait for metrics server to be ready:
```bash
kubectl get deployment metrics-server -n kube-system
kubectl top nodes  # Verify metrics are available
```

### 2. Create Test Deployment

Create a deployment with resource requests/limits:
```bash
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: stress-deployment
spec:
  replicas: 1
  selector:
    matchLabels:
      app: stress-app
  template:
    metadata:
      labels:
        app: stress-app
    spec:
      containers:
      - name: stress
        image: polinux/stress
        resources:
          requests:
            cpu: "800m"
            memory: "256Mi"
          limits:
            cpu: "1000m"
            memory: "512Mi"
        command: ["sleep"]
        args: ["999999"]
EOF
```

Verify deployment:
```bash
kubectl get deployment stress-deployment
kubectl get pods -l app=stress-app
```

### 3. Create HPA

Create CPU-based HPA:
```bash
cat <<EOF | kubectl apply -f -
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: cpu-hpa
spec:
  scaleTargetRef: 
    apiVersion: apps/v1
    kind: Deployment
    name: stress-deployment
  minReplicas: 1
  maxReplicas: 5
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 50
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 60
      policies:
        - type: Pods
          value: 2
          periodSeconds: 15
    scaleDown:
      stabilizationWindowSeconds: 180
      policies:
        - type: Pods
          value: 1
          periodSeconds: 60
EOF
```

Verify HPA:
```bash
kubectl get hpa cpu-hpa
```

---

## Test 1: Scale Up on High CPU Load

### Scenario
Trigger HPA scale-up by generating CPU load that exceeds 50% utilization (minimal increase for demo).

### Test Commands

**Terminal 1 - Monitor HPA:**
```bash
kubectl get hpa cpu-hpa -w
```

**Terminal 2 - Generate CPU Load:**
```bash
# Get the pod name
POD_NAME=$(kubectl get pods -l app=stress-app -o jsonpath='{.items[0].metadata.name}')

# Generate CPU stress (1 CPU = 1000m, request is 800m, so 1000/800 = 125% utilization)
kubectl exec -it $POD_NAME -- stress --cpu 1 -t 300s
```

**Terminal 3 - Monitor Pods:**
```bash
kubectl get pods -l app=stress-app -w
```

### Expected Result

**Initial State (before stress):**
```
NAME       REFERENCE                     TARGETS   MINPODS   MAXPODS   REPLICAS   AGE
cpu-hpa    Deployment/stress-deployment  5%/50%    1         5         1          1m
```

**During Stress (~30-90 seconds after starting):**
```
cpu-hpa    Deployment/stress-deployment  125%/50%  1         5         1          2m
cpu-hpa    Deployment/stress-deployment  125%/50%  1         5         3          2m  # Scaled to 3
```

**Pod Count:**
- Initial: 1 pod
- After ~60 seconds: 3 pods (adds 2 per scale-up policy)
- CPU usage per pod: 1000m / 3 = ~333m per pod = 42% of 800m (below 50%, will trigger scale-down)

### Verification
```bash
# Check current CPU usage per pod
kubectl top pods -l app=stress-app

# Check HPA events
kubectl describe hpa cpu-hpa
```

Look for events like:
```
New size: 3; reason: cpu resource utilization (percentage of request) above target
```

### Reason
- CPU request: 800m per pod
- Stress generates ~1 CPU = 1000m usage
- Initial utilization: 1000m / 800m = 125% (above 50% target - minimal increase for demo)
- HPA scales up to distribute load
- After scaling to 3 pods: 333m per pod = 42% (below 50%)

---

## Test 2: Scale Down After Load Decreases

### Scenario
After stopping the stress test, verify HPA scales down pods after stabilization window.

### Test Commands

**Stop the stress test** (let it timeout after 300s or Ctrl+C in Terminal 2)

**Continue monitoring:**
```bash
# Terminal 1 (already running)
kubectl get hpa cpu-hpa -w

# Terminal 3 (already running)
kubectl get pods -l app=stress-app -w
```

### Expected Result

**Immediately After Stopping Stress:**
```
cpu-hpa    Deployment/stress-deployment  5%/50%    1         5         3          5m
```
- Replicas stay at 3 (stabilization window prevents immediate scale-down)
- CPU usage drops to ~5% (well below 50% threshold)

**After ~3-5 Minutes (stabilizationWindowSeconds: 180s):**
```
cpu-hpa    Deployment/stress-deployment  5%/50%    1         5         2          8m  # Scaled down by 1
cpu-hpa    Deployment/stress-deployment  5%/50%    1         5         1          9m  # Scaled down by 1
```

**Pod Termination:**
- Pods are gracefully terminated one at a time
- Each scale-down waits 60 seconds (periodSeconds)

### Verification
```bash
kubectl describe hpa cpu-hpa
```

Look for events:
```
New size: 2; reason: All metrics below target
New size: 1; reason: All metrics below target
```

### Reason
- Stabilization window (180s) prevents premature scale-down
- Scale-down policy: Remove 1 pod at a time, wait 60s between operations
- Conservative approach to avoid flapping

---

## Test 3: Test Max Replicas Boundary

### Scenario
Generate extreme load to verify HPA respects maxReplicas limit.

### Test Commands

**Generate High Load in Multiple Pods:**
```bash
# Scale up manually first to have multiple pods
kubectl scale deployment stress-deployment --replicas=3

# Wait for pods to be ready
kubectl wait --for=condition=ready pod -l app=stress-app --timeout=60s

# Generate stress in all pods
for pod in $(kubectl get pods -l app=stress-app -o jsonpath='{.items[*].metadata.name}'); do
  kubectl exec $pod -- stress --cpu 2 -t 600s &
done
```

**Monitor:**
```bash
kubectl get hpa cpu-hpa -w
```

### Expected Result
```
cpu-hpa    Deployment/stress-deployment  250%/50%  1         5         3          15m
cpu-hpa    Deployment/stress-deployment  250%/50%  1         5         5          15m  # Maxed out
```

- Replicas scale up to 5 (maxReplicas)
- Even with continued high load, won't exceed 5 replicas
- HPA shows target exceeded but replicas capped

### Verification
```bash
kubectl describe hpa cpu-hpa
```

Look for:
```
New size: 5; reason: cpu resource utilization above target
```

No further scaling events after reaching maxReplicas.

---

## Test 4: Memory-Based HPA

### Scenario
Test HPA scaling based on memory utilization instead of CPU.

### Test Commands

**Delete CPU HPA:**
```bash
kubectl delete hpa cpu-hpa
```

**Create Memory HPA:**
```bash
cat <<EOF | kubectl apply -f -
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: memory-hpa
spec:
  scaleTargetRef: 
    apiVersion: apps/v1
    kind: Deployment
    name: stress-deployment
  minReplicas: 1
  maxReplicas: 5
  metrics:
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 70
EOF
```

**Scale deployment to 1 replica:**
```bash
kubectl scale deployment stress-deployment --replicas=1
```

**Generate Memory Load:**
```bash
POD_NAME=$(kubectl get pods -l app=stress-app -o jsonpath='{.items[0].metadata.name}')

# Generate memory stress (256Mi request, use 200Mi = ~78% utilization)
kubectl exec -it $POD_NAME -- stress --vm 1 --vm-bytes 200M --vm-hang 0 -t 300s
```

**Monitor:**
```bash
kubectl get hpa memory-hpa -w
```

### Expected Result
```
NAME         REFERENCE                     TARGETS   MINPODS   MAXPODS   REPLICAS   AGE
memory-hpa   Deployment/stress-deployment  78%/70%   1         5         1          1m
memory-hpa   Deployment/stress-deployment  78%/70%   1         5         3          2m  # Scaled up
```

### Verification
```bash
kubectl top pods -l app=stress-app
kubectl describe hpa memory-hpa
```

### Important Note
Memory-based scaling is less responsive than CPU because:
- Memory doesn't decrease when load stops (process holds memory)
- Scale-down only happens when pods are terminated
- Best used with applications that predictably release memory

---

## Test 5: Multi-Metric HPA (CPU + Memory)

### Scenario
Test HPA with both CPU and memory metrics. HPA uses the metric that requires MORE replicas.

### Test Commands

**Delete existing HPA:**
```bash
kubectl delete hpa memory-hpa
```

**Create Multi-Metric HPA:**
```bash
cat <<EOF | kubectl apply -f -
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: multi-metric-hpa
spec:
  scaleTargetRef: 
    apiVersion: apps/v1
    kind: Deployment
    name: stress-deployment
  minReplicas: 1
  maxReplicas: 5
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 50
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 70
EOF
```

**Generate Mixed Load:**
```bash
kubectl scale deployment stress-deployment --replicas=1

POD_NAME=$(kubectl get pods -l app=stress-app -o jsonpath='{.items[0].metadata.name}')

# Generate both CPU and memory stress
kubectl exec -it $POD_NAME -- stress --cpu 1 --vm 1 --vm-bytes 200M -t 300s
```

**Monitor:**
```bash
kubectl get hpa multi-metric-hpa -w
```

### Expected Result
```
NAME               REFERENCE                     TARGETS           MINPODS   MAXPODS   REPLICAS   AGE
multi-metric-hpa   Deployment/stress-deployment  78%/70%, 125%/50% 1         5         1          1m
multi-metric-hpa   Deployment/stress-deployment  78%/70%, 125%/50% 1         5         3          2m
```

**Calculation:**
- CPU utilization: 125% (suggests ~3 replicas)
- Memory utilization: 78% (suggests ~2 replicas)
- HPA chooses the HIGHER value (most conservative)
- Scales to 3 replicas

### Verification
```bash
kubectl describe hpa multi-metric-hpa
```

Look for both metrics in the status:
```
Metrics:
  resource cpu on pods (as a percentage of request):     125% / 50%
  resource memory on pods (as a percentage of request):  78% / 70%
```

---

## Test 6: Scale-Up Policy Testing

### Scenario
Test different scale-up policies (Pods vs Percent).

### Test Commands

**Modify HPA to test Percent policy:**
```bash
cat <<EOF | kubectl apply -f -
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: cpu-hpa
spec:
  scaleTargetRef: 
    apiVersion: apps/v1
    kind: Deployment
    name: stress-deployment
  minReplicas: 2  # Start with 2
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 50
  behavior:
    scaleUp:
      policies:
        - type: Percent
          value: 100  # Double the pods
          periodSeconds: 30
EOF

kubectl scale deployment stress-deployment --replicas=2
```

**Generate Load:**
```bash
for pod in $(kubectl get pods -l app=stress-app -o jsonpath='{.items[*].metadata.name}'); do
  kubectl exec $pod -- stress --cpu 2 -t 300s &
done
```

**Monitor:**
```bash
kubectl get hpa cpu-hpa -w
```

### Expected Result

**Percent-based scaling:**
- Start: 2 replicas
- First scale-up: 4 replicas (100% of 2 = +2)
- Second scale-up: 8 replicas (100% of 4 = +4)
- Third scale-up: 10 replicas (capped at maxReplicas)

**Exponential growth** with Percent policy vs linear growth with Pods policy.

---

## Monitoring and Debugging Commands

### Check HPA Status
```bash
kubectl get hpa
kubectl describe hpa <hpa-name>
```

### View HPA Events
```bash
kubectl get events --field-selector involvedObject.name=<hpa-name> --sort-by='.lastTimestamp'
```

### Check Current Metrics
```bash
kubectl top pods -l app=stress-app
kubectl top nodes
```

### View HPA Calculation Details
```bash
kubectl get hpa <hpa-name> -o yaml
```

Look at the `status` section for detailed metrics and conditions.

### Debug HPA Not Scaling
```bash
# Check if metrics-server is running
kubectl get deployment metrics-server -n kube-system

# Check if metrics are available
kubectl top pods

# Verify deployment has resource requests (required for HPA)
kubectl get deployment <deployment-name> -o yaml | grep -A 5 resources

# Check HPA conditions
kubectl describe hpa <hpa-name> | grep Conditions -A 10
```

---

## Cleanup

```bash
# Delete HPA
kubectl delete hpa cpu-hpa memory-hpa multi-metric-hpa

# Delete deployment
kubectl delete deployment stress-deployment

# Stop any running stress processes
kubectl delete pods -l app=stress-app
```

---

## Key Takeaways

1. **HPA requires resource requests** - Without requests, HPA cannot calculate utilization percentage

2. **Metrics-server is mandatory** - HPA depends on metrics-server for CPU/memory metrics

3. **Stabilization windows prevent flapping** - Scale-up uses shorter windows, scale-down uses longer windows

4. **Multi-metric uses highest replica count** - When multiple metrics are configured, HPA uses the most conservative (highest) replica count

5. **Scale-up is aggressive, scale-down is conservative** - By design to handle traffic spikes quickly but avoid disruption

6. **CPU is compressible, Memory is not** - CPU-based scaling is more predictable than memory-based

7. **Utilization is based on requests, not limits** - Always specify appropriate resource requests for HPA to work correctly

8. **HPA evaluation interval: ~15 seconds** - HPA controller checks metrics every 15 seconds by default

9. **Scale policies can be combined** - Multiple policies with different types can coexist; selectPolicy determines which to use

10. **Minimum scale-down time: 5 minutes** - By default, HPA waits 5 minutes after last scale-up before scaling down

11. **For demos, use minimal increases** - Request of 800m with 1 CPU stress (1000m) gives 125% utilization - just above thresholds for clear scaling behavior

