#!/bin/bash

# Monitor EKS nodes and beep when ready
# Usage: ./monitor-nodes.sh

CLUSTER_NAME="my-demo-cluster"
REGION="ap-south-1"
CHECK_INTERVAL=30
TIMEOUT_MINUTES=5
TIMEOUT_SECONDS=$((TIMEOUT_MINUTES * 60))

echo "🔍 Starting EKS Node Monitor for cluster: $CLUSTER_NAME"
echo "⏱️  Checking every $CHECK_INTERVAL seconds..."
echo "⏰ Timeout: $TIMEOUT_MINUTES minutes"
echo "🔔 Will beep when nodes are ready!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

START_TIME=$(date +%s)

while true; do
    # Get current timestamp
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Get nodes
    NODE_OUTPUT=$(kubectl get nodes --no-headers 2>/dev/null)
    if [ -z "$NODE_OUTPUT" ]; then
        NODE_COUNT=0
    else
        NODE_COUNT=$(echo "$NODE_OUTPUT" | grep -c "Ready")
    fi
    
    if [ "$NODE_COUNT" -gt 0 ]; then
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "🎉 SUCCESS! Nodes are ready! 🎉"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        kubectl get nodes -o wide
        echo ""
        
        # Beep 5 times (works on macOS)
        for i in {1..5}; do
            # macOS beep
            afplay /System/Library/Sounds/Glass.aiff 2>/dev/null || echo -e "\a"
            sleep 0.5
        done
        
        echo ""
        echo "✅ Monitoring complete!"
        exit 0
    else
        echo "[$TIMESTAMP] ⏳ No nodes ready yet. Nodes found: 0"
        
        # Show node group status
        NODEGROUP_STATUS=$(aws eks describe-nodegroup \
            --cluster-name $CLUSTER_NAME \
            --nodegroup-name test-node-group \
            --region $REGION \
            --query 'nodegroup.status' \
            --output text 2>/dev/null || echo "UNKNOWN")
        
        echo "[$TIMESTAMP] 📊 Node group status: $NODEGROUP_STATUS"
        
        # Check for EC2 instances
        INSTANCE_COUNT=$(aws ec2 describe-instances \
            --filters "Name=tag:eks:nodegroup-name,Values=test-node-group" "Name=instance-state-name,Values=pending,running" \
            --region $REGION \
            --query 'length(Reservations[*].Instances[*])' \
            --output text 2>/dev/null || echo "0")
        
        echo "[$TIMESTAMP] 🖥️  EC2 instances: $INSTANCE_COUNT"
        
        # Check if timeout exceeded
        CURRENT_TIME=$(date +%s)
        ELAPSED_TIME=$((CURRENT_TIME - START_TIME))
        REMAINING_TIME=$((TIMEOUT_SECONDS - ELAPSED_TIME))
        REMAINING_MINUTES=$((REMAINING_TIME / 60))
        
        if [ $ELAPSED_TIME -ge $TIMEOUT_SECONDS ]; then
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "⏰ TIMEOUT! No nodes after $TIMEOUT_MINUTES minutes!"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            echo "🚨 RECOMMENDATION: Terminate the EKS cluster!"
            echo ""
            echo "To delete the cluster and all resources:"
            echo "  1. Delete services first:"
            echo "     kubectl delete svc --all"
            echo ""
            echo "  2. Delete node groups (via AWS Console or CLI):"
            echo "     aws eks delete-nodegroup --cluster-name $CLUSTER_NAME --nodegroup-name test-node-group --region $REGION"
            echo ""
            echo "  3. Delete the cluster (via AWS Console or CLI):"
            echo "     aws eks delete-cluster --name $CLUSTER_NAME --region $REGION"
            echo ""
            echo "  4. Verify Load Balancers are deleted in EC2 Console"
            echo ""
            
            # Beep 3 times for alert
            for i in {1..3}; do
                afplay /System/Library/Sounds/Basso.aiff 2>/dev/null || echo -e "\a"
                sleep 1
            done
            
            echo "❌ Monitoring stopped due to timeout."
            exit 1
        fi
        
        echo "[$TIMESTAMP] ⏱️  Time remaining: $REMAINING_MINUTES minutes"
        echo ""
    fi
    
    sleep $CHECK_INTERVAL
done

