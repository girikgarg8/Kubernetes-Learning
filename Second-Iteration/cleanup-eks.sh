#!/bin/bash

# Automated EKS Cluster Cleanup Script
# Deletes node groups, cluster, and leftover resources

CLUSTER_NAME="my-demo-cluster"
REGION="ap-south-1"
CHECK_INTERVAL=30

echo "🗑️  EKS Cluster Cleanup Script"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Cluster: $CLUSTER_NAME"
echo "Region: $REGION"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Function to get all node groups
get_nodegroups() {
    aws eks list-nodegroups \
        --cluster-name $CLUSTER_NAME \
        --region $REGION \
        --query 'nodegroups[*]' \
        --output text 2>/dev/null || echo ""
}

# Function to delete all node groups
delete_all_nodegroups() {
    local nodegroups=$(get_nodegroups)
    
    if [ -z "$nodegroups" ]; then
        echo "✅ No node groups found"
        return 0
    fi
    
    echo "📋 Found node groups: $nodegroups"
    echo "🗑️  Initiating deletion of all node groups..."
    echo ""
    
    for ng in $nodegroups; do
        echo "  → Deleting node group: $ng"
        aws eks delete-nodegroup \
            --cluster-name $CLUSTER_NAME \
            --nodegroup-name $ng \
            --region $REGION 2>/dev/null
        
        if [ $? -eq 0 ]; then
            echo "    ✓ Deletion initiated for $ng"
        else
            echo "    ⚠️  Failed to delete $ng (may already be deleting)"
        fi
    done
    echo ""
}

# Function to check if all node groups are deleted
check_nodegroups_deleted() {
    local nodegroups=$(get_nodegroups)
    [ -z "$nodegroups" ]
}

# Function to delete EKS cluster
delete_cluster() {
    echo "🗑️  Deleting EKS cluster: $CLUSTER_NAME"
    aws eks delete-cluster \
        --name $CLUSTER_NAME \
        --region $REGION 2>/dev/null
    
    if [ $? -eq 0 ]; then
        echo "✓ Cluster deletion initiated"
        return 0
    else
        echo "⚠️  Failed to delete cluster"
        return 1
    fi
}

# Function to check if cluster is deleted
check_cluster_deleted() {
    aws eks describe-cluster \
        --name $CLUSTER_NAME \
        --region $REGION >/dev/null 2>&1
    
    # Return 0 if cluster doesn't exist (deleted), 1 if it exists
    [ $? -ne 0 ]
}

# Function to delete leftover EC2 instances
cleanup_ec2_instances() {
    echo ""
    echo "🖥️  Checking for leftover EC2 instances..."
    
    local instances=$(aws ec2 describe-instances \
        --filters "Name=tag:eks:cluster-name,Values=$CLUSTER_NAME" \
        --region $REGION \
        --query 'Reservations[*].Instances[?State.Name!=`terminated`].InstanceId' \
        --output text 2>/dev/null)
    
    if [ -z "$instances" ]; then
        echo "✅ No EC2 instances found"
        return 0
    fi
    
    echo "📋 Found EC2 instances: $instances"
    echo "🗑️  Terminating instances..."
    
    aws ec2 terminate-instances \
        --instance-ids $instances \
        --region $REGION >/dev/null 2>&1
    
    if [ $? -eq 0 ]; then
        echo "✓ EC2 instances terminated"
    else
        echo "⚠️  Failed to terminate some instances"
    fi
}

# Function to delete leftover load balancers
cleanup_load_balancers() {
    echo ""
    echo "⚖️  Checking for leftover Load Balancers..."
    
    # Get Classic Load Balancers
    local elbs=$(aws elb describe-load-balancers \
        --region $REGION \
        --query "LoadBalancerDescriptions[?contains(LoadBalancerName, 'k8s')].LoadBalancerName" \
        --output text 2>/dev/null)
    
    if [ ! -z "$elbs" ]; then
        echo "📋 Found Classic Load Balancers: $elbs"
        for elb in $elbs; do
            echo "  → Deleting CLB: $elb"
            aws elb delete-load-balancer \
                --load-balancer-name $elb \
                --region $REGION >/dev/null 2>&1
            echo "    ✓ Deleted"
        done
    else
        echo "✅ No Classic Load Balancers found"
    fi
    
    # Get Application/Network Load Balancers
    local albs=$(aws elbv2 describe-load-balancers \
        --region $REGION \
        --query "LoadBalancers[?contains(LoadBalancerName, 'k8s')].LoadBalancerArn" \
        --output text 2>/dev/null)
    
    if [ ! -z "$albs" ]; then
        echo "📋 Found ALB/NLB Load Balancers"
        for alb in $albs; do
            local alb_name=$(aws elbv2 describe-load-balancers --load-balancer-arns $alb --region $REGION --query 'LoadBalancers[0].LoadBalancerName' --output text 2>/dev/null)
            echo "  → Deleting ALB/NLB: $alb_name"
            aws elbv2 delete-load-balancer \
                --load-balancer-arn $alb \
                --region $REGION >/dev/null 2>&1
            echo "    ✓ Deleted"
        done
    else
        echo "✅ No ALB/NLB Load Balancers found"
    fi
}

# Function to cleanup security groups
cleanup_security_groups() {
    echo ""
    echo "🔒 Checking for leftover Security Groups..."
    
    local sgs=$(aws ec2 describe-security-groups \
        --filters "Name=tag:eks:cluster-name,Values=$CLUSTER_NAME" \
        --region $REGION \
        --query 'SecurityGroups[].GroupId' \
        --output text 2>/dev/null)
    
    if [ -z "$sgs" ]; then
        echo "✅ No security groups found"
        return 0
    fi
    
    echo "📋 Found security groups (will auto-delete with VPC): $sgs"
}

# Main execution
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "STEP 1: Delete Node Groups"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
delete_all_nodegroups

# Wait for node groups to be deleted
echo "⏳ Waiting for all node groups to be deleted..."
echo ""

NODEGROUP_WAIT_COUNT=0
MAX_NODEGROUP_WAIT=40  # Max 20 minutes (40 * 30 seconds)

while ! check_nodegroups_deleted; do
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    NODEGROUPS=$(get_nodegroups)
    NODEGROUP_COUNT=$(echo "$NODEGROUPS" | wc -w | tr -d ' ')
    
    echo "[$TIMESTAMP] ⏳ Waiting... $NODEGROUP_COUNT node group(s) remaining: $NODEGROUPS"
    
    NODEGROUP_WAIT_COUNT=$((NODEGROUP_WAIT_COUNT + 1))
    if [ $NODEGROUP_WAIT_COUNT -ge $MAX_NODEGROUP_WAIT ]; then
        echo ""
        echo "⚠️  WARNING: Node group deletion taking too long (20+ minutes)"
        echo "   You may need to manually check and delete from AWS Console"
        echo ""
        break
    fi
    
    sleep $CHECK_INTERVAL
done

if check_nodegroups_deleted; then
    echo ""
    echo "✅ All node groups deleted!"
    echo ""
    
    # Play success beep
    afplay /System/Library/Sounds/Glass.aiff 2>/dev/null || echo -e "\a"
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "STEP 2: Delete EKS Cluster"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    delete_cluster
    echo ""
    
    # Wait for cluster to be deleted
    echo "⏳ Waiting for cluster to be deleted..."
    echo ""
    
    CLUSTER_WAIT_COUNT=0
    MAX_CLUSTER_WAIT=20  # Max 10 minutes
    
    while ! check_cluster_deleted; do
        TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
        echo "[$TIMESTAMP] ⏳ Cluster still deleting..."
        
        CLUSTER_WAIT_COUNT=$((CLUSTER_WAIT_COUNT + 1))
        if [ $CLUSTER_WAIT_COUNT -ge $MAX_CLUSTER_WAIT ]; then
            echo ""
            echo "⚠️  WARNING: Cluster deletion taking too long"
            break
        fi
        
        sleep $CHECK_INTERVAL
    done
    
    if check_cluster_deleted; then
        echo ""
        echo "✅ Cluster deleted!"
        echo ""
        
        # Play success beep
        afplay /System/Library/Sounds/Glass.aiff 2>/dev/null || echo -e "\a"
    fi
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "STEP 3: Cleanup Leftover Resources"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

cleanup_load_balancers
sleep 5
cleanup_ec2_instances
sleep 5
cleanup_security_groups

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🎉 Cleanup Complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "✅ Node groups: Deleted"
echo "✅ Cluster: Deleted"
echo "✅ EC2 instances: Cleaned up"
echo "✅ Load Balancers: Cleaned up"
echo ""
echo "📋 Recommendations:"
echo "  1. Verify in AWS Console that all resources are deleted"
echo "  2. Check CloudWatch logs are deleted (if enabled)"
echo "  3. Check for any remaining EBS volumes"
echo ""
echo "💰 You should stop incurring charges now!"
echo ""

# Play final completion beeps
for i in {1..3}; do
    afplay /System/Library/Sounds/Glass.aiff 2>/dev/null || echo -e "\a"
    sleep 0.5
done

exit 0

