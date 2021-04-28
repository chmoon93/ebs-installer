##############################################################
# AWS EBS CSI DRIVER INSTALLER
#
# Required tools
# - helm v3+
# - jq 1.6+
# - kubectl 1.16+
#
# Tested version
#   EKS v1.19
#   chart: aws-ebs-csi 0.9.8 (0.9.0)
##############################################################
#!/bin/bash
export CLUSTER_NAME="dabbi"
export IAM_POLICY_NAME=${CLUSTER_NAME}"-AmazonEKS_EBS_CSI_Driver_Policy"
export CONTROLLER_IAM_ROLE_NAME=${CLUSTER_NAME}"-AmazonEKS_EBS_CSI_Driver_Role_For_Controller"
export CONTROLLER_SERVICE_ACCOUNT="ebs-csi-controller"
export SNAPSHOT_ENABLE="true" # [true|false]
export SNAPSHOT_IAM_ROLE_NAME=${CLUSTER_NAME}"-AmazonEKS_EBS_CSI_Driver_Role_For_Snapshot"
export SNAPSHOT_SERVICE_ACCOUNT="ebs-csi-snapshot"
export NAMESPACE="kube-system"
export CHART_VERSION="0.9.8"
export REGION="ap-northeast-2"
export RELEASE_NAME="aws-ebs-csi-driver"

source ./utils.sh

##############################################################
# Delete release
##############################################################
if [ "delete" == "$1" ]; then
  kubectl delete --ignore-not-found pdb/ebs-csi-controller-pdb --namespace ${NAMESPACE}
  kubectl delete --ignore-not-found pdb/ebs-snapshot-controller-pdb --namespace ${NAMESPACE}

  helm delete ${RELEASE_NAME} --namespace ${NAMESPACE}

  kubectl delete --ignore-not-found customresourcedefinitions\
    volumesnapshotclasses.snapshot.storage.k8s.io\
    volumesnapshotcontents.snapshot.storage.k8s.io\
    volumesnapshots.snapshot.storage.k8s.io
  exit 0
fi

##############################################################
# Create IAM Role and ServiceAccount
##############################################################
## download a latest policy for EBS CSI controller from kubernetes-sigs
curl -sSL -o ebs-csi-policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-ebs-csi-driver/master/docs/example-iam-policy.json

## create a policy
IAM_POLICY_ARN=$(aws iam list-policies --scope Local 2> /dev/null | jq -c --arg policyname $IAM_POLICY_NAME '.Policies[] | select(.PolicyName == $policyname)' | jq -r '.Arn')
if [ -z "$IAM_POLICY_ARN" ]; then
  IAM_POLICY_ARN=$(aws iam create-policy --policy-name ${IAM_POLICY_NAME} --policy-document file://ebs-csi-policy.json | jq -r .Policy.Arn)
fi

CONTROLLER_IAM_ROLE_ARN=$(createRole "$CLUSTER_NAME" "$NAMESPACE" "$CONTROLLER_SERVICE_ACCOUNT" "$CONTROLLER_IAM_ROLE_NAME" "$IAM_POLICY_ARN")

if [[  "true" == $SNAPSHOT_ENABLE ]]; then
  SNAPSHOT_IAM_ROLE_ARN=$(createRole "$CLUSTER_NAME" "$NAMESPACE" "$SNAPSHOT_SERVICE_ACCOUNT" "$SNAPSHOT_IAM_ROLE_NAME" "$IAM_POLICY_ARN")
else
  SNAPSHOT_ENABLE="false"
fi

##############################################################
# Install EXTERNAL SNAPSHOT CSI CRD
##############################################################
if [[  "true" == $SNAPSHOT_ENABLE ]]; then
  kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/master/client/config/crd/snapshot.storage.k8s.io_volumesnapshotclasses.yaml --validate=false

  kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/master/client/config/crd/snapshot.storage.k8s.io_volumesnapshotcontents.yaml --validate=false

  kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/master/client/config/crd/snapshot.storage.k8s.io_volumesnapshots.yaml --validate=false
fi

##############################################################
# Install AWS EBS CSI DRIVER with Helm
##############################################################
LOCAL_OS_KERNEL="$(uname -a | awk -F ' ' ' {print $1} ')"
## Add the aws-ebs-csi-driver Helm repository
if [ -z "$(helm repo list | grep https://kubernetes-sigs.github.io/aws-ebs-csi-driver)" ]; then
  helm repo add aws-ebs-csi-driver https://kubernetes-sigs.github.io/aws-ebs-csi-driver
fi
helm repo update

if [ "Darwin" == "$LOCAL_OS_KERNEL" ]; then
  sed -i.bak "s|REGION|${REGION}|g" ./templates/ebs-csi-driver.values.yaml
  sed -i '' "s|CONTROLLER_SERVICE_ACCOUNT|${CONTROLLER_SERVICE_ACCOUNT}|g" ./templates/ebs-csi-driver.values.yaml
  sed -i '' "s|CONTROLLER_IAM_ROLE_ARN|${CONTROLLER_IAM_ROLE_ARN}|g" ./templates/ebs-csi-driver.values.yaml
else
  CONTROLLER_IAM_ROLE_ARN=$(echo ${CONTROLLER_IAM_ROLE_ARN} | sed 's|\/|\\/|')
  sed -i.bak "s/REGION/${REGION}/g" ./templates/ebs-csi-driver.values.yaml
  sed -i "s/CONTROLLER_SERVICE_ACCOUNT/${CONTROLLER_SERVICE_ACCOUNT}/g" ./templates/ebs-csi-driver.values.yaml
  sed -i "s/CONTROLLER_IAM_ROLE_ARN/${CONTROLLER_IAM_ROLE_ARN}/g" ./templates/ebs-csi-driver.values.yaml
fi

if [[  "true" == $SNAPSHOT_ENABLE ]]; then
  if [ "Darwin" == "$LOCAL_OS_KERNEL" ]; then
    sed -i '' "s|SNAPSHOT_ENABLE|${SNAPSHOT_ENABLE}|g" ./templates/ebs-csi-driver.values.yaml
    sed -i '' "s|SNAPSHOT_SERVICE_ACCOUNT|${SNAPSHOT_SERVICE_ACCOUNT}|g" ./templates/ebs-csi-driver.values.yaml
    sed -i '' "s|SNAPSHOT_IAM_ROLE_ARN|${SNAPSHOT_IAM_ROLE_ARN}|g" ./templates/ebs-csi-driver.values.yaml
  else
    SNAPSHOT_IAM_ROLE_ARN=$(echo ${SNAPSHOT_IAM_ROLE_ARN} | sed 's|\/|\\/|')
    sed -i "s/SNAPSHOT_ENABLE/${SNAPSHOT_ENABLE}/g" ./templates/ebs-csi-driver.values.yaml
    sed -i "s/SNAPSHOT_SERVICE_ACCOUNT/${SNAPSHOT_SERVICE_ACCOUNT}/g" ./templates/ebs-csi-driver.values.yaml
    sed -i "s/SNAPSHOT_IAM_ROLE_ARN/${SNAPSHOT_IAM_ROLE_ARN}/g" ./templates/ebs-csi-driver.values.yaml
  fi
fi

helm upgrade --install ${RELEASE_NAME} \
  aws-ebs-csi-driver/aws-ebs-csi-driver \
  --version=${CHART_VERSION} \
  --namespace ${NAMESPACE} \
  -f ./templates/ebs-csi-driver.values.yaml \
  --wait

##############################################################
# Create Storage Classes
##############################################################
## Remove in-tree gp2 driver and recreate
if [[ "kubernetes.io/aws-ebs" == "$(kubectl get sc gp2 | grep gp2 | awk -F ' ' '{ print $3 }')" ]]; then
  kubectl delete sc gp2
  kubectl apply -f ./templates/gp2-storage-class.yaml
fi

## Add gp3 and io2 type StorageClass
kubectl apply -f ./templates/added-storage-class.yaml

##############################################################
## Create a EBS Volume Snapshot Class
##############################################################
if [[  "true" == $SNAPSHOT_ENABLE ]]; then
  kubectl apply -f ./templates/ebs-volume-snapshot-clsss.yaml
fi

##############################################################
## Create a PodDisruptionBudget
##############################################################
kubectl apply -f ./templates/ebs-csi-controller-pdb.yaml
if [[  "true" == $SNAPSHOT_ENABLE ]]; then
  kubectl apply -f ./templates/ebs-snapshot-controller-pdb.yaml
fi
